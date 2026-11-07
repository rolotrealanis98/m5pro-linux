#!/bin/bash
# J716s camera bring-up, run as root on the booted M5 (after root and network are up).
# Loads apple_isp ONCE: a marker on the ESP survives a crash, and the next run refuses to load
# again until the marker is read and deleted. Logs land in /boot/r1-logs/isp-<date>/.
#   isp-oneshot.sh            load, list devices and formats
#   isp-oneshot.sh capture    also capture one frame to /tmp/f.raw (a camera image: keep private)
set -u
LOGS=/boot/r1-logs
MARK=$LOGS/.isp-attempt
OUT=$LOGS/isp-$(date +%Y%m%d-%H%M%S)

if [ -e "$MARK" ]; then
	echo "A previous load did not finish (marker $MARK):"; cat "$MARK"
	echo "Read its logs, then delete the marker to try again."; exit 1
fi
if lsmod | grep -q '^apple_isp'; then echo "apple_isp is already loaded"; exit 1; fi

mkdir -p "$OUT"
echo "$(date -Is) $(uname -r) $*" > "$MARK"; sync

mount -t debugfs none /sys/kernel/debug 2>/dev/null
grep -i -E 'isp|domain' /sys/kernel/debug/pm_genpd/pm_genpd_summary > "$OUT/genpd-before.txt" 2>&1
dmesg > "$OUT/dmesg-before.txt"

# dyndbg: firmware handshakes, sensor configs and the firmware's own log lines
timeout 120 modprobe apple_isp dyndbg=+p > "$OUT/modprobe.txt" 2>&1
echo "modprobe exit $?" >> "$OUT/modprobe.txt"
sleep 3
dmesg > "$OUT/dmesg-after.txt"
grep -i -E 'apple-isp|isp@|isp:|dart|5828|fault|serror' "$OUT/dmesg-after.txt" > "$OUT/summary.txt"
grep -i -E 'isp|domain' /sys/kernel/debug/pm_genpd/pm_genpd_summary > "$OUT/genpd-after.txt" 2>&1

if command -v v4l2-ctl > /dev/null && [ -e /dev/video0 ]; then
	v4l2-ctl --list-devices > "$OUT/v4l2-devices.txt" 2>&1
	v4l2-ctl -d /dev/video0 --all > "$OUT/v4l2-all.txt" 2>&1
	v4l2-ctl -d /dev/video0 --list-formats-ext > "$OUT/v4l2-formats.txt" 2>&1
	if [ "${1:-}" = capture ]; then
		timeout 60 v4l2-ctl -d /dev/video0 \
			--set-fmt-video=width=1920,height=1080,pixelformat=NV12 \
			--stream-mmap --stream-count=1 --stream-to=/tmp/f.raw > "$OUT/capture.txt" 2>&1
		echo "capture exit $? size $(stat -c %s /tmp/f.raw 2>/dev/null) (1920x1080 NV12 = 3110400)" >> "$OUT/capture.txt"
		dmesg | tail -n 200 > "$OUT/dmesg-capture.txt"
	fi
else
	echo "no /dev/video0 or no v4l2-ctl (pacman -S v4l-utils)" > "$OUT/v4l2-devices.txt"
fi

rm -f "$MARK"; sync
echo "done: $OUT"; cat "$OUT/summary.txt" | tail -n 40
