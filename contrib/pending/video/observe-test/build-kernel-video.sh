#!/usr/bin/env bash
# video-observe kernel: worktree /Volumes/linux-cs-gpurec/wt-video-observe (branch j716s-video-observe)
# = the daily j716s-daily-dcp-recovery2 (12c445fa5371) + the video-observe series (SERIES.txt in this directory):
# video 0006, 0008; encode 0001, 0002; prores 0001, 0003, 0004, 0005 (prores 0002 dropped: 0008 already carries apr0/apr0_dart).
# Derived from ~/Work/agents/gpu-recovery/build-kernel-r2.sh: own container (kvideo), object dir (wt-video-observe-out on
# /Volumes/linux-cs-gpurec; nothing is written to /Volumes/linux-cs, which sits at its 15 GiB floor), results dir
# (kbuild-video), free-space guard at 5 GiB on the object volume (and on linux-cs, read-only here, as r2 did).
# Same toolchain (Fedora 43 container, clang 21.1.8, rustc 1.99.1, aurora-bindgen of wt-daily-dcp).
# Config: the daily-dcp .config (kbuild-r2/config.daily-dcp) + CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y, then olddefconfig;
# CONFIG_VIDEO_APPLE_AVE=m and CONFIG_VIDEO_APPLE_PRORES=m are already in the daily config (checked). The diff against the
# daily config must be exactly that one added line, else the build stops.
# Modules tarball from the daily target list (targets-daily.txt), which already carries apple-ave.ko and apple-prores.ko.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
W=/Volumes/linux-cs-gpurec/wt-video-observe
O=/Volumes/linux-cs-gpurec/wt-video-observe-out
R2=$HOME/Work/agents/gpu-recovery/kbuild-r2
LOG=$S/kbuild-video; mkdir -p "$LOG" "$O"; chmod 700 "$S" "$LOG"
[ "$(git -C $W rev-parse --abbrev-ref HEAD)" = j716s-video-observe ] || { echo "wrong branch in $W"; exit 1; }
[ -z "$(git -C $W status --porcelain)" ] || { echo "$W is dirty"; exit 1; }
free_k() { df -k "$1" | awk 'NR==2{print $4}'; }
[ "$(free_k /Volumes/linux-cs-gpurec)" -ge 5242880 ] || { echo "less than 5 GiB free on /Volumes/linux-cs-gpurec, not building"; exit 1; }
cp "$R2/config.daily-dcp" "$LOG/config.daily-dcp"
cp "$R2/targets-daily.txt" "$LOG/targets-daily.txt"
grep -qx 'CONFIG_VIDEO_APPLE_AVE=m' "$LOG/config.daily-dcp" || { echo "daily config lacks CONFIG_VIDEO_APPLE_AVE=m"; exit 1; }
grep -qx 'CONFIG_VIDEO_APPLE_PRORES=m' "$LOG/config.daily-dcp" || { echo "daily config lacks CONFIG_VIDEO_APPLE_PRORES=m"; exit 1; }
grep -q 'VIDEO_APPLE_PRORES_T6050_OBSERVE' "$LOG/config.daily-dcp" && { echo "daily config already mentions T6050_OBSERVE"; exit 1; }
grep -qx 'drivers/media/platform/apple/ave/apple-ave.ko' "$LOG/targets-daily.txt" || { echo "targets lack apple-ave.ko"; exit 1; }
grep -qx 'drivers/media/platform/apple/prores/apple-prores.ko' "$LOG/targets-daily.txt" || { echo "targets lack apple-prores.ko"; exit 1; }
{ cat "$LOG/config.daily-dcp"; echo "CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y"; } > "$LOG/config.video-observe.in"
cp "$LOG/config.video-observe.in" "$O/.config"
container rm -f kvideo >/dev/null 2>&1 || true
container run -d --name kvideo -m 16g -c 8 -v /Volumes/linux-cs:/Volumes/linux-cs -v /Volumes/linux-cs-gpurec:/Volumes/linux-cs-gpurec -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kvideo >/dev/null 2>&1 || true' EXIT
container exec kvideo bash -c '
set -euo pipefail
ulimit -n 1048576 2>/dev/null || ulimit -n 524288 || true
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
mk() { local lg=$1 t; shift; : > "$lg"; for t in 1 2 3 4 5 6 7 8; do "$@" >> "$lg" 2>&1 && return 0; grep -q "Too many open files" "$lg" || return 1; echo "ENFILE retry $t" >> /log/retries.txt; sleep 15; done; return 1; }
git config --global --add safe.directory "*"
O=/Volumes/linux-cs-gpurec/wt-video-observe-out
cd /Volumes/linux-cs-gpurec/wt-video-observe
export BINDGEN=/Volumes/linux-cs/wt-daily-dcp/tools/aurora-bindgen/build/bin/bindgen
[ -x $BINDGEN ] || { echo "no bindgen at $BINDGEN"; exit 1; }
{ git log --oneline -9; clang --version | head -1; rustc --version; $BINDGEN --version; } > /log/toolchain.txt
( while sleep 10; do a=$(df -k "$O" | awk "NR==2{print \$4}"); b=$(df -k /Volumes/linux-cs | awk "NR==2{print \$4}"); if [ "$a" -lt 5242880 ] || [ "$b" -lt 5242880 ]; then echo "LOW DISK (out $a KiB, linux-cs $b KiB): killing make" >> /log/lowdisk.txt; pkill -f "make.*O=$O"; fi; done ) &
WD=$!
M="make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION="
$M rustavailable > /log/rustavailable.txt 2>&1 || true
grep -q "Rust is available" /log/rustavailable.txt || { echo "rust not available"; exit 1; }
$M olddefconfig > /log/config.log 2>&1
cp $O/.config /log/config
diff <(grep -v "^#" /log/config.daily-dcp | grep .) <(grep -v "^#" /log/config | grep .) > /log/config.diff || true
if [ "$(grep -v "^[0-9]" /log/config.diff | tr -d "\n")" = "> CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y" ]; then echo "config = daily-dcp + CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y" >> /log/config.log; else echo "CONFIG DIFFERS from daily-dcp beyond the one expected line"; cat /log/config.diff; kill $WD; exit 1; fi
mk /log/build.log make -j8 LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION= Image.gz apple/t6050-j716s.dtb || { echo "BUILD FAILED"; grep -m8 -B3 -A8 -E " error|^error" /log/build.log; kill $WD; exit 1; }
cat $O/include/config/kernel.release > /log/kernel.release
grep -c -i "warning" /log/build.log > /log/warnings.count || true
grep -E "drivers/media/platform/apple/(ave|prores)/|t6050-j716s|t6050-media|t6050-max" /log/build.log | grep -i -E "warn|error" > /log/patched-file-warnings.txt || true
grep -iE "dtc|\.dts" /log/build.log | grep -iE "warn" > /log/dtc-warnings.txt || true
cp $O/arch/arm64/boot/Image.gz /log/Image.gz
cp $O/arch/arm64/boot/dts/apple/t6050-j716s.dtb /log/t6050-j716s-video-observe.dtb
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
[ -f "$D/kernel/drivers/media/platform/apple/ave/apple-ave.ko" ] || { echo "apple-ave.ko missing from the stage"; exit 1; }
[ -f "$D/kernel/drivers/media/platform/apple/prores/apple-prores.ko" ] || { echo "apple-prores.ko missing from the stage"; exit 1; }
modinfo "$D/kernel/drivers/media/platform/apple/prores/apple-prores.ko" > /log/apple-prores.modinfo 2>&1 || true
modinfo "$D/kernel/drivers/media/platform/apple/ave/apple-ave.ko" > /log/apple-ave.modinfo 2>&1 || true
tar -C $STAGE --owner=0 --group=0 --numeric-owner --zstd -cf /log/modules-$REL.tar.zst usr
rm -rf "$STAGE"
cd /log && sha256sum Image.gz t6050-j716s-video-observe.dtb config System.map kernel.release modules-$REL.tar.zst | tee /log/SHA256SUMS
'
echo "container build finished"
# DTB checks on the host (dtc from Homebrew): both T6050 video nodes present and enabled.
DTS=$LOG/t6050-j716s-video-observe.dts
dtc -I dtb -O dts -o "$DTS" "$LOG/t6050-j716s-video-observe.dtb" 2> "$LOG/dtc-host-warnings.txt" || true
{
  echo "dtc -I dtb -O dts warnings: $(wc -l < "$LOG/dtc-host-warnings.txt" | tr -d ' ')"
  echo "build-log dtc warnings: $(wc -l < "$LOG/dtc-warnings.txt" | tr -d ' ')"
  for c in apple,t6050-prores apple,t6050-ave apple,t6050-dart; do echo "compatible $c: $(grep -c "\"$c\"" "$DTS") occurrence(s)"; done
  for n in 'video-codec@48d000000' 'iommu@48d020000' 'video-codec@2283100000' 'iommu@22830a0000' 'iommu@2283080000'; do
    st=$(awk -v n="$n" '$0 ~ n" \\{" {f=1} f && /status =/ {print $3; exit} f && /^\t\};/ {print "(no status)"; exit}' "$DTS")
    echo "node $n: status ${st:-?}"
  done
  echo "chosen aurora,ave-*: $(grep -c 'aurora,ave-' "$DTS") (0 expected in the DTB; m1n1 adds them at boot)"
} | tee "$LOG/dtb-checks.txt"
chmod 600 "$LOG"/modules-*.tar.zst "$LOG"/Image.gz 2>/dev/null || true
echo "warnings: $(cat "$LOG/warnings.count") (daily r2: $(cat "$R2/warnings.count"))"
cat "$LOG/kernel.release"
