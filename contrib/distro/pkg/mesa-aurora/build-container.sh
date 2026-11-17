#!/usr/bin/env bash
# Build aurora-silicon/mesa at COMMIT for aarch64 in an Arch Linux ARM container
# (Apple `container`, arm64 guest) and stage it under PREFIX so it can sit next
# to the system Mesa on the MacBook. Mirrors the alarm-aurora mesa-aurora
# PKGBUILD: a first "tools" build makes mesa_clc / vtn_bindgen2 / asahi_clc
# (needs LLVM + SPIRV-Tools), the second build is the native GL/Vulkan tree and
# links neither. Only PREFIX, the glvnd vendor name (aurora, as /opt/mesa-aurora)
# and the absolute EGL vendor json differ from the package.
#
#   NAME=gpu-mesa-1 COMMIT=db928e79933d PREFIX=/opt/mesa-aurora-20261117 \
#   OUT=/Volumes/m5pro/bench/gpu-mesa-aurora-1/out build-container.sh
# Output: $OUT/stage$PREFIX, $OUT/mesa-aurora-<date>.tar.zst, $OUT/*.log
set -euo pipefail
NAME=${NAME:-gpu-mesa-1}
COMMIT=${COMMIT:?set COMMIT}
PREFIX=${PREFIX:?set PREFIX, e.g. /opt/mesa-aurora-20261117}
OUT=${OUT:?set OUT (host dir, mounted at /out)}
JOBS=${JOBS:-10}
container list 2>/dev/null | grep -q "^$NAME " || {
  container run -d --name "$NAME" -m 16g -c "$JOBS" -v "$OUT:/out" menci/archlinuxarm:base-devel sleep infinity >/dev/null
  container exec "$NAME" bash -c '
    sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
    pacman-key --init; pacman-key --populate archlinuxarm; pacman -Syu --noconfirm --needed
    pacman -S --noconfirm --needed git meson ninja python-mako python-yaml python-packaging python-ply rust rust-bindgen \
      clang llvm libclc spirv-llvm-translator spirv-tools cbindgen glslang libdrm expat libglvnd libx11 libxcb libxext \
      libxfixes libxrandr libxshmfence libxxf86vm wayland wayland-protocols vulkan-headers vulkan-icd-loader \
      libdisplay-info lm_sensors zlib zstd xcb-util-keysyms bison flex zstd >/dev/null'; }
container exec -e COMMIT="$COMMIT" -e PREFIX="$PREFIX" -e JOBS="$JOBS" "$NAME" bash -c '
set -euo pipefail
S=/root/mesa; T=/root/tools; B=/root/build
[[ -d $S/.git ]] || git clone -q --filter=blob:none -b aurora-wip https://github.com/aurora-silicon/mesa.git $S
git -C $S fetch -q origin; git -C $S checkout -q "$COMMIT"; FULL=$(git -C $S rev-parse HEAD)
export MESA_GIT_SHA1_OVERRIDE=$FULL
common=(--buildtype plain --wrap-mode nodownload -Db_pie=true -Db_ndebug=true -Dplatforms=x11,wayland
  -Dgallium-drivers=asahi,zink,softpipe -Degl=enabled -Dgbm=enabled -Dglx=dri -Dgles1=enabled -Dgles2=enabled
  -Dglvnd=enabled -Dglvnd-vendor-name=aurora -Dvideo-codecs= -Dvulkan-layers= -Dexpat=enabled -Dzstd=enabled
  -Dlmsensors=enabled -Dlibunwind=disabled -Dvalgrind=disabled)
[[ -f $T/build.ninja ]] || meson setup $T $S --prefix /usr "${common[@]}" -Dvulkan-drivers=asahi -Dllvm=enabled \
  -Dgallium-rusticl=false -Dbuild-tests=false >/out/meson-tools.log 2>&1
ninja -C $T -j $JOBS src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/asahi/clc/asahi_clc >/out/ninja-tools.log 2>&1
printf "%s\n" "[binaries]" "mesa_clc = '"'"'$T/src/compiler/clc/mesa_clc'"'"'" \
  "vtn_bindgen2 = '"'"'$T/src/compiler/spirv/vtn_bindgen2'"'"'" "asahi_clc = '"'"'$T/src/asahi/clc/asahi_clc'"'"'" > /root/tools.ini
rm -rf $B
# the makepkg optimization level: buildtype plain adds none, so without CFLAGS the driver is built -O0 (and the
# test executables then fail to link on unused hk_cmd_buffer references)
export CFLAGS="-O2 -pipe -fno-plt" CXXFLAGS="-O2 -pipe -fno-plt" RUSTFLAGS="-C opt-level=2"
meson setup $B $S --prefix "$PREFIX" --libdir lib "${common[@]}" --native-file /root/tools.ini -Dvulkan-drivers=asahi \
  -Dllvm=disabled -Dspirv-tools=disabled -Dmesa-clc=system -Dprecomp-compiler=system -Dgallium-rusticl=false \
  -Dbuild-tests=true >/out/meson-build.log 2>&1
ninja -C $B -j $JOBS >/out/ninja-build.log 2>&1
rm -rf /out/stage; DESTDIR=/out/stage meson install -C $B --no-rebuild >/out/install.log 2>&1
P=/out/stage$PREFIX
install -d $P/share/glvnd/egl_vendor.d
printf "{\n    \"file_format_version\" : \"1.0.0\",\n    \"ICD\" : {\n        \"library_path\" : \"%s/lib/libEGL_aurora.so.0\"\n    }\n}\n" "$PREFIX" > $P/share/glvnd/egl_vendor.d/50_aurora.json
echo $FULL > $P/MESA_COMMIT
find $P/lib -name "*.so*" -type f -exec strip --strip-unneeded {} +   # makepkg strips too
tar --owner=0 --group=0 -C /out/stage/opt -cf - "$(basename "$PREFIX")" | zstd -T8 -q -f -o /out/"$(basename "$PREFIX")".tar.zst
echo built $FULL'
