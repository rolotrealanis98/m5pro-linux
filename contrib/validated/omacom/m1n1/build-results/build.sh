#!/bin/bash
# Build the omacom/m1n1 T6050 series (worktree ~/Work/agents/omacom-m1n1/tree) with the aurora-prs-2
# recipe: Apple `container`, Fedora 43, clang/lld 21, rustc 1.99.1 (m1n1-t6050-bringup/build/build.sh style).
#   base0     = omacom/integration/aurora 121fcbf (the default branch)
#   base      = omacom/m1n1#30 head ad08bf5 (edimoldovan j714c/diskboot), warning baseline
#   cNN       = each commit of the series, plain `make` (the boot-test image)
#   ci-<tip>  = each branch tip and base with `make CHAINLOADING=1` (omacom CI's build)
#   pytest    = omacom CI's pytest set on base and each tip (gcc host compiler, as CI's default job)
#   clang-format = `git clang-format --diff` of each branch against its parent branch
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HOME/Work/agents/aurora-prs-2/m1n1   # main repo: the worktree's .git file points outside the container
OUT=$HERE; RUST=${RUST:-1.99.1}
G="git -C $TREE"
BASE0=$($G rev-parse omacom/integration/aurora); BASE=$($G rev-parse omacom-pr/30)
TIPS="omacom/t6050-bringup omacom/t6050-n1 omacom/t6050-gpu omacom/t6050-display omacom/wdt-keep"
STANDALONE=$($G rev-parse omacom/wdt-keep-standalone)
: > "$OUT/refs.txt"
for t in $TIPS; do echo "$t $($G rev-parse $t)" >> "$OUT/refs.txt"; done
COMMITS=$($G rev-list --reverse $BASE..omacom/wdt-keep | tr '\n' ' ')
TIPSHA=$(for t in $TIPS; do $G rev-parse $t; done | tr '\n' ' ')
LAST=$($G rev-parse omacom/wdt-keep)
container rm -f omacomm1n1build >/dev/null 2>&1 || true
container run -d --name omacomm1n1build --memory 4G -v "$TREE:/src" -v "$OUT:/out" docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f omacomm1n1build >/dev/null 2>&1 || true' EXIT
container exec omacomm1n1build bash -c "
set -e
dnf -y -q install clang clang-tools-extra lld llvm make git python3 python3-pip git-clang-format rustup ImageMagick diffutils which gcc >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain $RUST -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
pip install -q -r /src/requirements.txt pytest==9.1.1 unicorn capstone pyelftools >/dev/null 2>&1 || pip install -q construct==2.10.70 pyserial==3.5 pytest==9.1.1
{ clang --version | head -1; ld.lld --version | head -1; gcc --version | head -1; rustc --version; cargo --version;
  make --version | head -1; python3 --version; pytest --version; rpm -q clang lld llvm make gcc; } > /out/toolchain.txt 2>&1
git config --global --add safe.directory '*'
build() { # <sha> <name> [make args]
    cd / && rm -rf /build && git clone -q /src /build && cd /build && git checkout -q \$1
    git log --oneline -1 > /out/\$2.commit
    make -j8 \${@:3} > /out/\$2.log 2>&1 || { echo \"\$2: BUILD FAILED\" >> /out/warnings.txt; tail -30 /out/\$2.log; return 0; }
    cp build/m1n1.bin /out/\$2.bin
    file_end=\$(llvm-nm build/m1n1-raw.elf | awk '\$3==\"_file_end\"{print \$1}'); b=\$(llvm-nm build/m1n1-raw.elf | awk '\$3==\"_base\"{print \$1}')
    echo \"\$2: \$(grep -c 'warning:' /out/\$2.log) warnings, m1n1.bin \$(stat -c %s build/m1n1.bin) bytes (0x\$(printf %x \$(stat -c %s build/m1n1.bin))), file part 0x\$(printf %x \$((0x\$file_end - 0x\$b))) of 0x120000\" >> /out/warnings.txt
}
: > /out/warnings.txt
build $BASE0 base0
build $BASE base
n=0; for c in $COMMITS; do n=\$((n+1)); build \$c c\$(printf %02d \$n); done
build $BASE ci-base CHAINLOADING=1
i=0; for t in $TIPSHA; do i=\$((i+1)); build \$t ci-tip\$i CHAINLOADING=1; done
build $BASE0 ci-base0 CHAINLOADING=1
build $STANDALONE wdt-standalone
build $STANDALONE ci-wdt-standalone CHAINLOADING=1
sed -E 's/:[0-9]+:[0-9]+:/:/' /out/base.log | grep 'warning:' | sort -u > /tmp/b
sed -E 's/:[0-9]+:[0-9]+:/:/' /out/ci-base.log | grep 'warning:' | sort -u > /tmp/cb
for l in /out/c[0-9]*.log; do sed -E 's/:[0-9]+:[0-9]+:/:/' \$l | grep 'warning:' | sort -u | comm -13 /tmp/b - | sed \"s|^|\$(basename \$l): NEW |\"; done > /out/new-warnings.txt
for l in /out/ci-tip*.log; do sed -E 's/:[0-9]+:[0-9]+:/:/' \$l | grep 'warning:' | sort -u | comm -13 /tmp/cb - | sed \"s|^|\$(basename \$l): NEW |\"; done >> /out/new-warnings.txt
# pytest: omacom CI's set, base and each tip
: > /out/pytest.txt
for t in $BASE0 $BASE $TIPSHA $STANDALONE; do
    cd / && rm -rf /pt && git clone -q /src /pt && cd /pt && git checkout -q \$t
    r=\$(timeout 1800 pytest -q -p no:cacheprovider tests/python tests/test_t8122_gpu_reader.py tests/test_t8122_gpu_resources.py 2>&1 | tail -1)
    echo \"\$(git log --oneline -1 | cut -c1-60): \$r\" >> /out/pytest.txt
    pytest -q -p no:cacheprovider -rfE tests/python tests/test_t8122_gpu_reader.py tests/test_t8122_gpu_resources.py > /out/pytest-\$(git rev-parse --short=7 HEAD).log 2>&1 || true
    grep -E '^(FAILED|ERROR)' /out/pytest-\$(git rev-parse --short=7 HEAD).log | sed 's/^/    /' >> /out/pytest.txt || true
done
# clang-format of each branch's own lines
cd /build; : > /out/clang-format.txt; prev=$BASE
for t in $TIPSHA; do echo \"== \$(git log --oneline -1 \$t | cut -c1-70)\" >> /out/clang-format.txt; git clang-format --diff \$prev \$t -- src >> /out/clang-format.txt 2>&1 || true; prev=\$t; done
git diff $BASE $LAST > /out/series.diff
for l in /out/*.log; do case \$l in */pytest-*) continue;; esac; echo \"\$(basename \$l .log): \$(grep -o 'warning: .*' \$l | sort | md5sum | cut -c1-8)\"; done > /out/warning-sets.txt
cat /out/toolchain.txt /out/warnings.txt /out/new-warnings.txt /out/pytest.txt /out/clang-format.txt
"
cd "$OUT" && shasum -a 256 *.bin | tee SHA256SUMS
