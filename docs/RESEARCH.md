# EVO 4 on Linux: research notes

## Existing work

| Project | What it does |
|---|---|
| [anor4k/audient-evo-py](https://github.com/anor4k/audient-evo-py) | Most complete reverse-engineering effort (EVO 4 fully tested). It adds an `evo_raw` kernel module that binds the unused DFU interface (iface 3) to send control transfers without detaching `snd-usb-audio`. It also renames `EVO4  Playback Volume` to `Master Playback Volume` in-kernel. CLI/TUI for gain, 48 V, mute, monitor mix, loopback mixer. |
| [vijay-prema/audient-evo-linux-tools](https://github.com/vijay-prema/audient-evo-linux-tools) | Wireshark/USBPcap captures of the Windows app, replayed with pyusb (detaches the sound driver). |
| [soerenbnoergaard/evoctl](https://github.com/soerenbnoergaard/evoctl) | EVO 8 mixer for Linux, same protocol. |
| [alsa-ucm-conf PR #708](https://github.com/alsa-project/alsa-ucm-conf/pull/708) | Upstream EVO4 UCM profile (in 1.2.16; later changed to expect `Master`). |
| [Kernel patch set, Sep 2026](https://lore.kernel.org/lkml/20260919151840.24371-1-arc@gmx.li/) | `mixer_maps.c` renames FU 10 to `Master`. New `mixer_evo.c` adds ALSA controls for EU56/58/59 and MU60. Accepted by Takashi Iwai on 29 Sep 2026 (Kconfig patch dropped). |
| [Regression report](https://lore.kernel.org/regressions/CANBVYRCL=8QdLxGg4S6qrahrFtwJxhv-aSGpW7-1S=+iOe4ZGA@mail.gmail.com/) | Since kernel 7.2 (and 6.12/6.18 LTS), rejected mixer writes reach PipeWire, so volume is applied twice. Workaround: `quirk_flags=2708:0006:IGNORE_CTL_ERROR`. |

## USB layout (2708:0006)

| Interface | Use |
|---|---|
| 0 | Audio Control (UAC2) + interrupt EP for change notifications |
| 1 | Playback, 4 ch: 1/2 = main out, 3/4 = loopback bus |
| 2 | Capture, 4 ch: 1/2 = inputs, 3/4 = loopback |
| 3 | DFU (unused by Linux) |

All controls are UAC2 class requests on EP0: `bmRequestType 0x21/0xA1`,
`bRequest 0x01 (CUR)`, `wValue = CS<<8 | CN`, `wIndex = Entity<<8 | 0`.

| Entity | Function |
|---|---|
| FU 10 (0x0A00) CS2 | Output volume, Q8.8 dB, ch 1/2 (3/4 fixed, reject SET) |
| FU 11 (0x0B00) CS2 | Input gain −8…+50 dB |
| EU 56 (0x3800) CS0 | Monitor blend 0…127. **Don't probe other CS: the unit locks up.** |
| EU 58 (0x3A00) | CS0 48 V, CS2 input mute, CS5 **unknown (writable)**, CS7 capability flags |
| EU 59 (0x3B00) | CS0 volume mirror, CS1 output mute, CS2 **unknown boolean** |
| MU 60 (0x3C00) CS1 | 6×2 loopback mixer, write-only |

## Why the volume doesn't sync

`snd-usb-audio` builds the control name from the FU's string descriptor, which gives
`EVO4  Playback Volume`. PipeWire's ACP doesn't match that element. Stock UCM 1.2.16
uses the key `PlaybackVolume "EVO4 "`, which PipeWire doesn't use for the
hardware mixer. Newer upstream UCM expects `Master`, which only the patched kernel
provides. Either way PipeWire uses software volume.

Fixes, from most to least invasive:
1. Patched kernel (upstream, coming). The proper fix.
2. `evo_raw` out-of-tree module renames the control. Needs DKMS/akmods, plus module
   signing under Secure Boot on Fedora.
3. **This repo:** alsa-lib's `remap` ctl plugin, set up by a UCM `conf.d`
   override (alsa-ucm-conf ≥ 1.2.15). It's pure userspace and survives kernel updates.
   This is the same mechanism alsa-ucm-conf already uses for Behringer UMC devices.

## LEDs

- The ring LEDs and input meters are run by the device MCU. There's no HID interface.
  The buttons and encoder aren't visible over USB (audient-evo-py DESIGN.md, "Known Quirks" 5).
- Audient's EVO app 4.3.18 preset XML (`dev/evo4_app_windows/example_save_files`
  in audient-evo-py) stores blend, mixer, inputs, routing and sample rate.
  It has **no LED or display settings**. The app has no such option either.
- The upstream kernel patch only covers EU56/58/59/MU60. None of it is LED-related.
- The remaining unknowns are EU58 CS5 (CN0 default 0, CN1 default 0xFFFFFFFF;
  writable, no audible effect seen) and EU59 CS2 (boolean, default 1). Nobody has
  watched the LEDs while toggling them. `tools/evo4-led-probe.py` does exactly that.
- Vendor-specific requests and the DFU interface are unexplored. Firmware
  modification is out of scope (brick risk).

Conclusion: a lights-off mode needs a register that the official software
itself doesn't use. That's unlikely to exist, but the probe is cheap and safe to run.
