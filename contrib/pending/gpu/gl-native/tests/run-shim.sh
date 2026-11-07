#!/bin/bash
# Run a command on the staged tree against the noop DRM shim (no GPU).
#   run-shim.sh <chip> <cmd...>    chip: g17s-kernel (M5 gate on), g17s, ...
P=/out/stage/opt/mesa-aurora-gl
chip=$1; shift
printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s/lib/libEGL_aurora.so.0"}}' "$P" > /tmp/50_aurora.json
export LD_LIBRARY_PATH=$P/lib __EGL_VENDOR_LIBRARY_FILENAMES=/tmp/50_aurora.json
export LIBGL_DRIVERS_PATH=$P/lib/dri GBM_BACKENDS_PATH=$P/lib/gbm
export VK_DRIVER_FILES=$P/share/vulkan/icd.d/asahi_icd.aarch64.json
export ASAHI_M5_BRINGUP=1 ASAHI_SHIM_CHIP=$chip
unset MESA_LOADER_DRIVER_OVERRIDE
LD_PRELOAD=$P/lib/libasahi_noop_drm_shim.so exec "$@"
