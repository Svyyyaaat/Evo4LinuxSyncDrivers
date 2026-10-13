#!/usr/bin/env python3
"""Probe the Audient EVO4 for an LED / meter-ring control.

Nobody has found a USB control for the EVO4's LED ring yet: the Windows/macOS
EVO app has no LED option and its preset files store no LED state. The
device does have a few writable registers whose purpose is unknown. This
script reads them and lets you flip them one at a time while you watch the
LEDs. Every change is restored on exit.

Backends, picked automatically:
  * /dev/evo4 from the evo_raw kernel module (github.com/anor4k/audient-evo-py).
    Audio keeps playing, so you can watch the output meter react.
  * pyusb. Unbinds snd-usb-audio from the EVO4 while the script runs, so
    host playback stops. Input meters (mic/instrument) still work. Needs
    root or a udev rule.

Usage:
  sudo ./evo4-led-probe.py scan          # read known/unknown registers
  sudo ./evo4-led-probe.py try           # toggle candidates interactively
  sudo ./evo4-led-probe.py try --all     # also try every CS that reads back

Never touches Extension Unit 56 (monitor mix): unknown requests to it can
lock the unit until the device is replugged.
"""

import argparse
import fcntl
import os
import struct
import sys

VID, PID = 0x2708, 0x0006
SET_CUR, GET_CUR = 0x01, 0x01
OUT, IN = 0x21, 0xA1  # class request, interface recipient

EU58, EU59 = 0x3A, 0x3B  # input config, output config
SAFE_UNITS = {EU58: "EU58 input config", EU59: "EU59 output config"}

# Writable registers with no known function (from audient-evo-py DESIGN.md).
CANDIDATES = [
    (EU59, 2, 0, "EU59 CS2 CN0 - unknown boolean, default 1"),
    (EU59, 2, 1, "EU59 CS2 CN1 - unknown boolean"),
    (EU58, 5, 0, "EU58 CS5 CN0 - unknown, default 0"),
    (EU58, 5, 1, "EU58 CS5 CN1 - unknown, default 0xFFFFFFFF"),
]
# Known functions; scanned but never toggled.
KNOWN = {
    (EU58, 0): "phantom 48V",
    (EU58, 1): "gain mirror (RO)",
    (EU58, 2): "input mute",
    (EU58, 7): "capability flags (RO)",
    (EU59, 0): "volume mirror (RO)",
    (EU59, 1): "output mute",
}


class EvoRaw:
    """ioctl backend for /dev/evo4 (evo_raw.ko)."""

    FMT = "<BBHHH256s"
    IOCTL = (3 << 30) | (struct.calcsize(FMT) << 16) | (ord("E") << 8)

    def __init__(self, path="/dev/evo4"):
        self.fd = os.open(path, os.O_RDWR)

    def xfer(self, rtype, req, value, index, data_or_len):
        if rtype & 0x80:
            buf = struct.pack(self.FMT, rtype, req, value, index, data_or_len, b"")
        else:
            data = bytes(data_or_len)
            buf = struct.pack(self.FMT, rtype, req, value, index, len(data), data)
        buf = bytearray(buf)
        fcntl.ioctl(self.fd, self.IOCTL, buf)
        if rtype & 0x80:
            n = struct.unpack_from("<H", buf, 6)[0]
            return bytes(buf[8 : 8 + n])
        return None

    def close(self):
        os.close(self.fd)


class PyUsb:
    """pyusb backend; temporarily detaches snd-usb-audio from interface 0."""

    def __init__(self):
        import usb.core

        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            sys.exit("EVO4 not found (lsusb | grep 2708:0006)")
        self.detached = []
        for intf in (0, 1, 2):
            if self.dev.is_kernel_driver_active(intf):
                self.dev.detach_kernel_driver(intf)
                self.detached.append(intf)
        import usb.util

        usb.util.claim_interface(self.dev, 0)

    def xfer(self, rtype, req, value, index, data_or_len):
        r = self.dev.ctrl_transfer(rtype, req, value, index, data_or_len, timeout=1000)
        return bytes(r) if rtype & 0x80 else None

    def close(self):
        import usb.util

        usb.util.release_interface(self.dev, 0)
        for intf in self.detached:
            try:
                self.dev.attach_kernel_driver(intf)
            except Exception as e:  # noqa: BLE001
                print(f"reattach interface {intf} failed ({e}); replug the EVO4")


def open_backend():
    if os.path.exists("/dev/evo4"):
        print("backend: /dev/evo4 (audio keeps running)")
        return EvoRaw()
    try:
        import usb.core  # noqa: F401
    except ImportError:
        sys.exit("need /dev/evo4 (evo_raw) or pyusb: sudo dnf install python3-pyusb")
    print("backend: pyusb (snd-usb-audio detached; host audio stops until exit)")
    return PyUsb()


def get(dev, unit, cs, cn, n=4):
    try:
        return dev.xfer(IN, GET_CUR, (cs << 8) | cn, unit << 8, n)
    except OSError:
        return None  # STALL: not present


def put(dev, unit, cs, cn, data):
    dev.xfer(OUT, SET_CUR, (cs << 8) | cn, unit << 8, data)


def scan(dev):
    found = []
    for unit, name in SAFE_UNITS.items():
        print(f"\n{name} (wIndex=0x{unit:02X}00)")
        for cs in range(0, 9):
            for cn in range(0, 3):
                v = get(dev, unit, cs, cn)
                if v is None:
                    continue
                label = KNOWN.get((unit, cs), "unknown")
                print(f"  CS{cs} CN{cn}: {v.hex():<10} {label}")
                if (unit, cs) not in KNOWN:
                    found.append((unit, cs, cn, f"{name} CS{cs} CN{cn} - unknown"))
    return found


def try_values(orig):
    """Values worth trying for a 4-byte register."""
    vals = [b"\x00\x00\x00\x00", b"\x01\x00\x00\x00", b"\xff\xff\xff\xff"]
    return [v for v in vals if v != orig[:4]]


def try_candidates(dev, cands):
    print("\nPlay audio / talk into a mic so the LEDs are active, then watch them.")
    for unit, cs, cn, label in cands:
        orig = get(dev, unit, cs, cn)
        if orig is None:
            print(f"\n{label}: not readable, skipped")
            continue
        print(f"\n{label}: current {orig.hex()}")
        try:
            for val in try_values(orig):
                put(dev, unit, cs, cn, val)
                now = get(dev, unit, cs, cn)
                ans = input(
                    f"  wrote {val.hex()} (reads {now.hex() if now else '??'})"
                    " - did the LEDs change? [y/N/q] "
                )
                if ans.lower().startswith("y"):
                    print(f"  >>> HIT: {label} = {val.hex()}  (please report this!)")
                if ans.lower().startswith("q"):
                    return
        finally:
            put(dev, unit, cs, cn, orig[:4])
            print(f"  restored {orig[:4].hex()}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", choices=["scan", "try"])
    ap.add_argument("--all", action="store_true", help="try every unknown CS found by scan")
    args = ap.parse_args()

    dev = open_backend()
    try:
        found = scan(dev)
        if args.cmd == "try":
            cands = list(CANDIDATES)
            if args.all:
                seen = {(u, cs, cn) for u, cs, cn, _ in cands}
                cands += [c for c in found if c[:3] not in seen]
            try_candidates(dev, cands)
    finally:
        dev.close()


if __name__ == "__main__":
    main()
