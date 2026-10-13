# Evo4LinuxSyncDrivers

Make the **Audient EVO 4**'s hardware volume (the knob and its LED ring) follow
the system volume on Linux, the way it does on Windows. Targets Fedora + PipeWire
(Hyprland or any other desktop). No kernel module needed.

> **Status: untested on real hardware.** The config parses cleanly with alsa-lib
> and is built from upstream pieces that are known to work (see
> [docs/RESEARCH.md](docs/RESEARCH.md)). Please report whether it works.

## Why the volume doesn't sync

The EVO 4's output volume is a normal USB Audio Class 2 Feature Unit (FU 10).
Linux sees it, but `snd-usb-audio` names the control after the device's USB
string: **`EVO4  Playback Volume`** (with two spaces). PipeWire only drives
hardware volume when it can match a mixer element (`Master`, `PCM`, `Headphone`,
...) or a UCM profile names one. The stock EVO4 UCM profile in
alsa-ucm-conf 1.2.16 sets `PlaybackVolume "EVO4 "`, which PipeWire doesn't use.
The current upstream profile expects `Master Playback Volume`, a name only
kernels with a new patch provide. So PipeWire falls back to **software volume**:
the stream is scaled digitally, and the EVO stays at whatever level the knob is set to.

On Windows, Audient's driver maps the system volume onto FU 10 directly.

## The fix

A UCM override (`ucm2/USB-Audio/conf.d/`) that:

1. uses alsa-lib's `remap` ctl plugin to expose FU 10 as a 2-channel
   **`Main Output Playback Volume`**, covering only the real L/R channels. Channels
   3/4 are internal, and PipeWire's writes to them are rejected by the firmware.
2. points PipeWire's "Headphones" sink at that element (`PlaybackMixerElem`).
3. keeps everything else from the upstream EVO4 profile (stereo output,
   loopback sink/source, separate Mic 1 / Mic 2 sources).

It works with both naming schemes: it detects whether the kernel already exposes
`Master Playback Volume`. It also installs an optional `snd-usb-audio`
`IGNORE_CTL_ERROR` quirk. That works around a 7.2+/6.18-LTS regression where a
rejected write makes PipeWire apply the volume twice.

Result: `wpctl`, media keys, Waybar/pavucontrol sliders all move the EVO's
hardware volume (the LED ring shows it). Turning the knob should also update
PipeWire. The EVO has a UAC2 interrupt endpoint that reports control changes,
and audient-evo-py reports this working once PipeWire uses the hardware control.

### Install (Fedora)

```bash
git clone https://github.com/svyyyaaat/evo4linuxsyncdrivers && cd evo4linuxsyncdrivers
sudo ./install.sh                 # needs alsa-ucm-conf >= 1.2.15 (rpm -q alsa-ucm)
systemctl --user restart wireplumber
```

Replug the EVO 4 once so the modprobe quirk applies. Remove with
`sudo ./uninstall.sh`.

Hyprland volume keys (they now control the hardware):

```ini
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl  = , XF86AudioMute,        exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
```

Conflicts: remove any WirePlumber rule that sets `api.alsa.use-ucm = false` for
the EVO4 (audient-evo-py's `51-evo4.conf` does this), because this fix runs through UCM.

### Long term

Christian Ruppert's EVO4 mixer patches were [accepted by the ALSA maintainer in
Sep 2026](https://lore.kernel.org/lkml/20260919151840.24371-1-arc@gmx.li/). They
rename FU 10 to `Master` and add phantom power, input mute, the monitor mix and
the loopback mixer as ALSA controls. Once Fedora ships that kernel and a matching
alsa-ucm-conf, you won't need this repo. The override handles the transition.

## LED "lights-off" mode

**Not possible with what is known today.** Details in [docs/RESEARCH.md](docs/RESEARCH.md#leds):

- The ring/meter LEDs are driven by the EVO's own microcontroller. The front
  panel isn't exposed over USB: there's no HID interface, and buttons and the
  encoder aren't readable.
- Audient's own EVO app (Win/macOS) has no LED or brightness setting. Its preset
  files, which store the full device state, contain no LED field.
- Every decoded USB control (four independent reverse-engineering projects plus the
  upstream kernel patch) is about volume, gain, mute, 48 V or mixing. None is about LEDs.

There are two unknown, writable registers, plus a few never probed. If any of
them controls the meters, `tools/evo4-led-probe.py` will find it. It flips each
one while you watch the LEDs and restores everything afterwards:

```bash
sudo dnf install python3-pyusb
sudo ./tools/evo4-led-probe.py scan
sudo ./tools/evo4-led-probe.py try        # add --all to also try every unknown register
```

(With audient-evo-py's `evo_raw` module loaded, it uses `/dev/evo4` and audio
keeps playing. Otherwise it unbinds the sound driver while it runs.)

Possible workarounds that need no driver support:
- A physical fix: a strip of translucent/opaque tape over the ring.
- Firmware modification over the DFU interface is technically conceivable, but risky.
  It could brick the unit and isn't something I'd recommend.
