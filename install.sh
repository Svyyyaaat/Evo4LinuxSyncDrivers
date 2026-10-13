#!/usr/bin/env bash
# Install the Audient EVO4 hardware-volume sync fix (Fedora / any PipeWire distro).
#
#   sudo ./install.sh              # UCM override + snd-usb-audio quirk
#   sudo ./install.sh --no-quirk   # UCM override only
#
# Then, as your normal user:  systemctl --user restart wireplumber
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ucm=/usr/share/alsa/ucm2
quirk=1
[[ "${1:-}" == "--no-quirk" ]] && quirk=0

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

if ! grep -q 'conf.d/${var:USBID1}-${var:USBID2}.conf' "$ucm/USB-Audio/USB-Audio.conf" 2>/dev/null; then
    echo "alsa-ucm-conf >= 1.2.15 needed (has the USB-Audio/conf.d hook)."
    echo "Installed: $(rpm -q alsa-ucm-conf 2>/dev/null || echo unknown). Try: sudo dnf upgrade alsa-ucm-conf"
    exit 1
fi

install -d "$ucm/USB-Audio/conf.d/evo4-sync"
install -m 644 "$here/ucm2/USB-Audio/conf.d/2708-0006.conf" "$ucm/USB-Audio/conf.d/"
install -m 644 "$here"/ucm2/USB-Audio/conf.d/evo4-sync/*.conf "$ucm/USB-Audio/conf.d/evo4-sync/"
echo "installed UCM override -> $ucm/USB-Audio/conf.d/"

if (( quirk )); then
    read -r kmaj kmin _ <<<"$(uname -r | tr '.-' '  ')"
    if (( kmaj > 6 || (kmaj == 6 && kmin >= 18) )); then
        install -m 644 "$here/modprobe.d/snd-usb-audio-evo4.conf" /etc/modprobe.d/
        echo "installed /etc/modprobe.d/snd-usb-audio-evo4.conf (active after replug/reboot)"
        if grep -rqs 'snd_usb_audio.*quirk_flags' /etc/modprobe.d --exclude=snd-usb-audio-evo4.conf; then
            echo "WARNING: another quirk_flags option for snd_usb_audio exists in /etc/modprobe.d;"
            echo "         merge them into one line or only one will apply."
        fi
    else
        echo "kernel $(uname -r) < 6.18: skipping quirk (string quirk_flags unsupported)"
    fi
fi

# Re-run the card's UCM boot sequence (creates the ctl remap) if it's plugged in.
for id in /proc/asound/card*/id; do
    if [[ "$(cat "$id" 2>/dev/null)" == EVO4* ]]; then
        n=${id%/id}; n=${n##*card}
        command -v alsactl >/dev/null && alsactl restore "$n" >/dev/null 2>&1 || true
        echo "re-initialised ALSA card $n"
    fi
done

cat <<'EOF'

Done. Now, as your normal user (not root):
  systemctl --user restart wireplumber

Check:
  wpctl status                         # EVO4 "Headphones" sink should be default
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5   # the EVO4 LED ring should move
  alsaucm -c EVO4 get _verbs        # should list HiFi + Direct
If the knob/volume still don't sync, replug the EVO4 once (applies the quirk).
EOF
