#!/usr/bin/env bash
# E2 kernel: j716s-series-gpu-27 (worktree /Volumes/linux-cs/wt-gpu-e1) = series a0f2f30c967b + Aurora #1012
# + the integrated 27.2+ port, built in the Fedora 43 container exactly as ../next-daily/build-next.sh
# (clang 21, rustc 1.99.1, the daily's aurora bindgen) with the E1 GPU fragment:
#   make defconfig asahi.config j716s.config j716s-gpu.config   (DRM_ASAHI=y, APPLE_PMP off, DRM_APPLE off)
# CONFIGS="... j716s-dcp.config" OUTSUB=dcp LV=-dcp builds the DCP-B variant (DRM_APPLE on, release suffix -dcp so its
# modules get their own /usr/lib/modules directory) in the same out dir; j716s-dcp.config is copied into
# arch/arm64/configs/ for that build only (contrib/pending/dcp/aurora/j716s-dcp.config).
# Objects in /Volumes/linux-cs/wt-gpu-e1-out (the E1 out dir, reused); results to kbuild/$OUTSUB.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
OUTSUB=${OUTSUB:-gpu}
CONFIGS=${CONFIGS:-"defconfig asahi.config j716s.config j716s-gpu.config"}
LV=${LV:-}
LOG=$S/kbuild/$OUTSUB; mkdir -p "$LOG"
container rm -f kgpue2 >/dev/null 2>&1 || true
container run -d --name kgpue2 -m 24g -c 12 -v /Volumes/linux-cs:/Volumes/linux-cs -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kgpue2 >/dev/null 2>&1 || true' EXIT
container exec -e CONFIGS="$CONFIGS" -e LV="$LV" kgpue2 bash -c '
set -euo pipefail
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
git config --global --add safe.directory "*"
export BINDGEN=/Volumes/linux-cs/wt-aurora-audio2/tools/aurora-bindgen/build/bin/bindgen
O=/Volumes/linux-cs/wt-gpu-e1-out
cd /Volumes/linux-cs/wt-gpu-e1
{ git log --oneline -1; clang --version | head -1; rustc --version; $BINDGEN --version; echo "configs: $CONFIGS"; } > /log/toolchain.txt
( while sleep 10; do a=$(df -k "$O" | awk "NR==2{print \$4}"); if [ "$a" -lt 786432 ]; then echo "LOW DISK ($a KiB): killing make" >> /log/lowdisk.txt; pkill -f "make.*O=$O"; fi; done ) &
WD=$!
make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN rustavailable > /log/rustavailable.txt 2>&1 || true
cat /log/rustavailable.txt >> /log/toolchain.txt
grep -q "Rust is available" /log/rustavailable.txt || { echo "rust not available"; exit 1; }
make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=$LV $CONFIGS > /log/config.log 2>&1
cp $O/.config /log/config
grep -E "^CONFIG_(RUST|DRM_ASAHI|DRM_APPLE|APPLE_PMP|MTD_PHRAM|APPLE_MAILBOX)=|^# CONFIG_(APPLE_PMP|DRM_APPLE|DRM_ASAHI_M5) is not set" $O/.config > /log/config-key.txt || true
scripts/diffconfig /Volumes/linux-cs/wt-series-out/.config $O/.config > /log/diffconfig-vs-daily.txt || true
make -j12 LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=$LV Image.gz apple/t6050-j716s.dtb > /log/build.log 2>&1 || { echo "BUILD FAILED"; grep -m8 -B3 -A8 -E " error|^error" /log/build.log; kill $WD; exit 1; }
kill $WD
cat $O/include/config/kernel.release > /log/kernel.release
grep -c -i "warning" /log/build.log > /log/warnings.count || true
cp $O/arch/arm64/boot/Image.gz /log/Image.gz
cp $O/arch/arm64/boot/dts/apple/t6050-j716s.dtb /log/t6050-j716s-gpu27.dtb
cp $O/System.map /log/System.map
cd /log && sha256sum Image.gz t6050-j716s-gpu27.dtb config | tee /log/SHA256SUMS
'
echo "container build finished"
