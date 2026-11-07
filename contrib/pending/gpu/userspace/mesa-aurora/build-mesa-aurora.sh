#!/bin/bash
# Build Aurora Mesa (Asahi Gallium + Honeykrisp Vulkan) into a private prefix,
# leaving the distribution mesa untouched. Idempotent: rerun after a reboot and
# ninja resumes where it stopped.
#
# Source: github.com/aurora-silicon/mesa, branch agx3c. Its
# include/drm-uapi/asahi_drm.h is byte-identical to the kernel's
# include/uapi/drm/asahi_drm.h (PR aurora-silicon/mesa#169 took the M5 kernel
# header), and it opens DRM devices named "aurora" (and legacy "asahi").
set -euo pipefail

BRANCH=${BRANCH:-agx3c}
COMMIT=${COMMIT:-}               # optional exact pin
SRC=${SRC:-/root/build/mesa-agx3c}
BUILD=${BUILD:-$SRC/build-aurora}
PREFIX=${PREFIX:-/opt/mesa-aurora}
JOBS=${JOBS:-$(nproc)}
# llvmpipe keeps a fast software fallback when the GPU is absent (daily kernel).
GALLIUM=${GALLIUM:-asahi,zink,llvmpipe,softpipe}

if [[ ! -d $SRC/.git ]]; then
  # Clone to a temporary name so an interrupted clone is never mistaken for a tree.
  rm -rf "$SRC.tmp"
  git clone --filter=blob:none --branch "$BRANCH" --single-branch \
    https://github.com/aurora-silicon/mesa.git "$SRC.tmp"
  mv "$SRC.tmp" "$SRC"
fi
cd "$SRC"
if [[ -n $COMMIT ]]; then git fetch -q origin "$COMMIT" && git checkout -q "$COMMIT"; fi
echo "mesa source: $(git log --oneline -1)"

if [[ ! -f $BUILD/build.ninja ]]; then
  rm -rf "$BUILD"
  # One tree with LLVM on: LLVM is only needed to precompile the Asahi CL
  # helper shaders (mesa_clc / asahi_clc). The distro package splits this into
  # two trees to keep libLLVM out of the runtime; a private prefix need not.
  meson setup "$BUILD" \
    --prefix "$PREFIX" --libdir lib --buildtype release \
    -Db_ndebug=true \
    -Dplatforms=x11,wayland \
    -Dgallium-drivers=$GALLIUM \
    -Dvulkan-drivers=asahi \
    -Dvulkan-layers= \
    -Degl=enabled -Dgbm=enabled -Dglx=dri -Dgles1=enabled -Dgles2=enabled \
    -Dglvnd=enabled -Dglvnd-vendor-name=aurora \
    -Dllvm=enabled -Dgallium-rusticl=false \
    -Dmesa-clc=auto -Dprecomp-compiler=auto \
    -Dvideo-codecs= \
    -Dexpat=enabled -Dzstd=enabled -Dlmsensors=enabled \
    -Dlibunwind=disabled -Dvalgrind=disabled \
    -Dtools=drm-shim,asahi \
    -Dbuild-tests=false
fi

# An existing tree follows a changed driver list.
meson configure "$BUILD" -Dgallium-drivers="$GALLIUM" >/dev/null
ninja -C "$BUILD" -j "$JOBS"
ninja -C "$BUILD" install >/dev/null

# Offline test shim (fake G17S/M5 Pro device, no kernel driver needed).
shim=$(find "$BUILD" -name 'libasahi_noop_drm_shim.so' | head -1)
[[ -n $shim ]] && install -Dm755 "$shim" "$PREFIX/lib/libasahi_noop_drm_shim.so"

# glvnd EGL vendor file with an absolute library path, so selecting it needs no
# LD_LIBRARY_PATH for EGL clients.
install -d "$PREFIX/share/glvnd/egl_vendor.d"
cat > "$PREFIX/share/glvnd/egl_vendor.d/50_aurora.json" <<JSON
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "$PREFIX/lib/libEGL_aurora.so.0"
    }
}
JSON

git -C "$SRC" rev-parse HEAD > "$PREFIX/MESA_COMMIT"
echo "installed to $PREFIX:"
ls "$PREFIX/lib" | grep -E 'vulkan|EGL|GLX|gbm|gallium|shim' || true
ls "$PREFIX/share/vulkan/icd.d" "$PREFIX/lib/dri" 2>/dev/null || true
