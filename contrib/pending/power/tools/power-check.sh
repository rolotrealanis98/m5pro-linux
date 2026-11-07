#!/bin/sh
# power-check.sh - T6050 (J716s) cpufreq, PMC/CLPC and idle power checks. Read only,
# except phase C's load (plain user-space loops). Run as root on the daily.
#   power-check.sh info      cpufreq sysfs, driver lines, PMC/CLPC debugfs, zones
#   power-check.sh idle [s]  idle sample (default 60 s): power_now, PSTR, time_in_state deltas
#   power-check.sh load      per-cluster single-thread load and a memory copy, with readbacks
set -u
CF=/sys/devices/system/cpu/cpufreq
BAT=/sys/class/power_supply/macsmc-battery
DBG=/sys/kernel/debug

hwmon_power() {	# Total System Power (PSTR), in microwatts
	for h in /sys/class/hwmon/hwmon*; do
		for l in "$h"/power*_label; do
			[ -e "$l" ] || continue
			if [ "$(cat "$l")" = "Total System Power" ]; then
				cat "${l%_label}_input"; return
			fi
		done
	done
	echo 0
}

info() {
	echo "== kernel: $(uname -r)"; echo "== cmdline: $(cat /proc/cmdline)"
	for p in 0 6 12; do
		d=$CF/policy$p
		echo "== policy$p: driver $(cat $d/scaling_driver) gov $(cat $d/scaling_governor)" \
		     "cpuinfo $(cat $d/cpuinfo_min_freq)-$(cat $d/cpuinfo_max_freq)" \
		     "scaling $(cat $d/scaling_min_freq)-$(cat $d/scaling_max_freq)" \
		     "cur(req) $(cat $d/scaling_cur_freq) cur(hw) $(cat $d/cpuinfo_cur_freq 2>/dev/null)"
		echo "   available: $(cat $d/scaling_available_frequencies)"
		echo "   boost freqs: $(cat $d/scaling_boost_frequencies 2>/dev/null)"
		echo "   transition latency $(cat $d/cpuinfo_transition_latency) ns"
	done
	echo "== boost: $(cat $CF/boost 2>/dev/null)"
	echo "== sugov threads (none expected with fast switch):"; ps -eo comm | grep -c '^sugov' || true
	echo "== dmesg:"; dmesg | grep -E 'apple-cpufreq|cpufreq|DVFS|apple-pmc|pmc|clpc|thermal|macsmc_soc_die|pressure' | tail -40
	echo "== PMC:"; for f in $DBG/apple-pmc/*/status; do echo "-- $f"; cat "$f"; done 2>/dev/null
	echo "== CLPC:"; for f in $DBG/*performance-controller*/status $DBG/*clpc*/status; do [ -e "$f" ] && { echo "-- $f"; cat "$f"; }; done
	echo "== zones:"; for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp 2>/dev/null) $(cat $z/policy 2>/dev/null)"; done
	echo "== thermal_pressure_level: $(cat /sys/class/hwmon/hwmon*/device/thermal_pressure_level 2>/dev/null)"
}

tis() {	# policy -> "freq:ticks ..." snapshot
	tr '\n' ' ' < $CF/policy$1/stats/time_in_state
}

idle() {
	secs=${1:-60}
	echo "== idle sample ${secs}s: $(cat $BAT/status 2>/dev/null), keep hands off"
	for p in 0 6 12; do eval "t0_$p=\"\$(tis $p)\""; done
	n=0; sb=0; ss=0; minb=999999999; maxb=0
	while [ $n -lt "$secs" ]; do
		b=$(cat $BAT/power_now 2>/dev/null || echo 0); b=${b#-}
		s=$(hwmon_power)
		sb=$((sb + b)); ss=$((ss + s)); n=$((n + 1))
		[ "$b" -lt "$minb" ] && minb=$b; [ "$b" -gt "$maxb" ] && maxb=$b
		sleep 1
	done
	echo "battery power_now mean $((sb / n / 1000)) mW (min $((minb / 1000)) max $((maxb / 1000)))"
	echo "PSTR mean $((ss / n / 1000)) mW"
	for p in 0 6 12; do
		eval "a=\"\$t0_$p\""; b="$(tis $p)"
		echo "policy$p time_in_state delta (10 ms units):"
		echo "$a" "|" "$b" | awk '{s=1; for(i=1;i<=NF;i++){ if($i=="|"){s=2;continue} split($i,x,":"); if(s==1)a[x[1]]=x[2]; else d[x[1]]=x[2]-a[x[1]] } for(f in d) if(d[f]>0) printf "  %s kHz: %d\n", f, d[f] }' | sort -n -k1
	done
}

spin() {	# spin on CPU $1 for $2 s
	taskset -c "$1" sh -c "end=\$((\$(date +%s) + $2)); while [ \$(date +%s) -lt \$end ]; do :; done" &
}

load() {
	for c in 0 6 12; do
		p=$c
		spin $c 10; sleep 5
		echo "cpu$c loaded: req $(cat $CF/policy$p/scaling_cur_freq) hw $(cat $CF/policy$p/cpuinfo_cur_freq 2>/dev/null)"
		[ -x ./cpuhz ] && ./cpuhz $c
		[ -x ./dvfs-regs ] && ./dvfs-regs
		wait
	done
	echo "== memory copy, all clusters busy (CLPC floors should rise):"
	for c in $(seq 0 17); do spin $c 20; done; sleep 2
	cat $DBG/apple-pmc/*/status 2>/dev/null
	for f in $DBG/*performance-controller*/status; do [ -e "$f" ] && cat "$f"; done
	command -v perf >/dev/null && perf bench mem memcpy -s 1GB -l 5 2>&1 | tail -3
	wait
	echo "== after the load (floors released within ~32 ms):"; sleep 1
	cat $DBG/apple-pmc/*/status 2>/dev/null
	dmesg | grep -E 'DVFS|stopping requests' | tail -5
}

case "${1:-info}" in
info) info ;;
idle) idle "${2:-60}" ;;
load) load ;;
*) echo "usage: $0 info|idle [secs]|load"; exit 2 ;;
esac
