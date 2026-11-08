#!/usr/bin/env bash
# Build the open AVD CM3 firmware image the T6050 variant loads (apple/avd-fw-v5-t2.bin) from the local
# clone of aurora-silicon/avd-fw (the tree Aurora's drivers/media/platform/apple/avd Kconfig points at),
# with Homebrew LLVM 23 (clang --target=arm-none-eabi, ld.lld, llvm-objcopy). The clone is never built in
# place: `git archive HEAD` is unpacked into a scratch directory, built twice (the two images must be
# byte-identical), checked with the tree's own tests/check-images.py (size 0x12000, SP, reset vector) and
# the host-side queue test, then copied here with its sha256 and the source commit.
#   ~/Work/agents/avd/build-avd-fw.sh            -> ~/Work/agents/avd/firmware/avd-fw-v5-t2.bin
set -euo pipefail
SRC=$HOME/Work/agents/video-t6050/ref/avd-fw
OUT=$HOME/Work/agents/avd/firmware
export PATH=/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH
T=$(mktemp -d "${TMPDIR:-/tmp}/avd-fw-build.XXXXXX"); trap 'rm -rf "$T"' EXIT
git -C "$SRC" archive --format=tar HEAD | tar -x -C "$T"
git -C "$SRC" rev-parse HEAD > "$T/SOURCE-COMMIT.txt"
cd "$T"
make -s AVD_VER=5 AVD_TIER=2 CC=clang OBJCOPY=llvm-objcopy
cp build/avd-fw-v5-t2.bin first.bin; cp build/avd-fw-v5-t2.elf first.elf
make -s clean; make -s AVD_VER=5 AVD_TIER=2 CC=clang OBJCOPY=llvm-objcopy
cmp first.bin build/avd-fw-v5-t2.bin || { echo "the two builds differ"; exit 1; }
python3 -I tests/check-images.py build/avd-fw-v5-t2.bin
make -s test
mkdir -p "$OUT"; chmod 700 "$OUT"
cp build/avd-fw-v5-t2.bin build/avd-fw-v5-t2.elf "$OUT/"; cp SOURCE-COMMIT.txt "$OUT/avd-fw-source-commit.txt"
( cd "$OUT" && sha256sum avd-fw-v5-t2.bin avd-fw-v5-t2.elf > SHA256SUMS && cat SHA256SUMS && echo "source $(cat avd-fw-source-commit.txt)" )
