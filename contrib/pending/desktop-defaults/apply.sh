#!/bin/bash
# Install the m5pro desktop defaults on the J716s (staged 2026-11-16, not yet run). Idempotent; prints each step.
# Run as root on the MacBook from a copy of this folder:  bash apply.sh [USER]
#   USER: the desktop user whose hypridle.conf is replaced (default: the owner of /home's first directory).
# Leaves logind's new lid setting for the next boot (restarting logind would end the desktop session).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:-$(stat -c %U /home/* 2>/dev/null | head -1)}
say() { echo "== $*"; }

say "system drop-ins"
for f in $(cd files && find etc -type f); do install -Dm644 "files/$f" "/$f"; echo "   /$f"; done

say "/boot read-only (Windows-side finding A1: systemd-gpt-auto-generator mounts the ESP read-write on access)"
if grep -qE '^[^#]\S*\s+/boot\s' /etc/fstab; then echo "   /etc/fstab already has a /boot line: left alone"; else
  ls /boot >/dev/null; ESPDEV=$(findmnt -no SOURCE -t vfat /boot); EP=$(blkid -s PARTUUID -o value "$ESPDEV")
  [ -n "$EP" ] || { echo "   could not read the ESP's PARTUUID: stopping"; exit 1; }
  echo "PARTUUID=$EP /boot vfat ro,fmask=0177,dmask=0077,nosuid,nodev,noexec,x-systemd.automount,x-systemd.idle-timeout=120 0 2" >> /etc/fstab
  echo "   added the /boot line for $ESPDEV; esp-put.sh still remounts read-write inside its own write"
  systemctl daemon-reload; systemctl stop boot.mount boot.automount 2>/dev/null || true; systemctl start boot.automount
  ls /boot >/dev/null; findmnt -no OPTIONS -t vfat /boot
fi

say "packages (wireless-regdb: Wi-Fi regulatory database; zram-generator: compressed swap)"
pacman -S --needed --noconfirm wireless-regdb zram-generator

say "sysctl, journald, zram"
sysctl --system >/dev/null
systemctl restart systemd-journald
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service || echo "   zram setup failed (see journalctl -u systemd-zram-setup@zram0)"
swapon --show

say "TRIM"
if [ "$(cat /sys/block/nvme0n1/queue/discard_max_bytes)" != 0 ]; then systemctl enable --now fstrim.timer; else echo "   the NVMe reports no discard: fstrim.timer left off"; fi

say "systemd-oomd (needs CONFIG_PSI: next6 and later)"
if [ -e /proc/pressure/memory ]; then systemctl enable --now systemd-oomd.service; else echo "   no /proc/pressure: left off"; fi

say "hypridle for $U"
H=$(getent passwd "$U" | cut -d: -f6)
C=$H/.config/hypr/hypridle.conf
[ -f "$C" ] && [ ! -f "$C.before-m5pro" ] && cp -p "$C" "$C.before-m5pro"
install -Dm644 -o "$U" -g "$U" files/user/hypr/hypridle.conf "$C"
echo "   $C (old copy: $C.before-m5pro). hypridle must be started by the compositor: check with 'pgrep -a hypridle'"
pgrep -a hypridle || echo "   hypridle is NOT running (queue item 8: find which autostart line is missing)"
pkill -f org.omarchy.screensaver 2>/dev/null || true

say "regulatory database"
iw reg reload 2>/dev/null || true; iw reg get | head -3
say "done; lid setting takes effect at the next boot"
