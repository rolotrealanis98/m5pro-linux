#!/bin/bash
# Build the tree at a commit (incrementally, in the shared build dir), stage it
# to /tmp/stage-<rev>, and run the smoke test on the g17s-kernel shim.
#   gate-at.sh <rev>       (run inside the mesagl container)
set -e
rev=$1
cd /root/gl-native/mesa
git checkout -q --detach "$rev"
ninja -C /root/gl-native/build -j10 > /tmp/ninja-$rev.log 2>&1 || { tail -20 /tmp/ninja-$rev.log; exit 1; }
rm -rf /tmp/stage-$rev
DESTDIR=/tmp/stage-$rev ninja -C /root/gl-native/build install > /dev/null 2>&1
shim=$(find /root/gl-native/build -name libasahi_noop_drm_shim.so | head -1)
P=/tmp/stage-$rev/opt/mesa-aurora-gl
install -m755 "$shim" $P/lib/
printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s/lib/libEGL_aurora.so.0"}}' "$P" > /tmp/50-$rev.json
cd /tmp
LD_LIBRARY_PATH=$P/lib __EGL_VENDOR_LIBRARY_FILENAMES=/tmp/50-$rev.json \
LIBGL_DRIVERS_PATH=$P/lib/dri ASAHI_M5_BRINGUP=1 ASAHI_SHIM_CHIP=g17s-kernel \
LD_PRELOAD=$P/lib/libasahi_noop_drm_shim.so \
timeout 120 /out/gl-native-smoke surfaceless 2>&1 | grep -v "export failed\|pixel (\|v\[0\]" | sort | uniq -c | sort -rn | head -20
