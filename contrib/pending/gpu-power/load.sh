#!/bin/bash
# One GPU load for DURATION seconds, as the desktop user; root only. Window loads open on
# Hyprland workspace 5, silently (never the active workspace, no focus change), started by
# Hyprland itself; paced-* loads are headless (no window). Nothing plays sound.
#   load.sh NAME OUTFILE DURATION    (returns when the load has ended)
#   NAME: glmark-terrain | vkmark-cube | paced-finish | paced-flush | paced-heavy
# OUTFILE gets the load's own FPS/latency lines.
set -u
U=rolo
export XDG_RUNTIME_DIR=/run/user/1001
HIS=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
D=/home/rolo/gpu-ab/power2
hy() { runuser -u $U -- env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE=$HIS hyprctl "$@"; }
NAME=$1; OUT=$2; T=$3
MESA_ENV="$(grep -v '^#' /etc/mesa-aurora/session.env | xargs)"
: > "$OUT"; chown $U "$OUT"
win() { # command line: run through Hyprland on workspace 5 silently, wait for its end
  printf '#!/bin/bash\n%s > %s 2>&1\necho EXIT $? >> %s\n' "$1" "$OUT" "$OUT" > $D/cur-load.sh
  chown $U $D/cur-load.sh
  hy dispatch "hl.dsp.exec_cmd(\"bash $D/cur-load.sh\", {workspace = \"5 silent\"})" >/dev/null
  for ((i = 0; i < T + 20; i++)); do grep -q '^EXIT' "$OUT" && return 0; sleep 1; done
  pkill -f "^glmark2-es2-wayland --size 800x600" ; pkill -f "^vkmark --winsys wayland"
  echo "TIMEOUT" >> "$OUT"
}
paced() { runuser -u $U -- env $MESA_ENV $D/paced "$@" -s "$T" > "$OUT" 2>&1; }
case "$NAME" in
  glmark-terrain) win "glmark2-es2-wayland --size 800x600 -b terrain:duration=$T" ;;
  vkmark-cube)    win "vkmark --winsys wayland -p immediate -b cube:duration=$T" ;;
  paced-finish)   paced -f 60 -q 4 -i 64 -m finish ;;
  paced-flush)    paced -f 60 -q 4 -i 64 -m flush ;;
  paced-heavy)    paced -f 30 -q 8 -i 128 -m finish ;;
  idle)           sleep "$T" ;;
  *) echo "unknown load $NAME" >&2; exit 2 ;;
esac
