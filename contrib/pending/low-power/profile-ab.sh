#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# profile-ab.sh [seconds] - idle power per power profile (balanced, performance, power-saver, balanced), PSTR median
# at 1 Hz plus one SMC package reading (PHPC) per phase. Root. Restores the profile it found.
set -u
export LC_ALL=C
S=${1:-30}
P=$(for l in /sys/class/hwmon/hwmon*/power*_label; do [ "$(cat "$l")" = "Total System Power" ] && echo "${l%_label}_input"; done | head -1)
old=$(powerprofilesctl get); trap 'powerprofilesctl set "$old"' EXIT
med() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
for p in balanced performance power-saver balanced; do
    powerprofilesctl set "$p"; sleep 5
    f=$(mktemp); for i in $(seq 1 "$S"); do cat "$P" >> "$f"; sleep 1; done
    phpc=$(timeout 20 cat /sys/kernel/debug/macsmc-hwmon/keys 2>/dev/null | awk '$2=="PHPC"{print $NF}')
    echo "$p: PSTR median $(med < "$f" | awk '{printf "%.0f", $1/1000}') mW, PHPC $phpc mW, dpms $(cat /sys/class/drm/card*-eDP-*/dpms), cur $(cat /sys/devices/system/cpu/cpufreq/policy{0,6,12}/scaling_cur_freq | tr '\n' ' ')"
    rm -f "$f"
done
