#!/usr/bin/env bash
# build-modules.sh: the daily's module set (../modules-next2/targets.txt, 128 .ko incl. phram) for the E2 kernel
# (j716s-series-gpu-27, ../gpu-e2/build-kernel.sh, out dir /Volumes/linux-cs/wt-gpu-e1-out), built inside the
# Fedora 43 container exactly as ../modules-next2/build-modules.sh does; targets this config builds in (listed in
# its modules.builtin: phram, drm_exec, drm_gpuvm, drm_sched with j716s-gpu.config) are dropped into
# targets-builtin.txt. Stages them stripped under usr/lib/modules/REL and tars them.
# Never cleans OUT, never builds Image/vmlinux targets, creates no new out dir.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
REL=${REL:?set REL to the E2 kernel release}
container rm -f kmodsgpu27 >/dev/null 2>&1 || true
container run -d --name kmodsgpu27 -m 24g -c 12 -v /Volumes/linux-cs:/Volumes/linux-cs -v "$S:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kmodsgpu27 >/dev/null 2>&1 || true' EXIT
container exec -e REL=$REL kmodsgpu27 bash -c '
set -euo pipefail
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
git config --global --add safe.directory "*"
export BINDGEN=/Volumes/linux-cs/wt-aurora-audio2/tools/aurora-bindgen/build/bin/bindgen
O=/Volumes/linux-cs/wt-gpu-e1-out
cd /Volumes/linux-cs/wt-gpu-e1
[ "$(cat $O/include/config/kernel.release)" = "$REL" ]
grep -vxF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets.txt || true
grep -xF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets-builtin.txt || true
sha256sum $O/arch/arm64/boot/Image.gz > /log/image.before
( while sleep 10; do a=$(df -k "$O" | awk "NR==2{print \$4}"); if [ "$a" -lt 786432 ]; then echo "LOW DISK ($a KiB): killing make"; pkill -f "make.*O=$O"; fi; done ) &
WD=$!
make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN KBUILD_MODPOST_WARN=1 -j12 $(tr "\n" " " < /log/targets.txt) > /log/build.log 2>&1 || { echo "MODULE BUILD FAILED"; grep -m8 -B3 -A6 -E " error|^error" /log/build.log; kill $WD; exit 1; }
kill $WD
STAGE=/log/modstage-$REL
rm -rf "$STAGE"; D=$STAGE/usr/lib/modules/$REL; mkdir -p "$D/kernel"
: > "$D/modules.order"
while read -r k; do
  [ -f "$O/$k" ] || { echo "MISSING $k"; continue; }
  mkdir -p "$D/kernel/$(dirname "$k")"
  llvm-strip --strip-debug -o "$D/kernel/$k" "$O/$k"
  echo "kernel/$k" >> "$D/modules.order"
done < /log/targets.txt
cp $O/modules.builtin $O/modules.builtin.modinfo $D/
sha256sum $O/arch/arm64/boot/Image.gz > /log/image.after
cmp /log/image.before /log/image.after
cd /log && tar -C $STAGE --owner=0 --group=0 --numeric-owner --zstd -cf modules-$REL.tar.zst usr
rm -rf "$STAGE"
echo BUILD_DONE
'
cd "$S" && shasum -a 256 modules-$REL.tar.zst | tee SHA256SUMS
