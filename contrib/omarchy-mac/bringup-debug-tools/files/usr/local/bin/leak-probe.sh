#!/bin/bash
# Run ON the MacBook as root: reproduce the memory drain seen at 12:47 UTC (OOM during glmark2 fullscreen on the DCP
# session) under observation, and stop before the OOM. Samples MemAvailable, Shmem, dma-buf count/bytes and the apple
# card's framebuffer count every second while a client runs. Modes: windowed | fullscreen | fullscreen-nods (direct scanout off).
#   leak-probe.sh MODE SECONDS
MODE=${1:-fullscreen}; SECS=${2:-20}; FLOOR_MB=${FLOOR_MB:-12000}
HPID=$(pgrep -x Hyprland | head -1); HUSER=$(ps -o user= -p "$HPID" | tr -d ' '); HUID=$(id -u "$HUSER"); XRD=/run/user/$HUID
SIG=$(for d in "$XRD"/hypr/*/; do p=$(head -1 "$d/hyprland.lock" 2>/dev/null); kill -0 "$p" 2>/dev/null && basename "$d"; done | head -1)
ENVV=(); if [ -r /etc/mesa-aurora/session.env ]; then while IFS= read -r kv; do ENVV+=("$kv"); done < <(set -a; . /etc/mesa-aurora/session.env >/dev/null 2>&1; env | grep -E '^(LD_LIBRARY_PATH|LIBGL_DRIVERS_PATH|MESA_[A-Z_]+|VK_[A-Z_]+|__EGL_[A-Z_]+|ZINK_[A-Z_]+|GALLIUM_[A-Z_]+|EGL_[A-Z_]+)='); fi
while IFS= read -r -d '' kv; do case $kv in WAYLAND_DISPLAY=*|XDG_*=*|DBUS_SESSION_BUS_ADDRESS=*|HOME=*|PATH=*|LANG=*|DISPLAY=*) ENVV+=("$kv");; esac; done < "/proc/$HPID/environ"
ENVV+=("WAYLAND_DISPLAY=wayland-1" "XDG_RUNTIME_DIR=$XRD" "HYPRLAND_INSTANCE_SIGNATURE=$SIG")
asuser() { runuser -u "$HUSER" -- env "${ENVV[@]}" "$@"; }
hc() { asuser hyprctl "$@"; }
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
APPLE=$(for c in /sys/class/drm/card[0-9]; do [ "$(basename "$(readlink "$c/device/driver")")" = apple-drm ] && basename "$c" | tr -dc 0-9; done)
sample() { awk -v t="$1" '/MemAvailable/{a=int($2/1024)} /^Shmem:/{s=int($2/1024)} /^Unevictable/{u=int($2/1024)} END{printf "t=%-3s MemAvail=%6d MB Shmem=%5d MB Unevict=%5d MB", t, a, s, u}' /proc/meminfo
  echo -n "  dmabufs=$(grep -c '^Dma-buf' /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null)"
  echo -n " dmabuf_MB=$(awk '/^Total/{print int($1/1048576)}' /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null)"
  echo "  appleFBs=$(grep -c '^framebuffer\[' /sys/kernel/debug/dri/$APPLE/framebuffer 2>/dev/null) gpuFBs=$(grep -c '^framebuffer\[' /sys/kernel/debug/dri/0/framebuffer 2>/dev/null)"; }
echo "leak-probe mode=$MODE cmd=${CMD:-} secs=$SECS kernel=$(uname -r) apple=card$APPLE direct_scanout=$(hc getoption render:direct_scanout 2>/dev/null | grep -o 'int: [0-9]' )"
[ "$MODE" = fullscreen-nods ] && hc keyword render:direct_scanout 0 >/dev/null
echo "before: $(sample 0)"
case $MODE in windowed) asuser glmark2-es2-wayland --run-forever -s 1920x1080 >/tmp/leak-glmark2.log 2>&1 & ;;
  cmd) asuser bash -c "$CMD" >/tmp/leak-cmd.log 2>&1 & ;;
  *) asuser glmark2-es2-wayland --run-forever --fullscreen >/tmp/leak-glmark2.log 2>&1 & ;; esac
CP=$!; sleep 2
for t in $(seq 1 "$SECS"); do sleep 1; l=$(sample $t); echo "$l"; a=$(echo "$l" | sed -n 's/.*MemAvail= *\([0-9]*\) MB.*/\1/p'); if [ "${a:-99999}" -lt "$FLOOR_MB" ]; then echo "STOP: MemAvailable under $FLOOR_MB MB"; break; fi; done
kill $CP 2>/dev/null; asuser pkill -x glmark2-es2-wayland 2>/dev/null; asuser pkill -x vkcube 2>/dev/null; asuser pkill -x mpv 2>/dev/null; sleep 3
echo "after:  $(sample end)"
[ "$MODE" = fullscreen-nods ] && hc keyword render:direct_scanout 1 >/dev/null
echo "hyprland=$(pgrep -xc Hyprland) kms-submit-failures=$(tr -d '\000' < $XRD/hypr/$SIG/hyprland.log | grep -ac 'Failed to submit a buffer to KMS')"
dmesg | tail -n 5 | cut -c1-160
