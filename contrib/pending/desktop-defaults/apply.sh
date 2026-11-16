#!/bin/bash
# Install the m5pro desktop defaults on the J716s (staged 2026-11-16, not yet run). Idempotent; prints each step.
# Run as root on the MacBook from a copy of this folder:  bash apply.sh [USER]
#   USER: the desktop user whose hypridle.conf is replaced (default: the owner of /home's first directory).
# Leaves logind's new lid setting for the next boot (restarting logind would end the desktop session).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:-$(stat -c %U /home/* 2>/dev/null | head -1)}
say() { echo "== $*"; }

say "system drop-ins and tools"
for f in $(cd files && find etc -type f); do install -Dm644 "files/$f" "/$f"; echo "   /$f"; done
for f in $(cd files && find usr -type f); do install -Dm755 "files/$f" "/$f"; echo "   /$f"; done

say "battery charge limit (default 80 %; m5pro-charge-limit full = 100 % until unplugged)"
if grep -q '^CHARGE_CONTROL_END_THRESHOLD=' /etc/udev/macsmc-battery.conf 2>/dev/null; then
  echo "   a saved limit exists: $(grep '^CHARGE_CONTROL_END_THRESHOLD=' /etc/udev/macsmc-battery.conf), left alone"
else
  echo 'CHARGE_CONTROL_END_THRESHOLD=80' > /etc/udev/macsmc-battery.conf
fi
udevadm control --reload
/usr/local/lib/m5pro/charge-limit-restore
/usr/local/bin/m5pro-charge-limit || echo "   no charge limit support in this kernel"

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

say "menu rows: System > Battery charge limit (user menu extension, backup .before-m5pro-battery)"
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
if [ ! -f "$MENU" ]; then echo "   $MENU missing: rows not added (see README)"
elif grep -q '"system.battery-limit"' "$MENU"; then echo "   rows already there"
else
  cp -p "$MENU" "$MENU.before-m5pro-battery"
  python3 - "$MENU" files/user/omarchy/menu-battery-rows.jsonc <<'EOF'
import re, sys
path, rows = sys.argv[1], open(sys.argv[2]).read().rstrip()
text = open(path).read()
end = text.rindex("}")
# The last meaningful character before the closing brace, ignoring // comments and whitespace.
body = re.sub(r"//[^\n]*", "", text[:end]).rstrip()
sep = "" if body.endswith(("{", ",")) else ","
open(path, "w").write(text[:end].rstrip() + "\n" + sep + "\n" + rows + "\n" + text[end:])
EOF
  chown "$U:$U" "$MENU"; echo "   added; Quickshell reloads the file by itself"
fi

say "regulatory database"
iw reg reload 2>/dev/null || true; iw reg get | head -3
say "done; lid setting takes effect at the next boot"
