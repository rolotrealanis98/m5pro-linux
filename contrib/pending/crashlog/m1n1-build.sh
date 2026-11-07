#!/bin/bash
# Build the crashlog-pram stage-2 m1n1 (plain, CHAINLOADING=0) with the m1n1-r2 / pipe-park recipe
# (~/Work/agents/pipe-park/build.sh): Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1.
# Refs of ~/Work/agents/m1n1-r2/tree:
#   pipe-park-r2-atc  f7555558 = the daily's m1n1, must reproduce 28b26ebc... (recipe check)
#   pram-ramoops      f7555558 + 0028 (ramoops node from /pram)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HOME/Work/agents/m1n1-r2/tree
OUT=$HERE/build; mkdir -p "$OUT"
RUST=${RUST:-1.99.1}
container rm -f m1n1prambuild >/dev/null 2>&1 || true
container run -d --name m1n1prambuild -v "$TREE:/src" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1prambuild >/dev/null 2>&1 || true' EXIT
container exec m1n1prambuild bash -c "
set -e
dnf -y -q install clang lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain $RUST -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
{ clang --version | head -1; ld.lld --version | head -1; rustc --version; cargo --version;
  make --version | head -1; rpm -q clang lld llvm make ImageMagick; } > /out/toolchain.txt
git config --global --add safe.directory '*'
build() { # <ref> <name>
    cd / && rm -rf /build && git clone -q /src /build && cd /build && git checkout -q \$1
    git log --oneline -1 > /out/\$2.commit
    make -j8 CHAINLOADING=0 > /out/\$2.log 2>&1
    cp build/m1n1.bin /out/\$2.bin
}
build pipe-park-r2-atc m1n1-plain-r2-pipepark-atc
build pram-ramoops     m1n1-plain-r2-pipepark-atc-pram
cat /out/toolchain.txt
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS && cat *.commit
