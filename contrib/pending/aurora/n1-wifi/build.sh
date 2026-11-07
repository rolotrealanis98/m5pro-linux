#!/bin/bash
# Build the N1 stage-2 m1n1 (plain, CHAINLOADING=0) with the m1n1-r2 recipe
# (~/Work/agents/m1n1-r2/build.sh, BUILD.md): Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1.
# Refs of ~/Work/agents/m1n1-r2/tree:
#   pipe-park-atc d5b29b03 + 0020 + 0021, must reproduce pipe-park's m1n1-plain-pipepark-atc.bin (recipe check)
#   n1-handoff~1  pipe-park-atc + 0022 (N1 DT fill-in)
#   n1-handoff    pipe-park-atc + 0022 + 0023 (apcie0 port 0 training behind chosen.m5pro,n1)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HOME/Work/agents/m1n1-r2/tree
OUT=$HERE/build; mkdir -p "$OUT"
RUST=${RUST:-1.99.1}
container rm -f m1n1n1build >/dev/null 2>&1 || true
container run -d --name m1n1n1build -v "$TREE:/src" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1n1build >/dev/null 2>&1 || true' EXIT
container exec m1n1n1build bash -c "
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
build pipe-park-atc m1n1-plain-pipepark-atc
build n1-handoff~1  m1n1-plain-n1-dt
build n1-handoff    m1n1-plain-n1-train
cat /out/toolchain.txt
"
cd "$OUT" && shasum -a 256 *.bin && cat *.commit
