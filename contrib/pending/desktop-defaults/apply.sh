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
sysctl --system >/dev/null 2>&1 || echo "   some sysctl keys are not in this kernel (fq/bbr: next6 and later); the rest are set"
systemctl restart systemd-journald
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service || echo "   zram setup failed (see journalctl -u systemd-zram-setup@zram0)"
swapon --show

say "TRIM"
if [ "$(cat /sys/block/nvme0n1/queue/discard_max_bytes)" != 0 ]; then systemctl enable --now fstrim.timer; else echo "   the NVMe reports no discard: fstrim.timer left off"; fi

say "systemd-oomd (needs CONFIG_PSI: next6 and later)"
if [ -e /proc/pressure/memory ]; then systemctl enable --now systemd-oomd.service; else echo "   no /proc/pressure: left off"; fi

say "idle for $U: Omarchy's shell does it (no hypridle): screensaver off, lock at 5 min, panel off 5 s after the lock"
# The shell's idle service (plugins/services/idle) reads idle.screensaver / idle.lock (seconds, 0 = off) from
# shell.json and reloads it by itself; the lock screen blanks the panel 5 s after locking
# (omarchy-brightness-display off = hl.dsp.dpms disable, DCP cycle checked 2026-11-16). The screensaver
# (alacritty + ttfx at 120 fps) cost ~7700 IPIs/s on next4, so it goes; turn it back on in shell.json.
H=$(getent passwd "$U" | cut -d: -f6)
SJ=$H/.config/omarchy/shell.json
if [ -f "$SJ" ]; then
  [ -f "$SJ.before-m5pro-idle" ] || cp -p "$SJ" "$SJ.before-m5pro-idle"
  python3 - "$SJ" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
idle = d.setdefault("idle", {})
idle["screensaver"] = 0
idle.setdefault("lock", 300)
open(p, "w").write(json.dumps(d, indent=2) + "\n")
print("   idle:", json.dumps(idle))
EOF
  chown "$U:$U" "$SJ"
else
  echo "   $SJ missing: idle left alone"
fi
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

say "regulatory database + country (m5pro-regdom.service; country from /etc/conf.d/wireless-regdom)"
if ! grep -q '^WIRELESS_REGDOM=' /etc/conf.d/wireless-regdom 2>/dev/null; then
  echo 'WIRELESS_REGDOM="US"' >> /etc/conf.d/wireless-regdom; echo "   country set to US (change it in /etc/conf.d/wireless-regdom)"
fi
systemctl daemon-reload; systemctl enable m5pro-regdom.service; systemctl restart m5pro-regdom.service
iw reg get | sed -n 2p

say "root fs: drop x-systemd.growfs (systemd-growfs-root failed on every boot; the partition is already full size)"
if grep -q 'x-systemd.growfs' /etc/fstab; then cp -p /etc/fstab /etc/fstab.before-m5pro-growfs; sed -i 's/,x-systemd\.growfs//; s/x-systemd\.growfs,//' /etc/fstab; systemctl daemon-reload; systemctl reset-failed systemd-growfs-root.service 2>/dev/null || true; fi
grep -E '\s/\s' /etc/fstab
say "done; lid setting takes effect at the next boot"
