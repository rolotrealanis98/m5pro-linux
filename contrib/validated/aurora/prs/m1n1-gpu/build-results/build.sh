#!/bin/bash
# Build aurora-silicon/m1n1 pr/t6050-gpu-handoff with the aurora-prs-2 / m1n1-t6050-bringup recipe:
# Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1. Branch worktree: ~/Work/agents/m1n1-gpu-pr/tree
#   base     = origin/aurora-wip b6b4592 (warning baseline); must rebuild byte-identical to
#              m1n1-t6050-bringup/build base.bin 485b8bf3 (recipe check)
#   bringup  = pr/t6050-bringup d8a0458; must rebuild byte-identical to tip-default ecd93f2f (recipe check)
#   gpu      = pr/t6050-gpu-handoff, plain `make` (the boot-test image)
#   gpu65    = tmp/stack-gpu-65: tmp/stack-65 (bring-up + #65 v2) + the GPU commit, to show they combine
#   lineage  = our m5pro-linux stage 2 n1-warm (gpu-e2/m1n1); must rebuild byte-identical to 4c202e9d
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HOME/Work/agents/aurora-prs-2/m1n1   # main repo: the worktree .git file points outside the container
LINEAGE=$HOME/Work/agents/gpu-e2/m1n1
OUT=$HERE; RUST=${RUST:-1.99.1}
BASE=b6b459221ede06c255804b54b174383c50c3d7f0
container rm -f m1n1gpupr >/dev/null 2>&1 || true
container run -d --name m1n1gpupr -v "$TREE:/src" -v "$LINEAGE:/lineage" -v "$OUT:/out" \
    docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1gpupr >/dev/null 2>&1 || true' EXIT
container exec m1n1gpupr bash -c "
set -e
dnf -y -q install clang clang-tools-extra lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain $RUST -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
{ clang --version | head -1; ld.lld --version | head -1; rustc --version; cargo --version;
  make --version | head -1; rpm -q clang lld llvm make; } > /out/toolchain.txt
git config --global --add safe.directory '*'
build() { # <repo> <ref> <name> [make args]
    cd / && rm -rf /build && git clone -q \$1 /build && cd /build && git checkout -q \$2
    git log --oneline -1 > /out/\$3.commit
    make -j8 \${@:4} > /out/\$3.log 2>&1
    cp build/m1n1.bin /out/\$3.bin
    llvm-size -A build/m1n1.elf > /out/\$3.size
    # headroom: last byte of code before .text is padded to 64 KiB, and of rodata+relocations before .data
    llvm-nm -n -S --defined-only build/m1n1.elf | awk '\$3 ~ /^[tT]\$/ && NF == 4 {e = strtonum(\"0x\" \$1) + strtonum(\"0x\" \$2)}
        \$4 == \"_rela_end\" {r = strtonum(\"0x\" \$1)} \$NF == \"_rodata_end\" {d = strtonum(\"0x\" \$1)} \$NF == \"_text_size\" {t = strtonum(\"0x\" \$1)}
        END {printf \"text used to 0x%x of 0x%x (0x%x free); rodata+rela used to 0x%x of 0x%x (0x%x free)\\n\", e, 0x10000 + t, 0x10000 + t - e, r, d, d - r}' >> /out/\$3.size
    echo \"\$3: \$(grep -c 'warning:' /out/\$3.log) warnings, \$(stat -c %s build/m1n1.bin) bytes (0x\$(printf %x \$(stat -c %s build/m1n1.bin)))\" >> /out/warnings.txt
}
: > /out/warnings.txt
build /src $BASE base CHAINLOADING=0
build /src pr/t6050-bringup bringup
build /src pr/t6050-gpu-handoff gpu
build /src tmp/stack-gpu-65 gpu65
build /lineage n1-warm lineage CHAINLOADING=0
cd / && rm -rf /build && git clone -q /src /build && cd /build && git checkout -q pr/t6050-gpu-handoff
git diff -U0 origin/pr/t6050-bringup -- src | clang-format-diff -p1 > /out/clang-format.txt 2>&1 || true
git diff origin/pr/t6050-bringup HEAD > /out/gpu.diff
# line numbers and stack-usage byte counts move with unrelated code; stack.txt keeps the per-function values
norm() { sed -E 's/:[0-9]+:[0-9]+:/:/; s/stack usage is [0-9]+ bytes/stack usage is N bytes/' \$1 | grep 'warning:' | sort -u; }
norm /out/base.log > /tmp/b
for l in /out/bringup.log /out/gpu.log /out/gpu65.log; do norm \$l | comm -13 /tmp/b - | sed \"s|^|\$(basename \$l): NEW |\"; done > /out/new-warnings.txt
for l in /out/base.log /out/bringup.log /out/gpu.log /out/gpu65.log; do grep -B1 'stack usage' \$l | grep -oE \"In function '[^']+'|stack usage is [0-9]+ bytes\" | paste - - | sed \"s|^|\$(basename \$l): |\"; done > /out/stack.txt
cat /out/toolchain.txt /out/warnings.txt /out/new-warnings.txt /out/stack.txt; grep -h 'text used' /out/*.size
echo clang-format: \$(wc -l < /out/clang-format.txt) lines
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS && cat *.commit
check() { [ "$(shasum -a 256 "$1" | cut -c1-64)" = "$2" ] && echo "RECIPE CHECK: $1 byte-identical (${2:0:8})" || { echo "RECIPE CHECK FAILED: $1"; exit 1; }; }
check base.bin 485b8bf373d438c85728b50ed87dcf7798befe302698f97e7c9c42acfb312475
check bringup.bin ecd93f2f7aacd5c3234dbce86b8f3d306f1d8fb3b08e0420ec78680fea9ffc62
check lineage.bin 4c202e9dbf0738cb256fb3903f02c6abd2d653b8cfecea74d764f19d9ce6e1d5
