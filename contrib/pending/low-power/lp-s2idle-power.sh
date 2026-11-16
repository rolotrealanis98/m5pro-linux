#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lp-s2idle-power.sh - s2idle power on the J716s from the SMC battery's averaged power (B0AP = power_now), plus
# the panel's and the radios' share, and why idle parking does not engage. Low-power branch kernels only (needs
# apple_wdt.s2idle_wake_s for the timer wake).
#
# Why this way: charge_now/energy_now come from B0RM, the gauge's remaining-capacity estimate, which jumps by
# tens of mAh between reads and cannot integrate a 150 s sleep. power_now (B0AP) is an average: right after a
# wake it still holds mostly the sleep. The run measures how fast B0AP follows a step (charger to battery, awake),
# then samples it at 2 Hz for 40 s after each sleep; the value at the wake, extrapolated with that time constant,
# is the sleep's power.
#
# Results: /var/tmp/lowpower/s2p-<time>/ (summary.txt first), DONE at the end. About 14 min. Silent.
set -u
export LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -e /sys/module/apple_wdt/parameters/s2idle_wake_s ] || { echo "kernel has no s2idle wake timer" >&2; exit 1; }
OUT=/var/tmp/lowpower/s2p-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
exec > >(tee -a "$OUT/log.txt") 2>&1
SUM=$OUT/summary.txt
sum() { echo "$*" | tee -a "$SUM"; }
kmsg() { echo "lowpower: $*" > /dev/kmsg 2>/dev/null || true; }
rd() { cat "$1" 2>/dev/null || echo NA; }

HW_SYS=""
for l in /sys/class/hwmon/hwmon*/power*_label; do
    [ "$(cat "$l" 2>/dev/null)" = "Total System Power" ] && HW_SYS=${l%_label}_input
done
BAT=""; for p in /sys/class/power_supply/*; do [ "$(cat "$p/type" 2>/dev/null)" = Battery ] && BAT=$p; done
BL=$(command ls -d /sys/class/backlight/* 2>/dev/null | head -1)
POLICIES=$(command ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null)
[ -n "$BAT" ] && grep -q force-discharge "$BAT/charge_behaviour" || { echo "no force-discharge" >&2; exit 1; }
CB_OLD=$(sed -n 's/.*\[\([a-z-]*\)\].*/\1/p' "$BAT/charge_behaviour")
BL_OLD=$(cat "$BL/brightness"); BL_HALF=$(( $(cat "$BL/max_brightness") / 2 ))
RF_OLD=$(timeout 5 rfkill -rn -o ID,SOFT 2>/dev/null)

restore() {
    echo "${CB_OLD:-auto}" > "$BAT/charge_behaviour" 2>/dev/null
    echo "$BL_OLD" > "$BL/brightness" 2>/dev/null
    echo 0 > /sys/module/apple_wdt/parameters/s2idle_wake_s 2>/dev/null
    echo "$RF_OLD" | while read -r id soft; do
        [ "$soft" = unblocked ] && timeout 5 rfkill unblock "$id" 2>/dev/null
    done
    true
}
trap 'restore' EXIT

parks() { for p in $POLICIES; do echo "  $1 $(basename "$p"): $(rd "$p/park_stats")"; done | tee -a "$SUM"; }

# Charger-side system power (PSTR) at 1 Hz for $2 s
pstr() {
    local lbl=$1 secs=$2 i f=$OUT/pstr-$1.txt
    for i in $(seq 1 "$secs"); do echo "$(date +%s.%N | cut -c1-14) $(rd "$HW_SYS")" >> "$f"; sleep 1; done
    awk -v l="$lbl" '{ s += $2; n++ } END { printf "%s: system (PSTR) %.3f W over %d s\n", l, s / n / 1e6, n }' "$f" | tee -a "$SUM"
}

# Battery power_now (B0AP), current_now (B0AC), voltage and PSTR every $3 s for $2 s
bat() {
    local lbl=$1 secs=$2 step=$3 f=$OUT/bat-$1.txt t0 now
    t0=$(date +%s.%N)
    echo "# t_rel power_uW current_uA voltage_uV sys_uW" > "$f"
    while :; do
        now=$(date +%s.%N)
        awk -v a="$t0" -v b="$now" -v p="$(rd "$BAT/power_now")" -v c="$(rd "$BAT/current_now")" \
            -v v="$(rd "$BAT/voltage_now")" -v s="$(rd "$HW_SYS")" 'BEGIN { printf "%.2f %s %s %s %s\n", b - a, p, c, v, s }' >> "$f"
        awk -v a="$t0" -v b="$now" -v m="$secs" 'BEGIN { exit !(b - a < m) }' || break
        sleep "$step"
    done
}

