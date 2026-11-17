#!/bin/bash
# Attended, ON-SCREEN repro of the Obsidian native-GL black rectangle (BUG-aurora-mesa-electron-native-gl.md).
# Needs the owner present: the bug only shows on a VISIBLE window (a hidden workspace does not repaint).
# The script never switches workspaces or focus. It launches every throwaway window on workspace 5 silently and
# asks the OWNER to switch to workspace 5 and leave it there; it pauses whenever workspace 5 is not the active one.
#
#   sudo bash /home/rolo/gpu-ab/obs/attended-visible.sh [N]        # N launches per variant (default 10)
#
# Variants (N each, interleaved so drift hits all equally), throwaway profile/vault only, ~15 s per launch:
#   default            native GL, faulttrace logging (control: expected ~10-20% black-hole rate)
#   sync               ASAHI_MESA_DEBUG=sync        -> clean means an early presentation fence (hypothesis 1)
#   nocompress         ASAHI_MESA_DEBUG=nocompress  -> clean means stale compressed contents on partial redraw (2)
#   noshadow           ASAHI_MESA_DEBUG=noshadow    -> clean means resource shadowing / BO replacement (2)
#   partial-swap-off   --ui-disable-partial-swap    -> clean means the partial-redraw path (2), Chrome-side workaround
#   zink (N/2)         MESA_LOADER_DRIVER_OVERRIDE=zink  (control: expected clean)
# Each launch: map, float, four resizes, 4 s settle, window-only capture (grim -T), black fraction; stops on any GPU fault.
# Result: /home/rolo/gpu-ab/obs/results/attended-<time>/summary.txt
set -u
N=${1:-10}
B=/home/rolo/gpu-ab/obs
T=attended-$(date +%Y%m%d-%H%M%S); R=$B/results/$T; mkdir -p "$R"; chown rolo:rolo "$R"
HIS=$(ls -t /run/user/1001/hypr | head -1)
hy() { runuser -u rolo -- env XDG_RUNTIME_DIR=/run/user/1001 HYPRLAND_INSTANCE_SIGNATURE=$HIS hyprctl "$@"; }
U="obsidian://open?vault=vault&file=Welcome"
# run5.sh evaluates POST after the window mapped; PID and OUT are set there
export POST='W="window = \"pid:$PID\""; hyprctl dispatch "hl.dsp.window.float({ action = \"on\", $W })" >/dev/null; sleep 0.5
  for s in "1000, y = 700" "1100, y = 780" "900, y = 640" "1000, y = 700"; do hyprctl dispatch "hl.dsp.window.resize({ x = $s, $W })" >/dev/null; sleep 0.7; done; sleep 4'
echo "Switch to workspace 5 yourself and keep it visible (the test windows open there). Ctrl-C stops."
wait_ws5() {
  local warned=
  until hy activeworkspace -j | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["id"]==5 else 1)'; do
    [ -z "$warned" ] && echo "waiting: workspace 5 is not visible (switch to it to continue)" && warned=1; sleep 2
  done
}
run() { # label var... -- args...
  local label=$1; shift
  wait_ws5
  runuser -u rolo -- env POST="$POST" flock /home/rolo/gpu-ab/.gpu-window.lock bash $B/run5.sh "$T/$label" 8 "$@" | tee -a "$R/runs.txt"
  if ls "$B/results/$T/$label/FAULT" >/dev/null 2>&1; then echo "STOP: GPU fault after $label"; exit 3; fi
  sleep 2
}
for i in $(seq 1 "$N"); do
  run default-$i -- "$U"
  run sync-$i ASAHI_MESA_DEBUG=sync -- "$U"
  run nocompress-$i ASAHI_MESA_DEBUG=nocompress -- "$U"
  run noshadow-$i ASAHI_MESA_DEBUG=noshadow -- "$U"
  run partial-swap-off-$i -- --ui-disable-partial-swap "$U"
  [ $((i % 2)) = 0 ] && run zink-$i MESA_LOADER_DRIVER_OVERRIDE=zink -- "$U"
done
# a run shows the bug when more than 2% of the window is pure black (Obsidian's theme never uses #000)
python3 - "$R/runs.txt" > "$R/summary.txt" <<'EOF'
import re, sys, collections
c = collections.defaultdict(lambda: [0, 0, 0])
for line in open(sys.argv[1]):
    m = re.match(r'\S*/(\S+?)-\d+ .*?black=([0-9.]+)', line)
    if not m:
        n = re.match(r'\S*/(\S+?)-\d+ ', line)
        if n: c[n.group(1)][2] += 1
        continue
    v = c[m.group(1)]; v[0] += 1; v[1] += float(m.group(2)) > 0.02
for k, (runs, bad, nocap) in c.items():
    print(f"{k:18} {bad}/{runs} with a black hole" + (f", {nocap} without a capture" if nocap else ""))
EOF
cat "$R/summary.txt"; chown -R rolo:rolo "$R"
