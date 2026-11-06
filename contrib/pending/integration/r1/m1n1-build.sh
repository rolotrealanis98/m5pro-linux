#!/bin/bash
# Build the R2 stage-2 m1n1 (plain, CHAINLOADING=0) with a Linux toolchain in an Apple
# `container` Fedora 43 VM: the recipe that produced the R1 m1n1-plain.bin (742c5981...,
# ~/Work/m1n1-linuxbuild, 2026-11-04), with rustc pinned to the version used then.
#
# Builds three commits of tree/ (a clone of ~/Work/m1n1 m5-t6050 + 0017 + 0018):
#   459a3af2 (baseline, must reproduce 742c5981...), 01cf956d (+0017), HEAD (+0017 +0018).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/build; mkdir -p "$OUT"
RUST=${RUST:-1.99.1}
container rm -f m1n1r2build >/dev/null 2>&1 || true
container run -d --name m1n1r2build -v "$HERE/tree:/src" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1r2build >/dev/null 2>&1 || true' EXIT
container exec m1n1r2build bash -c "
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
build 459a3af2 m1n1-plain-baseline
build 01cf956d m1n1-plain-notch
build m1n1-r2  m1n1-plain-r2
cat /out/toolchain.txt
"
cd "$OUT" && shasum -a 256 *.bin && cat *.commit
