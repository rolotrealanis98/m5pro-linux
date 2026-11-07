#!/bin/sh
# Read-only snapshot of cpufreq/cpuidle state on the M5 (T6050). Run as root.
# Usage: ./cpufreq-check.sh [dir-with-dvfs-regs]   (default: directory of this script)
D=${1:-$(dirname "$0")}
C=/sys/devices/system/cpu
echo "== cmdline";      cat /proc/cmdline
echo "== cpus";         echo "online $(cat $C/online)  nproc $(nproc)"
echo "== CPU part";     grep "CPU part" /proc/cpuinfo | sort | uniq -c
echo "== cpufreq dir";  ls $C/cpufreq
echo "== global boost"; cat $C/cpufreq/boost 2>/dev/null
for p in $C/cpufreq/policy*; do
	echo "== $(basename $p)"
	for f in scaling_driver affected_cpus related_cpus scaling_governor cpuinfo_min_freq \
		 cpuinfo_max_freq cpuinfo_transition_latency scaling_min_freq scaling_max_freq \
		 scaling_cur_freq cpuinfo_cur_freq boost scaling_available_frequencies \
		 scaling_boost_frequencies stats/total_trans; do
		[ -e $p/$f ] && printf '%-30s %s\n' "$f" "$(cat $p/$f)"
	done
done
echo "== cpuidle";      grep . $C/cpuidle/current_driver $C/cpuidle/current_governor_ro 2>/dev/null
ls -d $C/cpu0/cpuidle 2>/dev/null || echo "no $C/cpu0/cpuidle (expected)"
echo "== dmesg";        dmesg | grep -E "DVFS for CPUs|APSC|apple_soc_cpufreq|cpufreq|OPP table|not in the OPP table|ID_AA64ISAR2|WFx with timeout|cpuidle|Failed to reach power state|error -110"
echo "== raw DVFS";     [ -x "$D/dvfs-regs" ] && "$D/dvfs-regs" || echo "dvfs-regs not found in $D"
echo "== hwmon";        for h in /sys/class/hwmon/hwmon*; do [ -e $h/name ] && echo "$h $(cat $h/name)"; done
