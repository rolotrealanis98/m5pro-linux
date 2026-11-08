#!/usr/bin/env bash
# avd-a kernel: branch j716s-avd-a (tip recorded in kbuild-avd/tip.txt) in the main repository /Volumes/linux-cs/linux
# = the daily j716s-video-observe (0933f881d736, kernel 7.3.0-g0933f881d736) + the AVD/JPEG series (SERIES.txt here):
# video 0001-0004 (T6050 AVD and JPEG bindings + drivers), 0009-0011 (J716s enables AVD, JPEG; j716s.config), plus the
# ADT/upstream annotation of the AVD node. Derived from ~/Work/agents/video-observe/build-kernel-video.sh (same Fedora 43
# container toolchain: clang 21, rustc 1.99.1, the aurora-bindgen of wt-daily-dcp), with one change of layout:
#   the sources come from `git archive` of the branch (kbuild-avd/src-<tip>.tar.zst, made on the host) and are built on the
#   container's OWN ext4 disk (/work, 504 GiB), not on a virtiofs share. The first attempt on /Volumes/linux-cs-gpurec took
#   that disk image down: each container kernel build on virtiofs holds 60-110k host file handles, three of them ran at once,
#   the host hit kern.maxfiles and the disk images behind the shares answered ENXIO (APFS tx_enter failed: 6). Only the small
#   results directory (kbuild-avd, on the Data volume) is shared now. No worktree is touched or needed.
# Config: the video-observe .config (kbuild-video/config = daily-dcp + CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y) unchanged:
# CONFIG_VIDEO_APPLE_AVD=m and CONFIG_VIDEO_APPLE_JPEG=m are already in it, so olddefconfig must change nothing (checked).
# Release: without .git, setlocalversion adds nothing, so LOCALVERSION=-g<tip> gives the daily's form 7.3.0-g<12 hex>.
# Modules tarball from the daily target list, which already carries apple-avd.ko and apple-jpeg.ko.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
REPO=/Volumes/linux-cs/linux
KV=$HOME/Work/agents/video-observe/kbuild-video
LOG=$S/kbuild-avd; mkdir -p "$LOG"; chmod 700 "$S" "$LOG"
free_k() { df -k "$1" | awk 'NR==2{print $4}'; }
[ "$(free_k "$LOG")" -ge 10485760 ] || { echo "less than 10 GiB free under $LOG, not building"; exit 1; }
TIP=$(git -C $REPO rev-parse --short=12 j716s-avd-a); echo "$TIP" > "$LOG/tip.txt"
git -C $REPO log --oneline -17 j716s-avd-a > "$LOG/series-log.txt"
SRC=$LOG/src-$TIP.tar.zst
[ -s "$SRC" ] || git -C $REPO archive --format=tar --prefix=src/ j716s-avd-a | zstd -T0 -3 -q -o "$SRC" -f
cp /Volumes/linux-cs/wt-daily-dcp/tools/aurora-bindgen/build/bin/bindgen "$LOG/bindgen"
cp "$KV/config" "$LOG/config.video-observe"
cp "$KV/targets-daily.txt" "$LOG/targets-daily.txt"
for k in CONFIG_VIDEO_APPLE_AVD=m CONFIG_VIDEO_APPLE_JPEG=m CONFIG_VIDEO_APPLE_AVE=m CONFIG_VIDEO_APPLE_PRORES=m CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y; do
  grep -qx "$k" "$LOG/config.video-observe" || { echo "video-observe config lacks $k"; exit 1; }; done
for k in avd/apple-avd.ko jpeg/apple-jpeg.ko ave/apple-ave.ko prores/apple-prores.ko; do
  grep -qx "drivers/media/platform/apple/$k" "$LOG/targets-daily.txt" || { echo "targets lack $k"; exit 1; }; done
