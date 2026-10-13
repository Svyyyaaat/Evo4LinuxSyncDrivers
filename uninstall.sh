#!/usr/bin/env bash
# Remove the EVO4 sync fix. Run with sudo, then: systemctl --user restart wireplumber
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
rm -fv /usr/share/alsa/ucm2/USB-Audio/conf.d/2708-0006.conf
rm -rfv /usr/share/alsa/ucm2/USB-Audio/conf.d/evo4-sync
rm -fv /etc/modprobe.d/snd-usb-audio-evo4.conf
