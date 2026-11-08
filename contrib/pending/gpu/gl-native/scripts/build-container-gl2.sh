#!/usr/bin/env bash
# Second production build of the gl-native series: patches 0001-0008
# (g17s-gallium-native-v2 in /Volumes/linux-cs/mesa-g17s) with prefix
# /opt/mesa-aurora-gl2, so it can sit next to /opt/mesa-aurora-gl for A/B.
# Same container (mesagl), same meson options as build-container.sh. Nothing
# of the first build is touched: own worktree, build dir, stage and logs.
#   build-container-gl2.sh            # needs out/g17s-gallium-native-v2.bundle
set -euo pipefail
WORK=${WORK:-$HOME/Work/agents/gpu-gl-native}
OUT=${OUT:-$WORK/out}
NAME=${NAME:-mesagl}
BRANCH=${BRANCH:-g17s-gallium-native-v2}
PREFIX=${PREFIX:-/opt/mesa-aurora-gl2}
if container list --all 2>/dev/null | grep -q "^$NAME " && ! container list 2>/dev/null | grep -q "^$NAME "; then
  container start "$NAME" >/dev/null
fi
container exec -e PREFIX="$PREFIX" -e BRANCH="$BRANCH" "$NAME" bash -c '
set -euo pipefail
REPO=/root/gl-native/mesa
SRC=/root/gl-native/mesa-v2
BUILD=/root/gl-native/build-v2
STAGE=/out/stage-gl2
cd "$REPO"
git fetch -q /out/$BRANCH.bundle "$BRANCH:$BRANCH" 2>/dev/null || true
[[ -d $SRC ]] || git worktree add -q "$SRC" "$BRANCH"
cd "$SRC"; git checkout -q "$BRANCH"
SHA=$(git rev-parse --short=11 HEAD)
echo "building $BRANCH $SHA -> $PREFIX"
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
    -Dbuild-tests=false > /out/gl2-meson-setup.log 2>&1
fi
ninja -C "$BUILD" -j 8 > /out/gl2-ninja.log 2>&1 || { grep -m20 -B2 -A6 "error" /out/gl2-ninja.log; exit 1; }
rm -rf "$STAGE"
DESTDIR=$STAGE ninja -C "$BUILD" install > /out/gl2-install.log 2>&1
T=$STAGE$PREFIX
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
git rev-parse HEAD > "$T/MESA_COMMIT"
cd $STAGE/opt && tar --owner=0 --group=0 --zstd -cf /out/mesa-aurora-gl2-$SHA.tar.zst "$(basename "$PREFIX")"
cd /out && sha256sum mesa-aurora-gl2-$SHA.tar.zst
'
echo "staged: $OUT/stage-gl2$PREFIX"