container rm -f kavd >/dev/null 2>&1 || true
container run -d --name kavd -m 24g -c 8 -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kavd >/dev/null 2>&1 || true' EXIT
container exec kavd bash -c '
set -euo pipefail
ulimit -n 1048576 2>/dev/null || ulimit -n 524288 || true
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
mk() { local lg=$1 t; shift; : > "$lg"; for t in 1 2 3 4 5 6 7 8; do "$@" >> "$lg" 2>&1 && return 0; grep -qE "Too many open files|No such device or address|not all data was written" "$lg" || return 1; echo "ENFILE/ENXIO retry $t $(date -u +%H:%M:%S)" >> /log/retries.txt; sleep 60; done; return 1; }
TIP=$(cat /log/tip.txt)
mkdir -p /work && cd /work && df -h /work | tail -1 > /log/work-disk.txt
tar --use-compress-program=unzstd -xf /log/src-$TIP.tar.zst
cp /log/bindgen /work/bindgen && chmod +x /work/bindgen
export BINDGEN=/work/bindgen
O=/work/out; mkdir -p $O; cp /log/config.video-observe $O/.config
cd /work/src
{ cat /log/series-log.txt; clang --version | head -1; rustc --version; $BINDGEN --version; } > /log/toolchain.txt
M="make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=-g$TIP"
$M rustavailable > /log/rustavailable.txt 2>&1 || true
grep -q "Rust is available" /log/rustavailable.txt || { echo "rust not available"; exit 1; }
$M olddefconfig > /log/config.log 2>&1
cp $O/.config /log/config
diff <(grep -v "^#" /log/config.video-observe | grep .) <(grep -v "^#" /log/config | grep .) > /log/config.diff || true
if [ ! -s /log/config.diff ]; then echo "config = video-observe (daily-dcp + PRORES_T6050_OBSERVE), unchanged" >> /log/config.log; else echo "CONFIG DIFFERS from the video-observe config"; cat /log/config.diff; exit 1; fi
$M -s kernelrelease > /log/kernel.release.expected 2>/dev/null || true
[ "$(cat /log/kernel.release.expected)" = "7.3.0-g$TIP" ] || { echo "unexpected kernel release $(cat /log/kernel.release.expected), wanted 7.3.0-g$TIP"; exit 1; }
mk /log/build.log make -j8 LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=-g$TIP Image.gz apple/t6050-j716s.dtb || { echo "BUILD FAILED"; grep -m8 -B3 -A8 -E " error|^error" /log/build.log; exit 1; }
cat $O/include/config/kernel.release > /log/kernel.release
grep -c -i "warning" /log/build.log > /log/warnings.count || true
grep -E "drivers/media/platform/apple/(avd|jpeg)/|t6050-j716s|t6050-media|t6050-max" /log/build.log | grep -i -E "warn|error" > /log/patched-file-warnings.txt || true
grep -iE "dtc|\.dts" /log/build.log | grep -iE "warn" > /log/dtc-warnings.txt || true
cp $O/arch/arm64/boot/Image.gz /log/Image.gz
cp $O/arch/arm64/boot/dts/apple/t6050-j716s.dtb /log/t6050-j716s-avd-a.dtb
cp $O/System.map /log/System.map
REL=$(cat $O/include/config/kernel.release)
grep -vxF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets.txt || true
grep -xF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets-builtin.txt || true
sha256sum $O/arch/arm64/boot/Image.gz > /log/image.before
mk /log/modules-build.log make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=-g$TIP KBUILD_MODPOST_WARN=1 -j8 $(tr "\n" " " < /log/targets.txt) || { echo "MODULE BUILD FAILED"; grep -m8 -B3 -A6 -E " error|^error" /log/modules-build.log; exit 1; }
STAGE=/work/modstage-$REL
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
for k in avd/apple-avd.ko jpeg/apple-jpeg.ko ave/apple-ave.ko prores/apple-prores.ko; do
  [ -f "$D/kernel/drivers/media/platform/apple/$k" ] || { echo "$k missing from the stage"; exit 1; }; done
modinfo "$D/kernel/drivers/media/platform/apple/avd/apple-avd.ko" > /log/apple-avd.modinfo 2>&1 || true
modinfo "$D/kernel/drivers/media/platform/apple/jpeg/apple-jpeg.ko" > /log/apple-jpeg.modinfo 2>&1 || true
grep -q "apple,t6050-avd" /log/apple-avd.modinfo || { echo "apple-avd.ko has no apple,t6050-avd alias"; exit 1; }
grep -q "apple,t6050-jpeg" /log/apple-jpeg.modinfo || { echo "apple-jpeg.ko has no apple,t6050-jpeg alias"; exit 1; }
grep -q "apple/avd-fw-v5-t2.bin" /log/apple-avd.modinfo || { echo "apple-avd.ko does not name apple/avd-fw-v5-t2.bin"; exit 1; }
tar -C $STAGE --owner=0 --group=0 --numeric-owner --zstd -cf /log/modules-$REL.tar.zst usr
rm -rf "$STAGE"
cd /log && sha256sum Image.gz t6050-j716s-avd-a.dtb config System.map kernel.release modules-$REL.tar.zst | tee /log/SHA256SUMS
'
echo "container build finished"
# DTB checks on the host (dtc from Homebrew): decoder, its DART and both JPEG engines + DART enabled; AVE/ProRes as in the daily.
DTS=$LOG/t6050-j716s-avd-a.dts
dtc -I dtb -O dts -o "$DTS" "$LOG/t6050-j716s-avd-a.dtb" 2> "$LOG/dtc-host-warnings.txt" || true
{
  echo "dtc -I dtb -O dts warnings: $(wc -l < "$LOG/dtc-host-warnings.txt" | tr -d ' ')"
  echo "build-log dtc warnings: $(wc -l < "$LOG/dtc-warnings.txt" | tr -d ' ')"
  for c in apple,t6050-avd apple,t8142-avd apple,t6050-jpeg apple,t6050-prores apple,t6050-ave; do echo "compatible $c: $(grep -c "\"$c\"" "$DTS") occurrence(s)"; done
  for n in 'avd@2309080000' 'iommu@2309020000' 'jpeg@2281000000' 'jpeg@2281060000' 'iommu@2281020000' 'video-codec@2283100000' 'video-codec@48d000000'; do
    st=$(awk -v n="$n" '$0 ~ n" \\{" {f=1} f && /status =/ {print $3; exit} f && /^\t\};/ {print "(no status)"; exit}' "$DTS")
    echo "node $n: status ${st:-?}"
  done
} | tee "$LOG/dtb-checks.txt"
chmod 600 "$LOG"/modules-*.tar.zst "$LOG"/Image.gz 2>/dev/null || true
echo "warnings: $(cat "$LOG/warnings.count") (video-observe: $(cat "$KV/warnings.count"))"
cat "$LOG/kernel.release"
