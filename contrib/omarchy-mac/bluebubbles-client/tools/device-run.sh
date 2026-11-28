#!/bin/bash
# THE device run: startup, idle, scroll, frame pacing, memory and the size comparison, upstream against our build.
# Run it from the Studio when the Mac may be used (it is NOT run by the build). Everything on the Mac goes through
# the bench ssh wrapper under /Volumes/m5pro/bench/.mac-lock, one step at a time.
#
#   contrib/omarchy-mac/bluebubbles-client/tools/device-run.sh [--runs 3] [--conversation FX,FY] [--no-base]
#
#   --conversation FX,FY  also open one chat (a click at that fraction of the window, FX,FY in 0..1: pick a chat with NO
#                         unread messages, so opening it changes nothing) and scroll its conversation. Never types,
#                         reacts, sends or marks anything. Without it only the chat list is scrolled.
#   --no-base             skip the "base" build (upstream tag plus diagnostics only)
#
# Before: build/install the two side copies' tarballs on the Studio (see README "Device run"):
#   build.sh                      -> out/bluebubbles-linux-aarch64-m5pro-client-<commit>.tar.gz   (ours, slim)
#   build.sh diag-base            -> out/bluebubbles-linux-aarch64-diag-base-<commit>.tar.gz      (upstream tag + BBDIAG marks only)
# The newest tarball of each kind is used.
# Runs: upstream (the installed ~/.local/opt/bluebubbles, no diagnostics), base, client; N full runs each plus one
# Wayland-traced run each. It closes a running BlueBubbles first and starts the default one again at the end.
# Output: results/<stamp>/*.json, summary.md, and screenshots copied to /Volumes/m5pro/bench/bluebubbles/shots/
# (they show private conversations: never publish them). Nothing is deleted anywhere.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
MBP=${MBP:-/Volumes/m5pro/bench/session-20261123/mbp}; LOCK=/Volumes/m5pro/bench/.mac-lock
OUT=${OUT:-/Volumes/m5pro/bluebubbles/out}; SHOTS=/Volumes/m5pro/bench/bluebubbles/shots
RUNS=3; CONV=""; BASE=1
while [ $# -gt 0 ]; do case "$1" in
  --runs) RUNS=$2; shift 2 ;; --conversation) CONV=$2; shift 2 ;; --no-base) BASE=0; shift ;;
  *) echo "unknown option $1" >&2; exit 2 ;; esac; done
mac() { lockf -t 1800 "$LOCK" "$MBP" "$@"; }
STAMP=$(date +%Y%m%d-%H%M); RES="$ROOT/results/$STAMP"; mkdir -p "$RES" "$SHOTS"
BENCH=/home/rolo/.local/share/bluebubbles-bench

echo "== preflight"; mac 'echo mac up: $(uptime -p)'
for f in bb-measure.py bb-launch.py gtk-ref.py; do mac "mkdir -p $BENCH && cat > $BENCH/$f" < "$HERE/$f"; done

echo "== close the running app (it will be started again at the end)"
WAS_RUNNING=$(mac 'pgrep -x bluebubbles >/dev/null && echo 1 || echo 0')
mac 'pkill -TERM -x bluebubbles; sleep 3; pgrep -x bluebubbles >/dev/null && echo "still running" >&2 && exit 1; exit 0'

echo "== install side copies (the wrapper and the default install are not touched)"
LABELS=(upstream)
if [ "$BASE" = 1 ]; then BB_DEST=bluebubbles-m5pro-bench-base-$STAMP "$ROOT/install.sh" "$(ls -t "$OUT"/bluebubbles-linux-aarch64-diag-base-*.tar.gz | head -1)" "base-$STAMP"; LABELS+=(base); fi
BB_DEST=bluebubbles-m5pro-bench-client-$STAMP "$ROOT/install.sh" "$(ls -t "$OUT"/bluebubbles-linux-aarch64-m5pro-client-*.tar.gz | head -1)" "client-$STAMP"; LABELS+=(client)
dir_of() { case $1 in upstream) echo /home/rolo/.local/opt/bluebubbles;; base) echo /home/rolo/.local/opt/bluebubbles-m5pro-bench-base-$STAMP;; client) echo /home/rolo/.local/opt/bluebubbles-m5pro-bench-client-$STAMP;; esac; }

measure() { # label name extra-args...
  local label=$1 name=$2; shift 2
  echo "-- $name"
  mac "python3 $BENCH/bb-measure.py $(dir_of "$label") $name $*" > "$RES/$name.json"
  for shot in start after-scroll conversation compare; do
    if mac "test -f /tmp/bbshots-$name/$shot.png"; then mac "cat /tmp/bbshots-$name/$shot.png" > "$SHOTS/$STAMP-$name-$shot.png"; fi
  done
}
CONVARG=""; [ -n "$CONV" ] && CONVARG="--conversation=$CONV"
for label in "${LABELS[@]}"; do
  for n in $(seq 1 "$RUNS"); do measure "$label" "$label-$n" $CONVARG; done
  measure "$label" "$label-wl" --noidle --wldebug $CONVARG
done
echo "== size comparison against a plain GTK window (client)"
measure client "client-ref" --noidle --ref
# (the -ref run is a screenshot run; its name has no -N / -wl suffix, so the table ignores it)

echo "== start the default app again"
[ "$WAS_RUNNING" = 1 ] && mac "python3 $BENCH/bb-launch.py" || true
python3 "$HERE/bb-summary.py" "$RES" | tee "$RES/summary.md"
echo "results: $RES   screenshots: $SHOTS/$STAMP-*"
