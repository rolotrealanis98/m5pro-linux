# usage: . ab-env.sh <prefix> [zink|native]   (one process only; never put this in the session)
P=$1; M=${2:-zink}
export LD_LIBRARY_PATH=$P/lib
export __EGL_VENDOR_LIBRARY_FILENAMES=$P/share/glvnd/egl_vendor.d/50_aurora.json
export __GLX_VENDOR_LIBRARY_NAME=aurora
export LIBGL_DRIVERS_PATH=$P/lib/dri GBM_BACKENDS_PATH=$P/lib/gbm
export VK_DRIVER_FILES=$P/share/vulkan/icd.d/asahi_icd.aarch64.json
export VK_ICD_FILENAMES=$P/share/vulkan/icd.d/asahi_icd.aarch64.json
[ "$M" = zink ] && export MESA_LOADER_DRIVER_OVERRIDE=zink
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1001} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1}
