#!/bin/bash
# Measure the raw image's file part (_file_end - _base, limit 0x120000) for given refs.
set -euo pipefail
TREE=$HOME/Work/agents/aurora-prs-2/m1n1; OUT=$(cd "$(dirname "$0")" && pwd)
container rm -f m1n1t6050size >/dev/null 2>&1 || true
container run -d --name m1n1t6050size -v "$TREE:/src" -v "$OUT:/out" docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1t6050size >/dev/null 2>&1 || true' EXIT
container exec m1n1t6050size bash -c "
set -e
dnf -y -q install clang lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain 1.99.1 -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
git config --global --add safe.directory '*'
: > /out/file-part.txt
for r in $*; do
  cd / && rm -rf /b && git clone -q /src /b && cd /b && git checkout -q \$r
  sed -i 's/_file_limit = 0x120000;/_file_limit = 0x200000;/' m1n1-raw.ld
  make -j8 CHAINLOADING=0 > /dev/null 2>&1 || { echo \"\$r: build failed\" >> /out/file-part.txt; continue; }
  llvm-size -A build/m1n1-raw.elf | grep -E '^\.(init|text|rodata|rela.dyn|data) ' | sed \"s|^|\$r |\" >> /out/file-part.txt
  llvm-nm -S --size-sort build/m1n1-raw.elf | grep -i -E ' [tTrRdD] ' | awk '{print \$2}' >/dev/null || true
  sed -i 's/^\(\s*\). = ALIGN(0x10000);/\1. = ALIGN(8);/' m1n1-raw.ld
  make -j8 CHAINLOADING=0 > /dev/null 2>&1 && llvm-size -A build/m1n1-raw.elf | grep -E '^\.(init|text|rodata|rela.dyn|data) ' | sed \"s|^|\$r unpadded |\" >> /out/file-part.txt || echo \"\$r: unpadded build failed\" >> /out/file-part.txt
  b=\$(llvm-nm build/m1n1-raw.elf | awk '\$3==\"_base\"{print \$1}'); e=\$(llvm-nm build/m1n1-raw.elf | awk '\$3==\"_file_end\"{print \$1}')
  printf '%s %s: file part 0x%x (limit 0x120000)\n' \$r \"\$(git log --format=%s -1)\" \$((0x\$e - 0x\$b)) >> /out/file-part.txt
done
"
cat "$OUT/file-part.txt"
