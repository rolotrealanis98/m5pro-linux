#!/bin/bash
# Idle A/B of kernel.sched_util_clamp_min_rt_default (needs CONFIG_UCLAMP_TASK: next4b and later). Root, no reboot,
# silent. Leave the laptop idle (lid open, screen static, no screensaver) for ~5 min. Restores 1024 and charging at the end.
set -u; S=/proc/sys/kernel/sched_util_clamp_min_rt_default
[ -w $S ] || { echo "no $S: kernel without UCLAMP_TASK"; exit 1; }
CB=$(ls /sys/class/power_supply/*/charge_behaviour 2>/dev/null | head -1); PN=$(ls /sys/class/power_supply/*/power_now 2>/dev/null | head -1)
old=$(cat $S); trap 'echo $old > $S; [ -n "$CB" ] && echo auto > $CB' EXIT
[ -n "$CB" ] && echo force-discharge > $CB; sleep 5
snap() { for p in 0 12; do f=/sys/devices/system/cpu/cpufreq/policy$p/stats/time_in_state; echo "p$p $(tail -1 $f | cut -d' ' -f2) $(awk '{s+=$2}END{print s}' $f)"; done; }
for v in 1024 256 128 0; do
  echo $v > $S; sleep 5; pgrep -x ttfx >/dev/null && echo "WARNING: screensaver running, phase not idle"
  a=$(snap); w=0; n=0; for i in $(seq 1 12); do sleep 5; x=$(cat $PN 2>/dev/null); [ -n "$x" ] && { w=$((w + ${x#-})); n=$((n+1)); }; done; b=$(snap)
  echo "$a" > /tmp/a; echo "$b" > /tmp/b
  share=$(paste /tmp/a /tmp/b | awk '{printf "%s top %.0f%%  ", $1, 100*($5-$2)/($6-$3)}')
  echo "rt_default=$v: $share avg power $( [ $n -gt 0 ] && echo "$((w / n / 1000)) mW" || echo n/a)"
done
echo "restored $old; sgv2: $(systemctl is-active speakerguardd-v2)"
