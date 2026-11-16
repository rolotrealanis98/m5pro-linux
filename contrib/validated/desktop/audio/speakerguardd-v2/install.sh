#!/bin/sh
# Install the J716s speakerguardd v2 drop-ins (README.md). Run as root from this directory, after
# pkg/speakerguardd-v2 and pkg/aurora-speaker-upgrade are installed and ../install.sh has put the UCM in place.
# Changes no running service; the boot unit switches the speakers at the next boot, after its own checks.
set -eu
S=/usr/lib/systemd/system
install -Dm0644 70-j716-speaker-upgrade-auto.conf "$S/aurora-speaker-upgrade.service.d/70-m5pro-j716s-auto.conf"
install -Dm0644 speakersafetyd-hold.conf "$S/speakersafetyd.service.d/50-m5pro-j716-hold.conf"
install -Dm0755 sgv2-telemetry.py /usr/local/bin/sgv2-telemetry
systemctl daemon-reload
# SGV2_NO_ENABLE=1 leaves the boot unit off (the silent bring-up test does; the morning procedure enables it)
[ -n "${SGV2_NO_ENABLE:-}" ] || systemctl enable aurora-speaker-upgrade.service
echo "installed; 'j716-audio-ab v2' removes the old speaker graph, then reboot. Undo: see README.md"
