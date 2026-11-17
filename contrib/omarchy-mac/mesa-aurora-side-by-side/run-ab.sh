#!/bin/bash
# One A/B configuration of the Aurora Mesa userspace on the MacBook, as the desktop user,
# never changing the session. Stops at the first GPU kernel fault.
#   run-ab.sh LABEL PREFIX zink|native [VAR=value ...]
# Run as the desktop user with XDG_RUNTIME_DIR/WAYLAND_DISPLAY set (see ab-env.sh).
# Output: ~/gpu-ab/results/LABEL/*.txt, *.jsonl, summary.txt
set -u
LABEL=$1; PREFIX=$2; MODE=$3; shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/ab-env.sh" "$PREFIX" "$MODE"
for kv in "$@"; do export "$kv"; done
OUT=$HOME/gpu-ab/results/$LABEL; rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"
FAULT_RE='GPU fault|page fault|crashed|runtime stopped|client failed|timed out|timeout|hang|recover|submit failed|ENODATA|lost device'
dm() { dmesg 2>/dev/null; }   # dmesg-unrestricted item: kernel.dmesg_restrict=0
KM0=$(dm | wc -l)
check() { # name
  local new; new=$(dm | sed -n "$((KM0+1)),\$p" | grep -iE 'aurora|asahi|drm|gpu' | grep -iE "$FAULT_RE")
  KM0=$(dm | wc -l)
  if [ -n "$new" ]; then echo "FAULT after $1:" | tee -a summary.txt; echo "$new" | tee -a summary.txt; echo "STOPPED" >> summary.txt; exit 3; fi
  echo "ok   $1 (no GPU kernel fault lines)" >> summary.txt
}
echo "label $LABEL prefix $PREFIX mode $MODE extra: $*" > summary.txt
echo "mesa commit $(cat $PREFIX/MESA_COMMIT 2>/dev/null)" >> summary.txt
vulkaninfo --summary > vulkaninfo.txt 2>&1; echo "vulkaninfo rc=$?" >> summary.txt; check vulkaninfo
eglinfo -B > eglinfo.txt 2>&1; check eglinfo
S=$(date +%s.%N); timeout 60 vkcube --wsi wayland --c 600 --present_mode 0 > vkcube.txt 2>&1; rc=$?; E=$(date +%s.%N)
echo "vkcube 600 frames immediate: rc=$rc $(python3 -c "w=$E-$S; print(f'wall={w:.2f}s fps={600/w:.1f}')")" | tee -a summary.txt; check vkcube
timeout 120 glmark2-es2-wayland --size 800x600 -b build:duration=5 -b texture:duration=5 -b shading:duration=5 \
  -b bump:duration=5 -b desktop:duration=5 -b buffer:duration=5 -b ideas:duration=5 -b terrain:duration=5 \
  -b jellyfish:duration=5 -b effect2d:duration=5 -b pulsar:duration=5 > glmark2.txt 2>&1; echo "glmark2 rc=$?" >> summary.txt
grep -E "glmark2 Score|FPS:|renderer|Renderer" glmark2.txt | sed 's/^ *//' >> summary.txt; check glmark2
for t in submit.empty render.light render.heavy compute.light compute.heavy copy.bw mem.buffer mem.image sync.signal; do
  timeout 120 /opt/gpubench/bin/gpubench-vk --test $t --depths 1,4,16 --runs 3 --run-ms 300 --warmup-ms 200 >> gpubench.jsonl 2> gpubench.err; echo "gpubench $t rc=$?" >> summary.txt
  check "gpubench $t"
done
echo DONE >> summary.txt
