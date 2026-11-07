#!/bin/bash
# Build aurora-silicon/m1n1 pr/t6050-display (the T6050 display hand-off series) with the
# m1n1-t6050-bringup recipe: Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1.
#   base        = origin/aurora-wip (b6b4592), warning baseline
#   below       = pr/t6050-bringup + #65 (tmp/stack-65, 1b253f1), the series' parent
#   d1..dN      = each display commit, plain (CHAINLOADING=0)
#   tip-default = the branch tip with a plain `make` (the boot-test image)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HOME/Work/agents/aurora-prs-2/m1n1  # main repo: the worktree .git file points outside the container
OUT=$HERE; RUST=${RUST:-1.99.1}
BASE=b6b459221ede06c255804b54b174383c50c3d7f0
BELOW=1b253f1
TIP=pr/t6050-display
container rm -f m1n1t6050disp >/dev/null 2>&1 || true
container run -d --name m1n1t6050disp -v "$TREE:/src" -v "$OUT:/out" docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f m1n1t6050disp >/dev/null 2>&1 || true' EXIT
container exec m1n1t6050disp bash -c "
set -e
dnf -y -q install clang clang-tools-extra lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain $RUST -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
{ clang --version | head -1; ld.lld --version | head -1; rustc --version; cargo --version;
  make --version | head -1; rpm -q clang lld llvm make; } > /out/toolchain.txt
git config --global --add safe.directory '*'
build() { # <ref> <name> [make args]
    cd / && rm -rf /build && git clone -q /src /build && cd /build && git checkout -q \$1
    git log --oneline -1 > /out/\$2.commit
    make -j8 \${@:3} > /out/\$2.log 2>&1
    cp build/m1n1.bin /out/\$2.bin
    echo \"\$2: \$(grep -c 'warning:' /out/\$2.log) warnings, \$(stat -c %s build/m1n1.bin) bytes\" >> /out/warnings.txt
}
: > /out/warnings.txt
build $BASE base CHAINLOADING=0
build $BELOW below CHAINLOADING=0
n=0; for c in \$(git -C /src rev-list --reverse $BELOW..$TIP); do n=\$((n+1)); build \$c d\$n CHAINLOADING=0; done
build $TIP tip-default
cd /build && git checkout -q $TIP
CFD=\$(command -v clang-format-diff || ls /usr/share/clang/clang-format-diff.py /usr/bin/clang-format-diff* 2>/dev/null | head -1)
echo \"clang-format-diff: \$CFD\" > /out/clang-format.log
git diff -U0 $BELOW $TIP -- src | python3 \$CFD -p1 > /out/clang-format.txt 2>>/out/clang-format.log || true
echo \"clang-format-diff on the series' changed lines: \$(wc -l < /out/clang-format.txt) lines of suggested change\" >> /out/clang-format.txt
git diff $BELOW $TIP > /out/series.diff
sed -E 's/:[0-9]+:[0-9]+:/:/' /out/base.log | grep 'warning:' | sort -u > /tmp/b
for l in /out/below.log /out/d*.log /out/tip-default.log; do sed -E 's/:[0-9]+:[0-9]+:/:/' \$l | grep 'warning:' | sort -u | comm -13 /tmp/b - | sed \"s|^|\$(basename \$l): NEW |\"; done > /out/new-warnings.txt
cat /out/toolchain.txt /out/warnings.txt /out/new-warnings.txt /out/clang-format.txt
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS && cat *.commit
