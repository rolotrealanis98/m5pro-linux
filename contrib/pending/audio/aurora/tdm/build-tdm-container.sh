#!/usr/bin/env bash
# build-audio-container.sh pointed at /Volumes/linux-cs/wt-audio-tdm (branch j716s-audio-tdm), output kbuild-tdm.
# Same Fedora 43 container, toolchain (clang, rustc 1.99.1, aurora-bindgen) and config seed (kbuild2's).
# Builds Image.gz, the in-tree J716s DTB, and the audio DTBs from ~/Work/agents/audio-tdm/dt with the tree's dtc.
set -euo pipefail
OUT=$HOME/Work/agents/audio-aurora/kbuild-tdm; mkdir -p "$OUT"
DT=$HOME/Work/agents/audio-tdm/dt; ADT=$HOME/Work/agents/audio-aurora/dt
container rm -f kaudiotdm >/dev/null 2>&1 || true
container run -d --name kaudiotdm -m 24g -c 12 -v /Volumes/linux-cs:/Volumes/linux-cs -v "$OUT:/out" -v "$DT:/dt" -v "$ADT:/adt:ro" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kaudiotdm >/dev/null 2>&1 || true' EXIT
container exec kaudiotdm bash -c '
set -euo pipefail
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
cd /Volumes/linux-cs/wt-audio-tdm
git config --global --add safe.directory "*"
{ git log --oneline -1; clang --version | head -1; rustc --version; } > /out/toolchain.txt
[ -x tools/aurora-bindgen/build/bin/bindgen ] || python3 tools/aurora-bindgen/build.py >> /out/bindgen.log 2>&1 || { echo "bindgen build failed" >> /out/toolchain.txt; tail -20 /out/bindgen.log; exit 1; }
export BINDGEN=$PWD/tools/aurora-bindgen/build/bin/bindgen
make LLVM=1 ARCH=arm64 O=/out/obj rustavailable > /out/rustavailable.txt 2>&1; cat /out/rustavailable.txt >> /out/toolchain.txt; grep "Rust is available" /out/rustavailable.txt >/dev/null || { echo "rust not available"; exit 1; }
mkdir -p /out/obj && cp /out/config.seed /out/obj/.config
make LLVM=1 ARCH=arm64 O=/out/obj olddefconfig >/dev/null
grep -E "^CONFIG_(RUST|APPLE_AOP|SND_SOC_APPLE_AOP_AUDIO|SND_SOC_APPLE_MACAUDIO|SND_SOC_TAS2764)=" /out/obj/.config
make -j12 LLVM=1 ARCH=arm64 O=/out/obj Image.gz apple/t6050-j716s.dtb > /out/build.log 2>&1 || { echo "BUILD FAILED"; grep -m8 -B3 -A6 -E " error|^error" /out/build.log; exit 1; }
mkdir -p /out/dtb
cp /out/obj/arch/arm64/boot/dts/apple/t6050-j716s.dtb /out/dtb/
for f in /adt/j716s-audio-notun-edp.dts /adt/j716s-audio-spk-notun-edp.dts /dt/j716s-audio-spk-defer-notun-edp.dts; do
  b=$(basename $f .dts); /out/obj/scripts/dtc/dtc -q -I dts -O dtb -o /out/dtb/t6050-${b}.dtb $f
done
grep -c "warning" /out/build.log || true
cd /out && sha256sum obj/arch/arm64/boot/Image.gz dtb/*.dtb | tee /out/SHA256SUMS
'
echo "container build finished"
