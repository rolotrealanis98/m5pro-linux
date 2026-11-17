#!/bin/bash
# Chrome GPU A/B on the live session, as the desktop user, in a THROWAWAY profile (never the owner's profile or flags).
#   run-ab.sh OUTDIR ROUNDS CONFIG...      e.g. run-ab.sh /home/rolo/gpu-ab/chrome-ab/r1 2 gl vk vk-graphite gl-graphite
# Each run is one Chrome window for ~40 s (bench.html: WebGL draws/fill, Canvas 2D, CSS layers, WebGPU), then chrome://gpu
# is read over DevTools and the browser closes. Silent page. GPU windows are serialized with other agents via flock.
# Owner rule: test windows open on Hyprland workspace 5, silently (never on the active workspace, never steal focus).
# Chrome is started by Hyprland (0.57 Lua: `hyprctl dispatch 'hl.dsp.exec_cmd("CMD", {workspace = "5 silent"})'`), so it
# gets the session's own environment (Mesa from /etc/mesa-aurora/session.env).
set -u
OUT=$1; ROUNDS=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
PROFILE=/home/rolo/gpu-ab/chrome-test
LOCK=/home/rolo/gpu-ab/.gpu-window.lock
mkdir -p "$OUT"
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
export HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)}
WS=${WS:-5}
# the owner's flags (chrome-flags.conf) minus the extension list, plus the uncapped-frame-rate switches for measuring
BASE=(--ozone-platform=wayland --ozone-platform-hint=wayland --render-node-override=/dev/dri/renderD128 --password-store=basic
      --no-first-run --no-default-browser-check --disable-gpu-vsync --disable-frame-rate-limit --mute-audio
      --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows
      --remote-debugging-port=9333 --user-data-dir=$PROFILE)
flags() {
  case $1 in
    gl)           echo "--enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar" ;;
    vk)           echo "--use-angle=vulkan --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,Vulkan,DefaultANGLEVulkan,VulkanFromANGLE" ;;
    vk-graphite)  echo "--use-angle=vulkan --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,SkiaGraphite" ;;
    gl-graphite)  echo "--enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,SkiaGraphite" ;;
    vk-graphite-sw) echo "--use-angle=vulkan --enable-skia-graphite --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,SkiaGraphite" ;;
    gl-graphite-sw) echo "--enable-skia-graphite --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,SkiaGraphite" ;;
    vk-forced)    echo "--use-angle=vulkan --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,VaapiIgnoreDriverChecks,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL" ;;
    angle-vk)     echo "--use-angle=vulkan --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar" ;;
    vk-only)    echo "--enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,Vulkan" ;;
    *) echo "unknown config $1" >&2; exit 2 ;;
  esac
}
for r in $(seq 1 "$ROUNDS"); do
  for c in "$@"; do
    tag=$c-r$r
    before=$(dmesg | wc -l)
    # shellcheck disable=SC2046
    L=$OUT/$tag.launch.sh
    printf '#!/bin/sh\nexec /opt/google/chrome/chrome %s %s "file://%s/bench.html?dur=6000" > "%s.stderr" 2>&1\n' \
      "${BASE[*]}" "$(flags "$c")" "$HERE" "$OUT/$tag" > "$L"; chmod +x "$L"
    flock "$LOCK" bash -c '
      hyprctl dispatch "hl.dsp.exec_cmd(\"'"$L"'\", {workspace = \"'"$WS"' silent\"})" >/dev/null
      timeout 90 python3 "'"$HERE"'/cdp.py" 9333 75 > "'"$OUT/$tag"'.json"
      sleep 2; pkill -f -- "^/opt/google/chrome/chrome .*--user-data-dir='"$PROFILE"'( |$)" 2>/dev/null; sleep 2; true
    '
    dmesg | tail -n +$((before + 1)) | grep -iE 'aurora|asahi|gpu|fault|fence|timeout|recover' > "$OUT/$tag.dmesg"
    echo "$tag: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); b=d.get("bench") or {}; print({k:(v.get("fps") if isinstance(v,dict) else v) for k,v in b.items()})' "$OUT/$tag.json" 2>&1 | cut -c1-400) dmesg+$(wc -l < "$OUT/$tag.dmesg")"
    if grep -qiE 'fault|recover|timed out|timeout' "$OUT/$tag.dmesg"; then echo "STOP: GPU fault lines after $tag"; cat "$OUT/$tag.dmesg"; exit 1; fi
    sleep 3
  done
done
