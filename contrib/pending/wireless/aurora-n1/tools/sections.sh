#!/bin/bash
# Print the 64K-aligned section layout of m1n1 builds (same recipe as build.sh) for given refs.
set -euo pipefail
TREE=$HOME/Work/agents/m1n1-r2/tree
OUT=$HOME/Work/agents/n1-wifi/build/sections; mkdir -p "$OUT"
container rm -f m1n1n1sec >/dev/null 2>&1 || true
container run -d --name m1n1n1sec -v "$TREE:/src" -v "$OUT:/out" docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1n1sec >/dev/null 2>&1 || true' EXIT
container exec m1n1n1sec bash -c "
set -e
dnf -y -q install clang lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain 1.99.1 -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
git config --global --add safe.directory '*'
for ref in $*; do
  cd / && rm -rf /build && git clone -q /src /build && cd /build && git checkout -q \$ref
  make -j8 CHAINLOADING=0 >/dev/null 2>&1
  echo \"== \$ref \$(git log --oneline -1)\"; llvm-readelf -S build/m1n1.elf | grep -E ' \.(init|text|rodata|rela|data|bss)' 
  llvm-nm build/m1n1.elf | grep -E ' _rela_(start|end)$'
  cp build/m1n1.bin /out/\$(echo \$ref | tr '~/' '__').bin
done
" | tee "$OUT/sections.txt"
