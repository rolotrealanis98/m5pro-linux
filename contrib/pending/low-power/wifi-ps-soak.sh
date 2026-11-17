#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wifi-ps-soak.sh [minutes] - Wi-Fi power save on for N minutes (default 10) with a ping log to the gateway, then
# leave it on only if no ping was lost and no disconnect was logged; otherwise turn it off. A systemd timer turns it
# off at N+2 minutes whatever happens. Run detached as root: setsid -f bash wifi-ps-soak.sh 10 >/dev/null 2>&1 </dev/null
set -u
export LC_ALL=C
IF=${IF:-wlan0}; MIN=${1:-10}
OUT=/var/tmp/power1/wifips-soak-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"; exec > "$OUT/result.txt" 2>&1
GW=$(ip -4 route show default dev "$IF" | awk '{print $3; exit}')
systemd-run --quiet --on-active=$(( (MIN + 2) * 60 )) --unit=m5pro-wifips-soak-revert /usr/bin/iw dev "$IF" set power_save off
since=$(date '+%F %T')
iw dev "$IF" set power_save on; echo "on rc=$? at $since, gateway $GW"
ping -n -D -i 1 -w $((MIN * 60)) "$GW" > "$OUT/ping.txt" 2>&1
tail -2 "$OUT/ping.txt"
loss=$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' "$OUT/ping.txt")
disc=$(journalctl --since "$since" --no-pager -o cat -u NetworkManager 2>/dev/null | grep -ciE 'disconnect|deauth|state change: activated -> ')
kern=$(journalctl -k --since "$since" --no-pager -o cat | grep -ciE 'centauri.*(error|fail|timeout)')
echo "loss ${loss}% disconnect-lines $disc driver-errors $kern"
if [ "${loss%.*}" = 0 ] && [ "$disc" = 0 ] && [ "$kern" = 0 ]; then
    echo "KEEP: power save stays on until the next reconnect (iw dev $IF set power_save off to undo)"
    systemctl stop m5pro-wifips-soak-revert.timer
else
    iw dev "$IF" set power_save off; echo "REVERTED: $(iw dev "$IF" get power_save)"
fi
touch "$OUT/DONE"
