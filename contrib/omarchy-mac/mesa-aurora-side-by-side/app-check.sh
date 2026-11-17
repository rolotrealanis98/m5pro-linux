#!/bin/bash
# App regressions from gl-native/APP-REGRESSIONS.md under one Mesa tree (as the desktop user, one process each):
# Alacritty text, glmark2 scene, foot, kitty; a grim screenshot of each and the driver's own messages.
#   app-check.sh LABEL PREFIX zink|native
set -u
LABEL=$1; PREFIX=$2; MODE=$3
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/ab-env.sh" "$PREFIX" "$MODE"
export MESA_DEBUG=1 ASAHI_MESA_DEBUG=faulttrace
OUT=$HOME/gpu-ab/results/$LABEL/apps; mkdir -p "$OUT"; cd "$OUT"
KM0=$(dmesg | wc -l)
# Only the test window is captured (never the whole screen: it is the owner'"'"'s desktop).
shot() { # name delay classregex
  sleep "$2"
  local g; g=$(hyprctl -j clients 2>/dev/null | python3 -c "
import json,sys,re
c=[w for w in json.load(sys.stdin) if re.search(sys.argv[1],w['class'],re.I)]
w=c[-1] if c else None
print('%d,%d %dx%d'%tuple(w['at']+w['size']) if w else '')" "$3")
  [ -n "$g" ] && grim -g "$g" "$1.png" 2>>shots.err || echo "no window for $3" >> shots.err
}
run() { # name class seconds cmd...
  local n=$1 cls=$2 t=$3; shift 3
  ( shot "$n" 3 "$cls" ) & timeout "$t" "$@" > "$n.log" 2>&1; echo "$n rc=$?" >> apps.txt; wait
  new=$(dmesg | sed -n "$((KM0+1)),\$p" | grep -iE 'aurora|asahi|drm|gpu' | grep -iE 'fault|timed out|timeout|hang|recover|submit failed|ENODATA|lost device')
  KM0=$(dmesg | wc -l); [ -n "$new" ] && { echo "FAULT during $n: $new" >> apps.txt; exit 3; }
}
: > apps.txt
run alacritty alacritty 7 alacritty -e sh -c 'echo "ALACRITTY TEXT TEST abcdefghijklmnop 0123456789"; ls /opt; sleep 6'
run glmark2 glmark2 8 glmark2-es2-wayland --size 800x600 -b build:duration=6
run foot foot 7 foot sh -c 'echo "FOOT TEXT TEST 0123456789"; sleep 6'
run kitty kitty 7 kitty sh -c 'echo "KITTY TEXT TEST 0123456789"; sleep 6'
echo DONE >> apps.txt
