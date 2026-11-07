#!/usr/bin/env bash
# Rust-enabled Aurora kernel build inside the Apple `container` Fedora 43 VM (Linux host: Aurora's bindgen patch and
# layout checks are built for Linux). Mounts /Volumes/linux-cs at the same path so the git worktree resolves.
set -euo pipefail
OUT=$HOME/Work/agents/audio-aurora/kbuild; mkdir -p "$OUT"
container rm -f kaudio >/dev/null 2>&1 || true
container run -d --name kaudio -m 24g -c 12 -v /Volumes/linux-cs:/Volumes/linux-cs -v "$OUT:/out" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kaudio >/dev/null 2>&1 || true' EXIT
container exec kaudio bash -c '
set -euo pipefail
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
cd /Volumes/linux-cs/wt-aurora-audio
git config --global --add safe.directory "*"
{ clang --version | head -1; rustc --version; } > /out/toolchain.txt
echo "== aurora-bindgen ==" >> /out/toolchain.txt
[ -x tools/aurora-bindgen/build/bin/bindgen ] || python3 tools/aurora-bindgen/build.py >> /out/bindgen.log 2>&1 || { echo "bindgen build failed" >> /out/toolchain.txt; tail -20 /out/bindgen.log; exit 1; }
B=tools/aurora-bindgen/build/bin/bindgen; echo "BINDGEN=$B" >> /out/toolchain.txt
export BINDGEN=$PWD/$B
make LLVM=1 ARCH=arm64 O=/out/obj rustavailable > /out/rustavailable.txt 2>&1; cat /out/rustavailable.txt >> /out/toolchain.txt; grep "Rust is available" /out/rustavailable.txt >/dev/null || { echo "rust not available"; exit 1; }
mkdir -p /out/obj && cp /out/config.seed /out/obj/.config
make LLVM=1 ARCH=arm64 O=/out/obj olddefconfig >/dev/null
grep -E "^CONFIG_(RUST|APPLE_AOP|SND_SOC_APPLE_MACAUDIO)=" /out/obj/.config
make -j12 LLVM=1 ARCH=arm64 O=/out/obj Image.gz > /out/build.log 2>&1 || { echo "BUILD FAILED"; grep -m5 -B3 " error" /out/build.log; exit 1; }
sha256sum /out/obj/arch/arm64/boot/Image.gz
'
echo "container build finished"
