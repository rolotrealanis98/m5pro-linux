#!/bin/bash
# E2 stage-2 m1n1 (plain, CHAINLOADING=0) with the W4 recipe (n1-wifi/w4/build.sh): Apple `container`, Fedora 43,
# clang/lld 21, rustc 1.99.1. Tree: ~/Work/agents/gpu-e2/m1n1 (clone of n1-wifi/w4/tree)
#   n1-warm          = the daily's m1n1 (0020-0023, 0025-0027), must reproduce 4c202e9d (recipe check)
#   n1-warm-gpu      = n1-warm + 0028 (E1's 0026: T6050 GPU hand-off behind chosen.m5pro,gpu=1)
#   n1-warm-gpu-dcp  = n1-warm-gpu + dcp 0024 (coprocessor logs, display hand-off behind chosen.m5,t6050-display=1)
#                      + dcp 0025 (firmware-compat 27.3.0)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HERE/m1n1
OUT=$HERE/build; mkdir -p "$OUT"
RUST=${RUST:-1.99.1}
container rm -f m1n1gpue2 >/dev/null 2>&1 || true
container run -d --name m1n1gpue2 -v "$TREE:/src" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1gpue2 >/dev/null 2>&1 || true' EXIT
container exec m1n1gpue2 bash -c "
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
    # rodata + relocations share one 128 KiB window: record how much of the image is used
    llvm-size build/m1n1.elf > /out/\$2.size 2>&1 || true
}
build n1-warm          m1n1-plain-n1-warm
build n1-warm-gpu      m1n1-plain-n1-warm-gpu
build n1-warm-gpu-dcp  m1n1-plain-n1-warm-gpu-dcp
grep -n 'warning' /out/m1n1-plain-n1-warm-gpu.log /out/m1n1-plain-n1-warm-gpu-dcp.log > /out/warnings.txt || true
cat /out/toolchain.txt
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS && cat *.commit
[ "$(shasum -a 256 m1n1-plain-n1-warm.bin | cut -c1-64)" = 4c202e9dbf0738cb256fb3903f02c6abd2d653b8cfecea74d764f19d9ce6e1d5 ] \
    && echo "RECIPE CHECK: n1-warm rebuilds byte-identical (4c202e9d)" || { echo "RECIPE CHECK FAILED"; exit 1; }
# A plain m1n1 must stay 0x400000: mk-daily.py and the payload layout put the variables at 0x400000.
for f in *.bin; do [ "$(stat -f %z "$f")" = 4194304 ] || { echo "SIZE: $f is $(stat -f %z "$f") bytes, not 0x400000"; exit 1; }; done
echo "all images 0x400000"
