#!/bin/bash
# build-modules.sh SRC OUT RELEASE TARGETS_FILE [override]
# Builds the listed .ko targets of an existing out-of-tree kernel build, stages them like
# modules_install (stripped of debug info) and tars the stage. Never builds Image/vmlinux targets and
# never cleans OUT. Why not `make modules`: the volume holding the out dirs had ~5 GiB free and the
# full =m set (~4900 objects with DEBUG_INFO) needs more; modules_install also needs every module built.
# "override" passes KERNELRELEASE=RELEASE (use when HEAD no longer matches the release the Image reports).
set -eu
SRC=$1; OUT=$2; REL=$3; TF=$4; OVR=${5:-}
HERE=$(cd "$(dirname "$0")" && pwd); TF=$(cd "$(dirname "$TF")" && pwd)/$(basename "$TF")
[ -s "$TF" ] || { echo "no targets file $TF" >&2; exit 1; }
export PATH=/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH
export ARCH=arm64 LLVM=1 HOSTCFLAGS="-I$HOME/Work/omarchy-m5/scripts/host-shim"
KR=(); [ "$OVR" = override ] && KR=("KERNELRELEASE=$REL")
cd "$SRC"
( while sleep 10; do a=$(df -k "$OUT" | awk 'NR==2{print $4}'); if [ "$a" -lt 786432 ]; then echo "LOW DISK ($a KiB): killing make"; pkill -f "make.*O=$OUT"; fi; done ) &
WD=$!; trap 'kill $WD 2>/dev/null' EXIT
make O="$OUT" "${KR[@]}" KBUILD_MODPOST_WARN=1 "HOSTCFLAGS_file2alias.o=-D_POSIX_C_SOURCE=200809L" -j16 $(cat "$TF" | tr '\n' ' ')
STAGE=$HERE/modstage-$REL
rm -rf "$STAGE"; D=$STAGE/lib/modules/$REL; mkdir -p "$D/kernel"
: > "$D/modules.order"
while read -r k; do
  [ -f "$OUT/$k" ] || { echo "MISSING $k"; continue; }
  mkdir -p "$D/kernel/$(dirname "$k")"
  llvm-strip --strip-debug -o "$D/kernel/$k" "$OUT/$k"
  echo "kernel/$k" >> "$D/modules.order"
done < "$TF"
cp "$OUT/modules.builtin" "$OUT/modules.builtin.modinfo" "$D/"
echo BUILD_DONE
