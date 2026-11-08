#!/usr/bin/env bash
# The gpu/faults STRESS.md mixed load for the MacBook (J716s), run from root or the session user:
#
#   stress-load.sh [SECONDS]        (default 600)
#
# Starts, as the Hyprland session user and inside its session: 3x `vkcube --wsi wayland`, glmark2-es2-wayland, the two
# Qt Quick windows (anim.qml: a continuously animated item; bar.qml: an item redrawn every 700 ms, the quickshell pattern;
# both need qml6, else they are skipped) and one Chromium tab on the WebGL aquarium (its own throwaway profile). After
# SECONDS (or on Ctrl-C/TERM) everything it started is stopped and the temp files removed. Pair with fault-watch.sh.
# Env knob: VKCUBES (default 3). Debug variables such as ASAHI_MESA_DEBUG exported before the call reach the clients.
#
# Session environment, the way run-recovery-test.sh / recovery-test.sh do it: /etc/mesa-aurora/session.env (the
# /opt/mesa-aurora zink + Borealis setup) first, then Hyprland's own /proc/<pid>/environ for the session variables,
# then WAYLAND_DISPLAY=wayland-1 and HYPRLAND_INSTANCE_SIGNATURE of the live instance.
set -u
SECS=${1:-600}; VKC=${VKCUBES:-3}
case $SECS in ''|*[!0-9]*) sed -n 2,14p "$0"; exit 2;; esac
HPID=$(pgrep -x Hyprland | head -1); [ -n "$HPID" ] || { echo "Hyprland not running"; exit 2; }
HUSER=$(ps -o user= -p "$HPID" | tr -d ' '); HUID=$(id -u "$HUSER")
XRD=/run/user/$HUID
SIG=$(for d in "$XRD"/hypr/*/; do p=$(head -1 "$d/hyprland.lock" 2>/dev/null); kill -0 "$p" 2>/dev/null && basename "$d"; done | head -1)
[ -n "$SIG" ] || { echo "no live Hyprland instance signature under $XRD/hypr"; exit 2; }

ENVV=()
for v in ASAHI_MESA_DEBUG HK_PERFTEST ZINK_DEBUG GALLIUM_THREAD; do [ -n "${!v:-}" ] && ENVV+=("$v=${!v}"); done
if [ -r /etc/mesa-aurora/session.env ]; then
  while IFS= read -r kv; do ENVV+=("$kv"); done < <(set -a; . /etc/mesa-aurora/session.env >/dev/null 2>&1; env | grep -E '^(LD_LIBRARY_PATH|LIBGL_DRIVERS_PATH|MESA_[A-Z_]+|VK_[A-Z_]+|__EGL_[A-Z_]+|ZINK_[A-Z_]+|HK_[A-Z_]+|ASAHI_[A-Z_]+|GALLIUM_[A-Z_]+|EGL_[A-Z_]+)=')
fi
# Hyprland's environment after session.env (env(1) keeps the last assignment); only the session variables
while IFS= read -r -d '' kv; do
  case $kv in
    WAYLAND_DISPLAY=*|XDG_*=*|DBUS_SESSION_BUS_ADDRESS=*|HOME=*|PATH=*|LANG=*|QT_*=*|LD_LIBRARY_PATH=*|LIBGL_DRIVERS_PATH=*|MESA_*=*|VK_*=*|__EGL_*=*|ZINK_*=*|HK_*=*|ASAHI_*=*|DISPLAY=*) ENVV+=("$kv");;
  esac
done < "/proc/$HPID/environ"
ENVV+=("WAYLAND_DISPLAY=wayland-1" "XDG_RUNTIME_DIR=$XRD" "HYPRLAND_INSTANCE_SIGNATURE=$SIG" "HOME=$(getent passwd "$HUSER" | cut -d: -f6)")
# The session may pin QT_QUICK_BACKEND=software for the bar (hypr-session); the QML windows here must use the GPU.
ENVV+=("QT_QUICK_BACKEND=rhi")
asuser() { if [ "$(id -u)" = 0 ]; then runuser -u "$HUSER" -- env "${ENVV[@]}" "$@"; else env "${ENVV[@]}" "$@"; fi; }

W=$(mktemp -d /tmp/gpu-stress.XXXXXX); chmod 755 "$W"; PROF=$W/chromium-profile
cat > "$W/anim.qml" <<'Q'
import QtQuick
Window {
    width: 640; height: 360; visible: true; title: "qq-stress"
    Rectangle {
        id: r; width: 120; height: 120; radius: 20; color: "tomato"
        NumberAnimation on x { from: 0; to: 520; duration: 1500; loops: Animation.Infinite }
        RotationAnimation on rotation { from: 0; to: 360; duration: 3000; loops: Animation.Infinite }
    }
    Text { anchors.bottom: parent.bottom; font.pixelSize: 28; text: Date.now() }
}
Q
cat > "$W/bar.qml" <<'Q'
import QtQuick
Window {
    width: 600; height: 32; visible: true; title: "qq-bar"
    property int n: 0
    Timer { interval: 700; running: true; repeat: true; onTriggered: n++ }
    Text { anchors.centerIn: parent; font.pixelSize: 18; text: "tick " + n }
}
Q
chmod 644 "$W"/*.qml

PIDS=()
start() { local name=$1; shift; asuser "$@" >/dev/null 2>&1 & PIDS+=($!); echo "started $name (pid $!)"; }
PATS=("vkcube --wsi wayland" "glmark2-es2-wayland --run-forever" "qml6 $W/" "$PROF")
stop_all() {
  trap - INT TERM EXIT
  echo "stopping the load"
  for pat in "${PATS[@]}"; do pkill -TERM -u "$HUID" -f -- "$pat" 2>/dev/null; done
  for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done
  sleep 3
  for pat in "${PATS[@]}"; do pkill -KILL -u "$HUID" -f -- "$pat" 2>/dev/null; done
  kill "${SLP:-0}" 2>/dev/null; wait 2>/dev/null; rm -rf "$W"; echo "load stopped"; exit 0
}
trap stop_all INT TERM EXIT

echo "stress-load: $SECS s as $HUSER (Hyprland pid $HPID, signature $SIG), $VKC x vkcube"
for i in $(seq "$VKC"); do start "vkcube $i" vkcube --wsi wayland; done
start glmark2 glmark2-es2-wayland --run-forever -s 1920x1080
if command -v qml6 >/dev/null 2>&1; then
  start anim.qml env QT_QPA_PLATFORM=wayland qml6 "$W/anim.qml"
  start bar.qml  env QT_QPA_PLATFORM=wayland qml6 "$W/bar.qml"
else echo "qml6 not found: skipping the two QML windows"; fi
if command -v chromium >/dev/null 2>&1; then
  start chromium chromium --ozone-platform=wayland --user-data-dir="$PROF" --no-first-run --new-window https://webglsamples.org/aquarium/aquarium.html
else echo "chromium not found: skipping the WebGL tab"; fi
sleep "$SECS" & SLP=$!; wait "$SLP"