sleep_once() {   # label seconds
    local lbl=$1 w=$2 t0 t1 rc
    echo 25 > /sys/module/apple_wdt/parameters/s2idle_fallback_s
    echo "$w" > /sys/module/apple_wdt/parameters/s2idle_wake_s
    local p0; p0=$(rd "$BAT/power_now")
    kmsg "s2p $lbl enter"; sync; sleep 1
    t0=$(date +%s.%N)
    echo freeze > /sys/power/state; rc=$?
    t1=$(date +%s.%N)
    bat "$lbl-after" 40 0.5
    echo 0 > /sys/module/apple_wdt/parameters/s2idle_wake_s
    kmsg "s2p $lbl back rc=$rc"
    dmesg | awk -v m="lowpower: s2p $lbl enter" 'index($0, m) { p = 1 } p' > "$OUT/dmesg-$lbl.txt"
    sum "$lbl: rc=$rc, $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') s wall, $(grep -c 'woken by the wake timer' "$OUT/dmesg-$lbl.txt") timer wake; power_now before $p0 uW; after the wake (t s: W):"
    awk 'NR > 1 && (NR <= 7 || NR % 10 == 2) { printf "    %s s: %.2f W (current %.2f A)\n", $1, $2 / 1e6, $3 / 1e6 }' "$OUT/bat-$lbl-after.txt" | tee -a "$SUM"
}

sum "kernel $(uname -r), backlight $(basename "$BL") $BL_HALF/$(cat "$BL/max_brightness"), rfkill: $(echo "$RF_OLD" | tr '\n' ' ')"
echo "$BL_HALF" > "$BL/brightness"
parks start

# 1. Awake on the charger: the panel's share, and parking
kmsg "s2p awake"
sleep 20
pstr awake-panel 60
parks after-60s-idle
echo 0 > "$BL/brightness"; sleep 3
pstr awake-backlight0 30
echo "$BL_HALF" > "$BL/brightness"; sleep 3

# 2. B0AP's response to a step: charger to battery, awake
echo force-discharge > "$BAT/charge_behaviour"
bat step 60 1
awk 'NR > 1 { printf "    %s s: %.2f W\n", $1, $2 / 1e6 }' "$OUT/bat-step.txt" | awk 'NR % 5 == 1' | tee -a "$SUM"
sum "  step: power_now 1 Hz after force-discharge (the time it takes to settle is B0AP's averaging)"

# 3. Sleeps on the battery: default, radios off, default again
sleep_once sleep-default-1 150
timeout 5 rfkill block all
sleep 10
sum "radios: $(timeout 5 rfkill -rn -o TYPE,SOFT 2>/dev/null | tr '\n' ' ')"
sleep_once sleep-radios-off 150
timeout 5 rfkill unblock all
sleep 15
sleep_once sleep-default-2 150

echo "$CB_OLD" > "$BAT/charge_behaviour"
sum "charge_behaviour back to $(cat "$BAT/charge_behaviour")"
parks end

# Health after
{
    for c in /sys/class/drm/card*-eDP-*; do echo "$(basename "$c"): $(rd "$c/status") $(rd "$c/enabled") dpms=$(rd "$c/dpms")"; done
    ip -br addr 2>/dev/null | grep -E 'wl|enu'
    echo "bt: $(command ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')"
    echo "superspeed: $(grep -lE '^(5000|10000|20000)$' /sys/bus/usb/devices/*/speed 2>/dev/null | sed 's|/speed||; s|.*/||' | tr '\n' ' ')"
    echo "pci devices: $(timeout 5 lspci 2>/dev/null | wc -l)"
    for t in /sys/class/typec/port*; do echo "$(basename "$t"): $(rd "$t/data_role") partner $([ -d "$t/$(basename "$t")-partner" ] && echo yes || echo no)"; done
    echo "suspend_stats: success=$(rd /sys/power/suspend_stats/success) fail=$(rd /sys/power/suspend_stats/fail) last_failed_dev=$(rd /sys/power/suspend_stats/last_failed_dev)"
} | sed 's/^/  health: /' | tee -a "$SUM"
dmesg > "$OUT/dmesg-full.txt"
restore
sum "done $(date +%T)"
touch "$OUT/DONE"
