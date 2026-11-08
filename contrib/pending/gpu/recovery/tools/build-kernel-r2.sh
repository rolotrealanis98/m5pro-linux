#!/usr/bin/env bash
# daily-dcp-recovery2 kernel: worktree /Volumes/linux-cs-gpurec/wt-daily-dcp-recovery (branch j716s-daily-dcp-recovery2)
# = j716s-daily-dcp-recovery (ed7e1d0c42b0: bd53915f2ef1 + gpu/recovery 0001-0003) + the two fault-blame commits of
# j716s-daily-dcp-faults (gpu/faults 0001, 0002) cherry-picked. Adapted from build-kernel.sh: own container (kgpurec2), object
# dir (wt-daily-dcp-recovery2-out), results dir (kbuild-r2), free-space guards at 5 GiB on both volumes.
# Same toolchain as ../daily-dcp/build-kernel.sh (Fedora 43 container, clang 21, rustc 1.99.1, aurora-bindgen of
# wt-daily-dcp). Same config: the daily-dcp .config (kbuild/config.daily-dcp) + olddefconfig, checked identical.
# Objects on the separate sparse bundle vol/linux-cs-gpurec.sparsebundle (/Volumes/linux-cs keeps its free space).
# Results to ~/Work/agents/gpu-recovery/kbuild-r2; modules tarball from the daily target list (targets-daily.txt).
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
W=/Volumes/linux-cs-gpurec/wt-daily-dcp-recovery
O=/Volumes/linux-cs-gpurec/wt-daily-dcp-recovery2-out
LOG=$S/kbuild-r2; mkdir -p "$LOG" "$O"
[ "$(git -C $W rev-parse --abbrev-ref HEAD)" = j716s-daily-dcp-recovery2 ] || { echo "wrong branch in $W"; exit 1; }
[ -z "$(git -C $W status --porcelain)" ] || { echo "$W is dirty"; exit 1; }
cp "$LOG/config.daily-dcp" "$O/.config"
container rm -f kgpurec2 >/dev/null 2>&1 || true
container run -d --name kgpurec2 -m 16g -c 8 -v /Volumes/linux-cs:/Volumes/linux-cs -v /Volumes/linux-cs-gpurec:/Volumes/linux-cs-gpurec -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kgpurec2 >/dev/null 2>&1 || true' EXIT
container exec kgpurec2 bash -c '
set -euo pipefail
ulimit -n 1048576 2>/dev/null || ulimit -n 524288 || true
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
mk() { local lg=$1 t; shift; : > "$lg"; for t in 1 2 3 4 5 6 7 8; do "$@" >> "$lg" 2>&1 && return 0; grep -q "Too many open files" "$lg" || return 1; echo "ENFILE retry $t" >> /log/retries.txt; sleep 15; done; return 1; }
git config --global --add safe.directory "*"
O=/Volumes/linux-cs-gpurec/wt-daily-dcp-recovery2-out
cd /Volumes/linux-cs-gpurec/wt-daily-dcp-recovery
export BINDGEN=/Volumes/linux-cs/wt-daily-dcp/tools/aurora-bindgen/build/bin/bindgen
[ -x $BINDGEN ] || { echo "no bindgen at $BINDGEN"; exit 1; }
{ git log --oneline -4; clang --version | head -1; rustc --version; $BINDGEN --version; } > /log/toolchain.txt
( while sleep 10; do a=$(df -k "$O" | awk "NR==2{print \$4}"); b=$(df -k /Volumes/linux-cs | awk "NR==2{print \$4}"); if [ "$a" -lt 5242880 ] || [ "$b" -lt 5242880 ]; then echo "LOW DISK (out $a KiB, linux-cs $b KiB): killing make" >> /log/lowdisk.txt; pkill -f "make.*O=$O"; fi; done ) &
WD=$!
M="make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION="
$M rustavailable > /log/rustavailable.txt 2>&1 || true
grep -q "Rust is available" /log/rustavailable.txt || { echo "rust not available"; exit 1; }
$M olddefconfig > /log/config.log 2>&1
cp $O/.config /log/config
diff <(grep -v "^#" /log/config.daily-dcp | grep .) <(grep -v "^#" /log/config | grep .) > /log/config.diff && echo "config identical to daily-dcp" >> /log/config.log || { echo "CONFIG DIFFERS from daily-dcp"; cat /log/config.diff; exit 1; }
mk /log/build.log make -j8 LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION= Image.gz apple/t6050-j716s.dtb || { echo "BUILD FAILED"; grep -m8 -B3 -A8 -E " error|^error" /log/build.log; kill $WD; exit 1; }
cat $O/include/config/kernel.release > /log/kernel.release
grep -c -i "warning" /log/build.log > /log/warnings.count || true
grep -E "drivers/gpu/drm/(asahi|apple)/" /log/build.log | grep -i -E "warn|error" > /log/patched-file-warnings.txt || true
cp $O/arch/arm64/boot/Image.gz /log/Image.gz
cp $O/arch/arm64/boot/dts/apple/t6050-j716s.dtb /log/t6050-j716s-daily-dcp-recovery2.dtb
cp $O/System.map /log/System.map
REL=$(cat $O/include/config/kernel.release)
grep -vxF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets.txt || true
grep -xF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets-builtin.txt || true
sha256sum $O/arch/arm64/boot/Image.gz > /log/image.before
mk /log/modules-build.log make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION= KBUILD_MODPOST_WARN=1 -j8 $(tr "\n" " " < /log/targets.txt) || { echo "MODULE BUILD FAILED"; grep -m8 -B3 -A6 -E " error|^error" /log/modules-build.log; kill $WD; exit 1; }
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
tar -C $STAGE --owner=0 --group=0 --numeric-owner --zstd -cf /log/modules-$REL.tar.zst usr
rm -rf "$STAGE"
cd /log && sha256sum Image.gz t6050-j716s-daily-dcp-recovery2.dtb config System.map kernel.release modules-$REL.tar.zst | tee /log/SHA256SUMS
'
echo "container build finished"
