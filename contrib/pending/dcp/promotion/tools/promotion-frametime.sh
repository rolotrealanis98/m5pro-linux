#!/bin/sh
# promotion-frametime.sh [SECONDS] : swap completion cadence of the internal panel's DCP.
# Records dcp:iomfb_swap_complete (and dcp:iomfb_vrr_timestamps, to show whether swaps carry
# presentation timestamps) for SECONDS (default 10) while something draws continuously
# (modetest -v, vkcube, a moving window), then prints the completion rate and the interval
# spread. Root; needs tracefs. Only the busiest DCP (the internal panel's) is reported.
set -eu
secs=${1:-10}
T=/sys/kernel/tracing
[ -d $T/events/dcp ] || T=/sys/kernel/debug/tracing
[ -d $T/events/dcp ] || { echo "no dcp trace events (tracefs not mounted or appledrm not loaded)"; exit 1; }
echo 0 > $T/tracing_on
echo > $T/trace
echo 1 > $T/events/dcp/iomfb_swap_complete/enable
echo 1 > $T/events/dcp/iomfb_vrr_timestamps/enable
echo 1 > $T/tracing_on
sleep "$secs"
echo 0 > $T/tracing_on
echo 0 > $T/events/dcp/iomfb_swap_complete/enable
echo 0 > $T/events/dcp/iomfb_vrr_timestamps/enable
awk -v secs="$secs" '
/iomfb_vrr_timestamps:/ { stamped++ }
/iomfb_swap_complete:/ {
	for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+:$/) { t = substr($i, 1, length($i) - 1); break }
	match($0, /dcp=[0-9a-f]+/); d = substr($0, RSTART + 4, RLENGTH - 4)
	n[d]++; if (d in last) { dt = (t - last[d]) * 1000; iv[d, n[d]] = dt; sum[d] += dt } last[d] = t
}
END {
	best = ""; for (d in n) if (best == "" || n[d] > n[best]) best = d
	if (best == "" || n[best] < 3) { print "fewer than 3 swap completions: is anything drawing?"; exit 1 }
	m = n[best] - 1; k = 0
	for (i = 2; i <= n[best]; i++) v[++k] = iv[best, i]
	for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
	printf "dcp %s: %d completions in %d s = %.2f fps; interval ms mean %.3f p1 %.3f p50 %.3f p99 %.3f max %.3f\n",
		best, n[best], secs, n[best] / secs, sum[best] / m, v[int(k * 0.01) + 1], v[int(k * 0.5) + 1],
		v[int(k * 0.99) + 1 > k ? k : int(k * 0.99) + 1], v[k]
	b8 = b16 = b20 = bo = 0
	for (i = 1; i <= k; i++) { if (v[i] < 9.5) b8++; else if (v[i] < 18) b16++; else if (v[i] < 22) b20++; else bo++ }
	printf "intervals: <9.5 ms (120 Hz) %d, 9.5-18 ms (60-100 Hz) %d, 18-22 ms (48-50 Hz) %d, longer %d; timestamped swaps %d\n",
		b8, b16, b20, bo, stamped
}' $T/trace
