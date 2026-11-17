#!/bin/bash
# Runtime A/B of a GPU power knob on the J716s; root only. Interleaved A,B per load and round.
# Every knob is put back to the value it had at the start, whatever happens.
#   ab.sh OUTDIR ROUNDS SECONDS KNOB "VAL_A VAL_B" LOAD...
#   KNOB: gpu_floor (CLPC module parameter) | idle_off_delay_ms (drm device attribute)
#         | any other writable file given by absolute path
# Output: OUTDIR/<load>-<val>-r<round>.tsv (samp.py) and .out (the load's own lines).
set -u
OUT=$1; ROUNDS=$2; T=$3; KNOB=$4; VALS=$5; shift 5
D=/home/rolo/gpu-ab/power2
case "$KNOB" in
  gpu_floor) F=/sys/module/clpc/parameters/gpu_floor ;;
  idle_off_delay_ms) F=/sys/class/drm/card0/device/idle_off_delay_ms ;;
  /*) F=$KNOB ;;
  *) echo "unknown knob" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
exec 9>/home/rolo/gpu-ab/.gpu-window.lock
flock -w 600 9 || { echo "GPU window lock busy" >&2; exit 1; }
ORIG=$(cat "$F")
restore() { echo "$ORIG" > "$F"; echo "restored $F=$(cat "$F")" | tee -a "$OUT/log"; }
trap restore EXIT
trap 'exit 130' INT TERM
echo "$(date -u +%FT%TZ) knob $F orig=$ORIG vals=$VALS rounds=$ROUNDS T=$T loads=$*" | tee -a "$OUT/log"
KM0=$(dmesg | wc -l)
for ((r = 1; r <= ROUNDS; r++)); do
  for L in "$@"; do
    for v in $VALS; do
      echo "$v" > "$F"
      sleep 2
      python3 -I $D/samp.py "$T" 1 > "$OUT/$L-$v-r$r.tsv" &
      sp=$!
      bash $D/load.sh "$L" "$OUT/$L-$v-r$r.out" "$T"
      wait $sp
      echo "$(date -u +%T) $L $v r$r done" >> "$OUT/log"
      new=$(dmesg | sed -n "$((KM0 + 1)),\$p" | grep -iE 'aurora|asahi|g17|gpu' | grep -iE 'fault|timeout|timed out|recover|crash|in-fence')
      KM0=$(dmesg | wc -l)
      if [ -n "$new" ]; then echo "GPU kernel lines, stopping:"; echo "$new" | tee -a "$OUT/log"; exit 3; fi
    done
  done
done
echo DONE >> "$OUT/log"
