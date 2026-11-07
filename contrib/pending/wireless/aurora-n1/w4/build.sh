#!/bin/bash
# Build the W4 stage-2 m1n1 (plain, CHAINLOADING=0) with the m1n1-r2 recipe (m1n1-BUILD.md):
# Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1. Tree: ~/Work/agents/n1-wifi/w2/tree
#   n1-smc   = 0020-0023 + 0025 + 0026, must reproduce w2's a4cc59fd (W2c/W3b/daily-wifi m1n1, recipe check)
#   n1-warm  = n1-smc + 0027 (warm N1 / live port at entry, bounded SMC waits)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HERE/tree
OUT=$HERE/build; mkdir -p "$OUT"
RUST=${RUST:-1.99.1}
container rm -f m1n1w4build >/dev/null 2>&1 || true
container run -d --name m1n1w4build -v "$TREE:/src" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1w4build >/dev/null 2>&1 || true' EXIT
container exec m1n1w4build bash -c "
set -e
dnf -y -q install clang clang-tools-extra lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
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
build n1-smc     m1n1-plain-n1-smc
build n1-warm    m1n1-plain-n1-warm
cd /build && git checkout -q n1-warm && clang-format --dry-run src/pcie_t6050.c src/smc.c src/smc.h > /out/clang-format.txt 2>&1 || true
cat /out/toolchain.txt
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS && cat *.commit
# A plain m1n1 must stay 0x400000: mk-daily.py and the payload layout put the variables at 0x400000.
# rodata + relocations share one 128 KiB window (see 0026/0027).
for f in *.bin; do [ "$(stat -f %z "$f")" = 4194304 ] || { echo "SIZE: $f is $(stat -f %z "$f") bytes, not 0x400000"; exit 1; }; done
