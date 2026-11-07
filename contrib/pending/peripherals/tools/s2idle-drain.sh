#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Measure the battery drain of one s2idle sleep on the J716s. Run as root on
# battery (charger unplugged), then wake the machine by lid or power button.
#
#   s2idle-drain.sh [logdir]        default logdir: /var/log/s2idle-drain
#
# Writes <logdir>/<start>.log with the battery and SMC power readings before
# and after, the suspended time from the kernel log, the wakeup sources and
# the average drain in watts. Prints the summary line at the end:
#   DRAIN slept=<s> dQ=<mAh> avgV=<V> avg=<W> capacity=<a>-><b>%
set -eu

LOGDIR=${1:-/var/log/s2idle-drain}
BAT=/sys/class/power_supply/macsmc-battery
AC=/sys/class/power_supply/macsmc-ac
mkdir -p "$LOGDIR"
START=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$LOGDIR/$START.log

snap() {
	echo "== $1 $(date -u +%FT%TZ)"
	for f in status capacity charge_now voltage_now current_now power_now; do
		[ -r "$BAT/$f" ] && echo "bat.$f=$(cat "$BAT/$f")"
	done
	[ -r "$AC/online" ] && echo "ac.online=$(cat "$AC/online")"
	# The SMC power channels (PSTR system total, PDTR DC in, PHPC CPU, ...)
	for h in /sys/class/hwmon/hwmon*; do
		[ "$(cat "$h/name" 2>/dev/null)" = macsmc_hwmon ] || continue
		for l in "$h"/power*_label; do
			[ -r "$l" ] || continue
			echo "smc.$(cat "$l")=$(cat "${l%_label}_input")"
		done
	done
}

if [ "$(cat "$AC/online" 2>/dev/null || echo 0)" = 1 ]; then
	echo "on AC: unplug the charger first" >&2
	exit 1
fi

{
	snap before
	echo "mem_sleep=$(cat /sys/power/mem_sleep)"
	cat /sys/power/suspend_stats/success 2>/dev/null | sed 's/^/suspend_stats.success=/'
} >"$LOG"

Q0=$(cat "$BAT/charge_now")
V0=$(cat "$BAT/voltage_now")
C0=$(cat "$BAT/capacity")
echo "S2IDLE-DRAIN start $START" >/dev/kmsg
echo s2idle >/sys/power/mem_sleep
sync
echo mem >/sys/power/state

# Back from sleep
{
	snap after
	echo "== kernel"
	dmesg | sed -n "/S2IDLE-DRAIN start $START/,\$p" | grep -E 'Timekeeping suspended|PM: suspend|wakeup|Wakeup|lid open' || true
	echo "== wakeup sources (active_count > 0)"
	awk 'NR == 1 || $2 > 0' /sys/kernel/debug/wakeup_sources 2>/dev/null || true
} >>"$LOG"

Q1=$(cat "$BAT/charge_now")
V1=$(cat "$BAT/voltage_now")
C1=$(cat "$BAT/capacity")
SLEPT=$(dmesg | sed -n "/S2IDLE-DRAIN start $START/,\$p" |
	sed -n 's/.*Timekeeping suspended for \([0-9.]*\) seconds.*/\1/p' | tail -1)
[ -n "$SLEPT" ] || SLEPT=0

# charge_now is in uAh, voltage_now in uV
awk -v q0="$Q0" -v q1="$Q1" -v v0="$V0" -v v1="$V1" -v s="$SLEPT" -v c0="$C0" -v c1="$C1" 'BEGIN {
	dq = (q0 - q1) / 1000.0
	v = (v0 + v1) / 2e6
	w = (s > 0) ? (dq / 1000.0) * v / (s / 3600.0) : 0
	printf "DRAIN slept=%.0f dQ=%.1f avgV=%.3f avg=%.2f capacity=%d->%d%%\n", s, dq, v, w, c0, c1
}' | tee -a "$LOG"
