#!/bin/sh
# vrrcadence-run.sh: two passes with the dcp events traced, then analyse. Root; the compositor must not hold the card.
#   pass 1 "cadence": swap events, phases vrr off/on at 45 41 30 24 20 15 fps and 90 50 (8 s each)
#   pass 2 "static":  ALL dcp events (callbacks, mailbox messages), the image held 30 s per phase, vrr 0 1 0 1, battery power sampled
# Output dir: ./vrrcadence-<time>/ with trace-cadence.txt, trace-static.txt, client-*.txt, dmesg.txt, verdict.txt
set -u
TR=/sys/kernel/tracing
OUT=./vrrcadence-$(date +%H%M%S); mkdir -p "$OUT"
HERE=$(dirname "$0")
BIN=$HERE/vrrcadence; [ -x "$BIN" ] || BIN=./vrrcadence
[ -d "$TR/events/dcp" ] || { echo "no dcp trace events under $TR (kernel without FTRACE?)"; exit 1; }
echo 0 > "$TR/tracing_on"; echo 65536 > "$TR/buffer_size_kb"
echo 0 > "$TR/events/dcp/enable"
echo "vrrcadence-run start ${OUT#./}" > /dev/kmsg

: > "$TR/trace"
for e in iomfb_swap_submit iomfb_swap_complete iomfb_swap_complete_info iomfb_vrr_timestamps; do echo 1 > "$TR/events/dcp/$e/enable"; done
echo 1 > "$TR/tracing_on"
timeout 250 "$BIN" -s 8 -o "$OUT/flip-intervals.csv" -p "${CADENCE:-0:45,1:45,0:41,1:41,0:30,1:30,0:24,1:24,0:20,1:20,0:15,1:15,0:90,1:90,0:50,1:50}" 2>&1 | tee "$OUT/client-cadence.txt"
echo 0 > "$TR/tracing_on"; cat "$TR/trace" > "$OUT/trace-cadence.txt"

: > "$TR/trace"
echo 0 > "$TR/events/dcp/iomfb_swap_complete_info/enable"
echo 1 > "$TR/events/dcp/enable"
echo 1 > "$TR/tracing_on"
timeout 200 "$BIN" -s 30 -p "${STATIC:-0:-1,1:-1,0:-1,1:-1}" 2>&1 | tee "$OUT/client-static.txt"
echo 0 > "$TR/tracing_on"; cat "$TR/trace" > "$OUT/trace-static.txt"
echo 0 > "$TR/events/dcp/enable"

dmesg | sed -n "/vrrcadence-run start ${OUT#./}/,\$p" > "$OUT/dmesg.txt"
grep -E "VRR_ENABLED|adaptive_sync|timed out|crashed|swap failed|watchdog|retraining" "$OUT/dmesg.txt" | cut -c1-220 > "$OUT/dmesg-vrr.txt"
python3 -I -B "$HERE/vrrcadence-analyze.py" "$OUT" | tee "$OUT/verdict.txt"
echo "files in $OUT"
