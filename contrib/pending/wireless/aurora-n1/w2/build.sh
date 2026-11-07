#!/bin/bash
# Build the W2 stage-2 m1n1 (plain, CHAINLOADING=0) with the m1n1-r2 recipe (m1n1-BUILD.md):
# Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1. Tree: ~/Work/agents/n1-wifi/w2/tree
#   n1-handoff  = 0020+0021+0022+0023, must reproduce n1-wifi/build/m1n1-plain-n1-train.bin (d31e5248, recipe check)
#   n1-ans      = n1-handoff + 0025 (ANS started for the storage checks, chosen.m5pro,n1=3|4), must reproduce 69730b19 (W2/W2b)
#   n1-smc      = n1-ans + 0026 (SMC gP13 pulse as on J813, n1=4|5; J813 port order, n1=5)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HERE/tree
OUT=$HERE/build; mkdir -p "$OUT"
RUST=${RUST:-1.99.1}
container rm -f m1n1w2build >/dev/null 2>&1 || true
container run -d --name m1n1w2build -v "$TREE:/src" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1w2build >/dev/null 2>&1 || true' EXIT
container exec m1n1w2build bash -c "
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
build n1-handoff m1n1-plain-n1-train
build n1-ans     m1n1-plain-n1-ans
build n1-smc     m1n1-plain-n1-smc
cd /build && git checkout -q n1-smc && clang-format --dry-run src/pcie_t6050.c src/pcie_t6050.h src/kboot_n1.c src/rtkit.c src/rtkit.h > /out/clang-format.txt 2>&1 || true
cat /out/toolchain.txt
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS && cat *.commit
# A plain m1n1 must stay 0x400000: mk-daily.py and the payload layout put the variables at 0x400000.
# rodata + relocations share one 128 KiB window; n1-ans/n1-smc leave 0x28 bytes of it.
for f in *.bin; do [ "$(stat -f %z "$f")" = 4194304 ] || { echo "SIZE: $f is $(stat -f %z "$f") bytes, not 0x400000"; exit 1; }; done
