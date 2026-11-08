#!/bin/bash
# Compile-check the nvme-shutdown branch with the daily-n1k config (one container, -j8).
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
LOG=$S/log; mkdir -p "$LOG"
container rm -f knvmeshut >/dev/null 2>&1 || true
container run -d --name knvmeshut -m 16g -c 8 -v /Volumes/linux-cs:/Volumes/linux-cs -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f knvmeshut >/dev/null 2>&1 || true' EXIT
container exec knvmeshut bash -c '
set -euo pipefail
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
git config --global --add safe.directory "*"
O=/Volumes/linux-cs/wt-nvme-shutdown-out
cd /Volumes/linux-cs/wt-nvme-shutdown
export BINDGEN=/Volumes/linux-cs/wt-daily-n1k/tools/aurora-bindgen/build/bin/bindgen
test -f $O/.config
M="make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN"
$M olddefconfig > /log/olddefconfig.log 2>&1
$M -j8 prepare > /log/prepare.log 2>&1 || { tail -20 /log/prepare.log; exit 1; }
$M -j8 W=1 drivers/nvme/host/apple.o drivers/power/reset/macsmc-reboot.o > /log/w1.log 2>&1 || { tail -30 /log/w1.log; exit 1; }
echo BUILD-OK
'
