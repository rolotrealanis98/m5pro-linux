#!/bin/bash
# measure.sh: camera noise, raw (V4L2) and through the denoise filter (PipeWire), on the MacBook as root.
# Statistics only: frames stay in memory, nothing is written. The camera light is on for ~4 s per run.
#   sudo contrib/omarchy-mac/camera-denoise/tools/measure.sh [raw|filter|both] [desktop user, default rolo]
# Point the camera at a still scene and keep out of the picture; compare runs under the same light.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); WHAT=${1:-both}; U=${2:-rolo}; B=/run/camera-noise
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
if fuser /dev/video0 >/dev/null 2>&1; then echo "camera in use: $(fuser /dev/video0 2>&1)"; exit 2; fi
mkdir -p $B; chmod 755 $B
gcc -O2 -o $B/noisestat "$HERE/noisestat.c" -lm
gcc -O2 -o $B/pwcap "$HERE/pwcap.c" $(pkg-config --cflags --libs libpipewire-0.3)
if [ "$WHAT" != filter ]; then
  echo "== raw V4L2 /dev/video0 $(date +%T)"
  timeout 10 v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=NV12 \
    --stream-mmap --stream-count=100 --stream-to=- 2>/dev/null | $B/noisestat 1920 1080 50
  sleep 6   # the ISP stays up 5 s after a stream
fi
if [ "$WHAT" != raw ]; then
  echo "== denoise filter node $(date +%T)"
  runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$(id -u "$U") timeout 12 \
    $B/pwcap aurora_camera_denoise.v4l2_input.platform-580000000.isp 100 2>/dev/null | $B/noisestat 1920 1080 50
fi
rm -rf $B
