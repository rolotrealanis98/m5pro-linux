#!/usr/bin/env bash
# E1 kernel: j716s-series-gpu (worktree /Volumes/linux-cs/wt-gpu-e1) built with the audio Rust recipe
# (build-tdm-container.sh): Apple `container`, Fedora 43, clang 21, rustc 1.99.1, tools/aurora-bindgen.
# Config: make defconfig asahi.config j716s.config j716s-gpu.config (RUST=y, DRM_ASAHI=y, APPLE_PMP off).
# Objects in /Volumes/linux-cs/wt-gpu-e1-out (case-sensitive volume); Image.gz, the J716s DTB, the .config
# and the config diff against the series build are copied to ~/Work/agents/gpu-e1/kbuild/.
set -euo pipefail
OUT=$HOME/Work/agents/gpu-e1/kbuild; mkdir -p "$OUT"
OBJ=/Volumes/linux-cs/wt-gpu-e1-out; mkdir -p "$OBJ"
container rm -f kgpue1 >/dev/null 2>&1 || true
container run -d --name kgpue1 -m 24g -c 12 -v /Volumes/linux-cs:/Volumes/linux-cs -v "$OUT:/out" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kgpue1 >/dev/null 2>&1 || true' EXIT
container exec kgpue1 bash -c '
set -euo pipefail
OBJ=/Volumes/linux-cs/wt-gpu-e1-out
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
cd /Volumes/linux-cs/wt-gpu-e1
git config --global --add safe.directory "*"
{ git log --oneline -1; clang --version | head -1; rustc --version; } > /out/toolchain.txt
[ -x tools/aurora-bindgen/build/bin/bindgen ] || python3 tools/aurora-bindgen/build.py >> /out/bindgen.log 2>&1 || { echo "bindgen build failed" >> /out/toolchain.txt; tail -20 /out/bindgen.log; exit 1; }
export BINDGEN=$PWD/tools/aurora-bindgen/build/bin/bindgen
make LLVM=1 ARCH=arm64 O=$OBJ rustavailable > /out/rustavailable.txt 2>&1; cat /out/rustavailable.txt >> /out/toolchain.txt; grep "Rust is available" /out/rustavailable.txt >/dev/null || { echo "rust not available"; exit 1; }
make LLVM=1 ARCH=arm64 O=$OBJ defconfig asahi.config j716s.config j716s-gpu.config > /out/config.log 2>&1
grep -E "^CONFIG_(RUST|DRM_ASAHI|DRM_ASAHI_G1[568]|DRM_ASAHI_M5|APPLE_PMP|APPLE_PMP_REPORT|RUST_APPLE_RTKIT|APPLE_MAILBOX|DRM|ARM64_16K_PAGES|IOMMU_SUPPORT)=|^# CONFIG_(APPLE_PMP|DRM_ASAHI_G16|DRM_ASAHI_M5) is not set" $OBJ/.config | tee /out/config-key.txt
cp $OBJ/.config /out/config
scripts/diffconfig /Volumes/linux-cs/wt-series-out/.config $OBJ/.config > /out/diffconfig-vs-series.txt || true
make -j12 LLVM=1 ARCH=arm64 O=$OBJ Image.gz apple/t6050-j716s.dtb > /out/build.log 2>&1 || { echo "BUILD FAILED"; grep -m8 -B3 -A8 -E " error|^error" /out/build.log; exit 1; }
cp $OBJ/arch/arm64/boot/Image.gz /out/Image.gz
cp $OBJ/arch/arm64/boot/dts/apple/t6050-j716s.dtb /out/t6050-j716s-gpu.dtb
cat $OBJ/include/config/kernel.release > /out/kernel.release
grep -c "warning" /out/build.log > /out/warning-count.txt || true
cd /out && sha256sum Image.gz t6050-j716s-gpu.dtb config | tee /out/SHA256SUMS
'
echo "container build finished"
