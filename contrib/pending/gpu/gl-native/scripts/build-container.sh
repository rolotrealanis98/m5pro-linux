#!/usr/bin/env bash
# Build Aurora Mesa (agx3c + the gl-native series) for the M5 Pro inside an
# Arch Linux ARM container on the Mac Studio (Apple `container`, arm64 guest,
# so this is a native aarch64 build against the same Arch packages the MacBook
# runs: LLVM 23.1, libdrm 2.4.134, ...). Same meson options as the MacBook's
# /root/build/build-mesa-aurora.sh, but the install goes to a staging DESTDIR
# so the result mirrors /opt/mesa-aurora and can be copied to
# /opt/mesa-aurora-gl. The prefix baked into the build is $PREFIX (default
# /opt/mesa-aurora-gl), so the glvnd/ICD json files point at the new tree.
#
#   build-container.sh            # setup (once) + build + stage
#   STAGE_ONLY=1 build-container.sh
# A fresh container clones aurora-silicon/mesa at $BASE and applies
# ../patches/*.patch (git am), so the tree is rebuilt from the series alone.
set -euo pipefail
# Source and build live on the container's own disk (/Volumes/linux-cs is
# shared with the kernel builds and fills up); patches and the staged tree
# come out through /out.
SRC=${SRC:-/root/gl-native/mesa}
BUILD=${BUILD:-/root/gl-native/build}
WORK=${WORK:-$HOME/Work/agents/gpu-gl-native}
OUT=${OUT:-$WORK/out}
BASE=${BASE:-a8e86a80cdc}
PREFIX=${PREFIX:-/opt/mesa-aurora-gl}
NAME=${NAME:-mesagl}
mkdir -p "$OUT"

# A stopped container keeps its disk (and the tree on it): start it again.
if container list --all 2>/dev/null | grep -q "^$NAME " &&
   ! container list 2>/dev/null | grep -q "^$NAME "; then
  container start "$NAME" >/dev/null
fi
if ! container list 2>/dev/null | grep -q "^$NAME "; then
  container run -d --name "$NAME" -m 16g -c 10 \
    -v "$WORK:/work" -v "$OUT:/out" \
    menci/archlinuxarm:base-devel sleep infinity >/dev/null
  container exec "$NAME" bash -c '
    set -e
    grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
    pacman-key --init >/dev/null 2>&1 || true
    pacman-key --populate archlinuxarm >/dev/null 2>&1 || true
    pacman -Syu --noconfirm --needed >/dev/null
    pacman -S --noconfirm --needed meson ninja git python-mako python-yaml python-packaging \
      python-ply llvm clang libclc spirv-llvm-translator spirv-tools glslang \
      libdrm wayland wayland-protocols libglvnd libx11 libxext libxfixes libxshmfence \
      libxxf86vm libxrandr libxcb xcb-util-keysyms expat zstd lm_sensors elfutils \
      libva libvdpau bison flex cbindgen rust rust-bindgen valgrind >/dev/null
    git config --global --add safe.directory "*"
    { pacman -Q llvm-libs clang libclc spirv-llvm-translator libdrm meson; } > /out/toolchain.txt'
fi

container exec -e SRC="$SRC" -e BUILD="$BUILD" -e PREFIX="$PREFIX" -e BASE="$BASE" -e STAGE_ONLY="${STAGE_ONLY:-}" "$NAME" bash -c '
set -euo pipefail
if [[ ! -d $SRC/.git ]]; then
  git clone -q --filter=blob:none --branch agx3c https://github.com/aurora-silicon/mesa.git "$SRC"
  cd "$SRC"
  git checkout -q -b agx3c-gl-native "$BASE"
  git -c user.name="Rolando Trevino" -c user.email=rolotrealanis@gmail.com am -q /work/patches/*.patch
fi
cd "$SRC"
if [[ ! -f $BUILD/build.ninja ]]; then
  meson setup "$BUILD" \
    --prefix "$PREFIX" --libdir lib --buildtype release \
    -Db_ndebug=true \
    -Dplatforms=x11,wayland \
    -Dgallium-drivers=asahi,zink,llvmpipe,softpipe \
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
    -Dbuild-tests=false > /out/meson-setup.log 2>&1
fi
if [[ -z $STAGE_ONLY ]]; then
  ninja -C "$BUILD" -j 8 > /out/ninja.log 2>&1 || { grep -m20 -B2 -A6 "error" /out/ninja.log; exit 1; }
fi
rm -rf /out/stage
DESTDIR=/out/stage ninja -C "$BUILD" install > /out/install.log 2>&1
T=/out/stage$PREFIX
shim=$(find "$BUILD" -name libasahi_noop_drm_shim.so | head -1)
[[ -n $shim ]] && install -Dm755 "$shim" "$T/lib/libasahi_noop_drm_shim.so"
install -d "$T/share/glvnd/egl_vendor.d"
cat > "$T/share/glvnd/egl_vendor.d/50_aurora.json" <<JSON
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "$PREFIX/lib/libEGL_aurora.so.0"
    }
}
JSON
git -C "$SRC" rev-parse HEAD > "$T/MESA_COMMIT"
cd /out/stage/opt && tar --owner=0 --group=0 -czf /out/mesa-aurora-gl.tar.gz "$(basename "$PREFIX")"
ls "$T" "$T/lib"
'
echo "staged: $OUT/stage$PREFIX ; tarball: $OUT/mesa-aurora-gl.tar.gz"
