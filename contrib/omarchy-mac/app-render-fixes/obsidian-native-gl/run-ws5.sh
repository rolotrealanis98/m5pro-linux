#!/bin/bash
# run5.sh LABEL SECONDS [VAR=val ...] -- [extra app args ...]
# ONE throwaway Obsidian/Chrome window on native GL (/opt/mesa-aurora-20261117) as rolo, launched by Hyprland on
# workspace 5 silently (never the owner's view). Capture = that toplevel only (grim -T stableId, ext-image-copy-capture),
# stderr with Mesa debug, dmesg delta. Run under flock /home/rolo/gpu-ab/.gpu-window.lock.
set -u
LABEL=$1; SECS=$2; shift 2
ENVS=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do ENVS+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift
B=/home/rolo/gpu-ab/obs; OUT=$B/results/$LABEL; rm -rf "$OUT"; mkdir -p "$OUT"
export XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-1
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1001/hypr | head -1)
APP=${APP:-obsidian}
case $APP in
  obsidian) UDD=$B/obsidian-test; ARGS=(/opt/obsidian/obsidian --user-data-dir=$UDD);;
  chrome)   UDD=/home/rolo/gpu-ab/chrome-test-obs; ARGS=(/opt/google/chrome/chrome --user-data-dir=$UDD --no-first-run --no-default-browser-check --mute-audio --password-store=basic --ozone-platform=wayland);;
  chromium) UDD=/home/rolo/gpu-ab/chromium-test-obs; ARGS=(/usr/lib/chromium/chromium --user-data-dir=$UDD --no-first-run --no-default-browser-check --mute-audio --password-store=basic --ozone-platform=wayland);;
esac
P=/opt/mesa-aurora-20261117
# Launcher: the full environment is written here, Hyprland only execs it (its own env is not used).
{
  echo '#!/bin/bash'
  echo "echo \$\$ > '$OUT/pid'"
  printf 'exec env -i HOME=/home/rolo USER=rolo LOGNAME=rolo PATH=/usr/local/bin:/usr/bin LANG=en_US.UTF-8 '
  printf '%q ' XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-1 DISPLAY=:0 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland \
    ELECTRON_OZONE_PLATFORM_HINT=wayland OZONE_PLATFORM=wayland XDG_CONFIG_HOME=$B/xdg \
    LD_LIBRARY_PATH=$P/lib __EGL_VENDOR_LIBRARY_FILENAMES=$P/share/glvnd/egl_vendor.d/50_aurora.json \
    __GLX_VENDOR_LIBRARY_NAME=aurora LIBGL_DRIVERS_PATH=$P/lib/dri GBM_BACKENDS_PATH=$P/lib/gbm \
    VK_DRIVER_FILES=$P/share/vulkan/icd.d/asahi_icd.aarch64.json VK_ICD_FILENAMES=$P/share/vulkan/icd.d/asahi_icd.aarch64.json \
    ASAHI_M5_BRINGUP=1 MESA_DEBUG=1 ASAHI_MESA_DEBUG=${DBG-faulttrace} "${ENVS[@]}" "${ARGS[@]}" --enable-logging=stderr "$@"
  echo " > '$OUT/stderr.log' 2>&1"
} > "$OUT/launch.sh"; chmod +x "$OUT/launch.sh"
KM0=$(dmesg | wc -l)
hyprctl dispatch "hl.dsp.exec_cmd(\"$OUT/launch.sh\", { workspace = \"5 silent\" })" > "$OUT/hypr.log" 2>&1
info() { hyprctl -j clients | python3 -c "
import json,sys
pid=int(sys.argv[1]); c=[w for w in json.load(sys.stdin) if w['pid']==pid]
print('%s %s %d,%d %dx%d'%((c[-1]['workspace']['name'],c[-1]['stableId'])+tuple(c[-1]['at']+c[-1]['size'])) if c else '')" "$1"; }
PID=; for i in $(seq 1 40); do [ -s "$OUT/pid" ] && PID=$(cat "$OUT/pid") && [ -n "$(info $PID)" ] && break; sleep 0.25; done
I=$( [ -n "$PID" ] && info $PID ); echo "$I" > "$OUT/window"
WS=${I%% *}
if [ -n "$I" ] && [ "$WS" != 5 ]; then echo "window NOT on workspace 5 ($I): closing" >> "$OUT/shot.err"; I=; fi
if [ -n "$I" ]; then
  sleep "$SECS"
  [ -n "${POST:-}" ] && eval "$POST"
  SID=$(echo "$I" | cut -d' ' -f2)
  grim -T "$SID" "$OUT/shot.png" 2>>"$OUT/shot.err"
  grim -T "$SID" -t ppm "$OUT/shot.ppm" 2>>"$OUT/shot.err" && python3 $B/blk.py "$OUT/shot.ppm" > "$OUT/black.txt"; rm -f "$OUT/shot.ppm"
fi
[ -n "$PID" ] && kill $PID 2>/dev/null; sleep 1; pkill -f -- "--user-data-dir=$UDD" 2>/dev/null; sleep 1; pkill -9 -f -- "--user-data-dir=$UDD" 2>/dev/null
dmesg | sed -n "$((KM0+1)),\$p" | grep -viE 'snd-soc|speakers-|macaudio|UFW|apple_sep' > "$OUT/dmesg.txt"
grep -iE 'fault|timed out|timeout|hang|recover|submit failed|lost device' "$OUT/dmesg.txt" && echo "GPU-FAULT" > "$OUT/FAULT"
printf '%s win=[%s] %s drops=%s profile=%s couldnot=%s refused=%s\n' "$LABEL" "$I" "$(cat $OUT/black.txt 2>/dev/null)" \
  "$(grep -c 'dropping' "$OUT/stderr.log" 2>/dev/null)" "$(grep -c 'native triangle profile' "$OUT/stderr.log" 2>/dev/null)" \
  "$(grep -c 'could not build' "$OUT/stderr.log" 2>/dev/null)" "$(grep -ci 'refused' "$OUT/stderr.log" 2>/dev/null)"
