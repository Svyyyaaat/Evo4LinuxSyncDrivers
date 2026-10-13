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
    echo "Installed: $(rpm -q alsa-ucm 2>/dev/null || echo unknown). Try: sudo dnf upgrade alsa-ucm"
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

# alsaucm is used below to validate the profile (Fedora: alsa-ucm-utils).
if ! command -v alsaucm >/dev/null && command -v dnf >/dev/null; then
    dnf install -y -q alsa-ucm-utils >/dev/null 2>&1 || true
fi

ok=1
for id in /proc/asound/card*/id; do
    [[ "$(cat "$id" 2>/dev/null)" == EVO4* ]] || continue
    n=${id%/id}; n=${n##*card}
    if command -v alsaucm >/dev/null; then
        if out=$(alsaucm -c "hw:$n" set _verb HiFi get _devices 2>&1); then
            echo "UCM profile loads OK on card $n:"; echo "$out" | sed 's/^/    /'
        else
            ok=0; echo "ERROR: UCM profile failed to load on card $n:"; echo "$out" | sed 's/^/    /'
        fi
    fi
    # Runs the UCM boot sequence, which writes the ctl remap to /var/lib/alsa.
    if command -v alsactl >/dev/null; then
        alsactl restore "$n" 2>&1 | grep -v -i 'no state is present' || true
    fi
    ls /var/lib/alsa/card"$n".conf.d/ 2>/dev/null | grep -q remap \
        && echo "ctl remap active on card $n" \
        || echo "note: ctl remap not written yet for card $n (replug the EVO4)"
done
(( ok )) || { echo "Please send the error above."; exit 1; }

cat <<'EOF'

Done. Now, as your normal user (not root):
  systemctl --user restart wireplumber

Check:
  wpctl status                         # EVO4 "Headphones" sink should be default
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5   # the EVO4 LED ring should move
  pactl list cards | grep -A2 -i "active profile"   # EVO4 should be on HiFi
If the knob/volume still don't sync, replug the EVO4 once (applies the quirk).
EOF
