#!/bin/sh
# vrrflip-run.sh [vrrflip args] : run vrrflip with dcp:iomfb_swap_complete traced, then count swap
# completions per phase (between the "vrrflip: phase <name>" trace markers). Root, no compositor on the
# card (run from a VT: systemctl stop the Hyprland session first). Output dir: ./vrrflip-<time>/.
set -u
TR=/sys/kernel/tracing
OUT=./vrrflip-$(date +%H%M%S); mkdir -p "$OUT"
BIN=$(dirname "$0")/vrrflip
[ -x "$BIN" ] || BIN=vrrflip
[ -d "$TR/events/dcp" ] || { echo "no dcp trace events under $TR"; exit 1; }
echo 0 > "$TR/tracing_on"; : > "$TR/trace"
for e in iomfb_swap_submit iomfb_swap_complete iomfb_vrr_timestamps; do
	[ -w "$TR/events/dcp/$e/enable" ] && echo 1 > "$TR/events/dcp/$e/enable"
done
echo "vrrflip-run start ${OUT#./}" > /dev/kmsg
echo 1 > "$TR/tracing_on"
"$BIN" -o "$OUT/intervals.csv" "$@" 2>&1 | tee "$OUT/vrrflip.txt"
RC=0; grep -q "result vrr-off-50" "$OUT/vrrflip.txt" || RC=1
echo 0 > "$TR/tracing_on"
cat "$TR/trace" > "$OUT/trace.txt"
dmesg | sed -n "/vrrflip-run start ${OUT#./}/,\$p" > "$OUT/dmesg.txt"
# swap completions per phase, and their spacing (ms) from the trace timestamps
awk '
/tracing_mark_write: vrrflip: phase / { ph = $NF; next }
/iomfb_swap_complete:/ && ph != "" {
	for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+:$/) { t = substr($i, 1, length($i) - 1); break }
	n[ph]++; if (last[ph] != "") { d = (t - last[ph]) * 1000; s[ph] += d; if (d > mx[ph]) mx[ph] = d; if (mn[ph] == "" || d < mn[ph]) mn[ph] = d }
	last[ph] = t; if (!(ph in seen)) { seen[ph] = 1; order[++k] = ph }
}
END { for (j = 1; j <= k; j++) { p = order[j]; printf "swap_complete %-11s %5d  mean %.2f ms  min %.2f  max %.2f\n", p, n[p], (n[p] > 1 ? s[p] / (n[p] - 1) : 0), mn[p], mx[p] } }
' "$OUT/trace.txt" | tee "$OUT/swap-complete.txt"
grep -E "VRR_ENABLED|adaptive_sync|set_digital_out_mode|timed out|crashed|swap failed|watchdog" "$OUT/dmesg.txt" | tee "$OUT/dmesg-vrr.txt"
echo "rc=$RC, files in $OUT"
exit $RC
