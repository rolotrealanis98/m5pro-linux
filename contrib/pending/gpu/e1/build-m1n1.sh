#!/bin/bash
# Build the E1 stage-2 m1n1 (plain, CHAINLOADING=0) with the m1n1-r2 recipe (n1-wifi/w2/build.sh):
# Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1. Tree: ~/Work/agents/gpu-e1/m1n1
#   base = pipe-park-r2-atc f7555558 (0017+0018+0020+0021): must reproduce the daily's m1n1
#          m1n1-plain-r2-pipepark-atc.bin 28b26ebc (recipe check)
#   gpu  = base + 0026 (T6050 GPU hand-off behind chosen.m5pro,gpu=1)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HERE/m1n1
OUT=$HERE/build; mkdir -p "$OUT"
RUST=${RUST:-1.99.1}
container rm -f m1n1gpue1 >/dev/null 2>&1 || true
container run -d --name m1n1gpue1 -v "$TREE:/src" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1gpue1 >/dev/null 2>&1 || true' EXIT
container exec m1n1gpue1 bash -c "
set -e
dnf -y -q install clang clang-tools-extra lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain $RUST -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
{ clang --version | head -1; ld.lld --version | head -1; rustc --version; cargo --version;
  make --version | head -1; rpm -q clang lld llvm make ImageMagick; } > /out/toolchain.txt
git config --global --add safe.directory '*'
build() { # <ref> <name>
    cd / && rm -rf /build && git clone -q /src /build && cd /build && git checkout -q \$1
    git log --oneline -1 > /out/\$2.commit; git describe --tags --always >> /out/\$2.commit
    make -j8 CHAINLOADING=0 > /out/\$2.log 2>&1
    cp build/m1n1.bin /out/\$2.bin
}
build f7555558 m1n1-plain-base
build gpu-e1   m1n1-plain-gpu
cd /build && git checkout -q gpu-e1 && clang-format --dry-run src/kboot_gpu.c src/pmgr.c src/pmgr.h src/kboot.h > /out/clang-format.txt 2>&1 || true
grep -n 'warning' /out/m1n1-plain-gpu.log > /out/warnings-gpu.txt || true
cat /out/toolchain.txt
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS && cat *.commit && ls -l *.bin
