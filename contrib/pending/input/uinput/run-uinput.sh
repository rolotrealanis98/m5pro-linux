#!/bin/bash
# uinput round (issue #4), driven from the Studio. Adapted from video-observe/run-promote-rec-video.sh.
#   run-uinput.sh prep      no reboot: modules for the new release on the root, udev rule, self-check tool
#   run-uinput.sh test      write uinput-test (m5.selftest=1, self-reverts to boot.bin.prev) as boot.bin, reboot, check
#   run-uinput.sh promote   from a passed test boot: write daily-uinput-hv27 (no selftest) as boot.bin, reboot, check
# boot.bin.prev is never written here: it stays the previous daily (c7f84366), which is the rollback.
set -o pipefail
MODE=${1:?prep|test|promote}
U=~/Work/agents/uinput; cd "$U" || exit 1
REPO=~/Documents/GitHub/m5pro-linux/contrib/pending/input/uinput
HOST=${HOST:?HOST=root@<macbook>}; SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8); export HOST
PROBE=~/Documents/GitHub/m5pro-linux/contrib/pending/boot-ab/firstboot/firstboot-probe.sh
PREV_DAILY=c7f84366
REL=$(cat kbuild-uinput/kernel.release) || exit 1
r() { ssh "${SSHO[@]}" "$HOST" "$@" 2>&1 | grep -v "null byte"; }
waitup() { sleep 100; for i in $(seq 1 40); do ssh "${SSHO[@]}" "$HOST" true 2>/dev/null && return 0; sleep 10; done; return 1; }
put() { scp "${SSHO[@]}" "$1" "$HOST:/root/$(basename "$1")" && r "sh /root/esp-put.sh /root/$(basename "$1") $2 $3"; }
state() { r 'echo "KERNEL $(uname -r) up $(cut -d. -f1 /proc/uptime) s slot=$(tr -d "\0" < /proc/device-tree/chosen/m5pro,boot-slot) pmu=$(tr -d "\0" < /proc/device-tree/chosen/m5pro,pmu-scrpad) boot.bin=$(sha256sum /boot/m1n1/boot.bin | cut -c1-8) prev=$(sha256sum /boot/m1n1/boot.bin.prev | cut -c1-8) drm: $(for c in /sys/class/drm/card[0-9]; do echo -n "$(basename $c)=$(basename $(readlink $c/device/driver)) "; done) hyprland=$(pgrep -xc Hyprland) selftest=$(grep -c m5.selftest=1 /proc/cmdline)"'; }
rb() { REBOOT=$(date +%s); r 'sync; sleep 30; systemctl reboot' >/dev/null; waitup || { echo "ssh never came back"; return 1; }; echo "reboot->ssh $(( $(date +%s) - REBOOT )) s"; SSHO="-i $HOME/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8" "$PROBE" "$REBOOT"; state; }
checks() {
  echo "--- nodes"; r 'ls -l /dev/uinput /dev/uhid; zcat /proc/config.gz | grep -E "^CONFIG_(INPUT_UINPUT|UHID)="'
  echo "--- bluetooth (unchanged by this kernel; uhid is what its LE HID devices need)"; r 'systemctl is-active bluetooth; timeout 8 bluetoothctl show | grep -E "Powered"; timeout 14 bluetoothctl --timeout 8 scan on >/dev/null 2>&1; echo "devices seen: $(timeout 5 bluetoothctl devices | wc -l)"; btmgmt info 2>/dev/null | grep -E "supported settings|current settings" | cut -c1-200; dmesg | grep -i -E "Bluetooth: hci0|centauri.*(bt|error|timeout)" | tail -5'
  echo "--- self-check as root (uinput + uhid)"; r 'python3 /root/uinput-selfcheck.py; echo rc=$?'
  echo "--- self-check as the desktop user (uinput through the udev rule)"; r 'runuser -u rolo -- python3 /usr/local/bin/uinput-selfcheck.py; echo rc=$?'
  echo "--- desktop"; r 'sleep 20; hypr-dcp-precheck 2>&1 | grep "DCP session"; hypr-dcp-verify 2>&1 | tail -4; /usr/local/bin/m5pro-rescue status 2>&1 | tail -2'
  echo "--- selftest journal"; r 'journalctl -b -t m5-selftest --no-pager 2>/dev/null | tail -3'
  echo "--- kernel log (errors since boot, uinput/uhid lines)"; r 'dmesg -l err,crit,alert,emerg | tail -8; dmesg | grep -i -E "uinput|uhid" | tail -5'
}
pick() { ls -t "$U"/$1-2*.bin 2>/dev/null | head -1; }
echo "=== uinput $MODE $(date -u +%H:%M:%S)  release $REL"
case "$MODE" in
prep)
  state
  M=$U/modules-$REL.tar.zst; [ -f "$M" ] || M=$U/kbuild-uinput/modules-$REL.tar.zst
  scp "${SSHO[@]}" "$M" "$HOST:/root/" && r "tar -C / -xf /root/modules-$REL.tar.zst && depmod $REL && ls /lib/modules | grep -c $REL"
  scp "${SSHO[@]}" "$REPO/uinput-selfcheck.py" "$HOST:/root/uinput-selfcheck.py"
  scp "${SSHO[@]}" "$REPO/70-m5pro-uinput.rules" "$HOST:/etc/udev/rules.d/70-m5pro-uinput.rules"
  r 'install -m755 /root/uinput-selfcheck.py /usr/local/bin/uinput-selfcheck.py; udevadm control --reload; udevadm verify /etc/udev/rules.d/70-m5pro-uinput.rules 2>&1 | tail -2'
  ;;
test|promote)
  L=uinput-test; [ "$MODE" = promote ] && L=daily-uinput-hv27
  P=$(pick $L); [ -n "$P" ] || { echo "no $L payload (mk-uinput.py)"; exit 1; }
  PS=$(shasum -a 256 "$P" | cut -d' ' -f1); echo "payload $(basename "$P") $PS"
  r 'touch /run/m5pro-studio-busy'; state
  [ "$(r "ls /lib/modules | grep -c $REL")" = 1 ] || { echo "modules for $REL missing on the root (run prep)"; exit 1; }
  [ "$(r 'sha256sum /boot/m1n1/boot.bin.prev | cut -c1-8')" = $PREV_DAILY ] || { echo "boot.bin.prev is not the previous daily $PREV_DAILY, not writing"; exit 1; }
  if [ "$MODE" = promote ]; then
    [ "$(r 'uname -r' | grep -c "$REL")" = 1 ] || { echo "promote runs from the passed test boot ($REL), this is another kernel"; exit 1; }
  fi
  put "$P" boot.bin "$PS" || { echo "write failed"; exit 1; }
  rb || exit 1
  if [ "$(r 'uname -r' | grep -c "$REL")" != 1 ]; then echo "RESULT: $L FELL BACK (prev booted)"; r 'rm -f /run/m5pro-studio-busy'; exit 1; fi
  checks
  r 'rm -f /run/m5pro-studio-busy'; state
  ;;
*) echo "prep|test|promote"; exit 2;;
esac
echo "=== done $(date -u +%H:%M:%S)"
