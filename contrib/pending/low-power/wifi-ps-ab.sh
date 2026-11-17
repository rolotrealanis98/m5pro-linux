#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wifi-ps-ab.sh - Wi-Fi power save A-B-A on the J716s with a revert timer. Run detached (setsid) as root:
#   setsid -f bash wifi-ps-ab.sh > /dev/null 2>&1 < /dev/null
# Two systemd timers turn power save back off (at +100 s and +200 s) whatever happens to this script or the SSH link.
# Output: /var/tmp/power1/wifips-<stamp>/result.txt
set -u
export LC_ALL=C
IF=${IF:-wlan0}
OUT=/var/tmp/power1/wifips-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"; exec > "$OUT/result.txt" 2>&1
P=$(for l in /sys/class/hwmon/hwmon*/power*_label; do [ "$(cat "$l")" = "Total System Power" ] && echo "${l%_label}_input"; done | head -1)
GW=$(ip -4 route show default dev "$IF" | awk '{print $3; exit}')
for t in 100 200; do systemd-run --quiet --on-active=$t --unit=m5pro-wifips-revert-$t /usr/bin/iw dev "$IF" set power_save off; done
phase() { # $1 label, $2 seconds
    local s=0 n=0 v
    echo "== $1: $(iw dev "$IF" get power_save)"
    ping -n -q -i 0.5 -w "$2" "$GW" 2>&1 | tail -2 &
    for i in $(seq 1 "$2"); do v=$(cat "$P"); s=$((s + v)); n=$((n + 1)); sleep 1; done
    wait
    echo "$1 PSTR mean $((s / n / 1000)) mW over $n s"
}
echo "gateway $GW, $(iw dev "$IF" link | grep -E 'SSID|freq|signal|tx bitrate' | tr '\n' ' ')"
phase off-1 25
iw dev "$IF" set power_save on; echo "set on rc=$?"; sleep 2
phase on 25
iw dev "$IF" link | grep -E 'SSID|signal' | tr '\n' ' '; echo
iw dev "$IF" set power_save off; echo "set off rc=$?"; sleep 2
phase off-2 25
for t in 100 200; do systemctl stop m5pro-wifips-revert-$t.timer 2>/dev/null; done
echo "final: $(iw dev "$IF" get power_save)"
touch "$OUT/DONE"
