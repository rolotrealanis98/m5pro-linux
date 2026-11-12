#!/usr/bin/env bash
# uinput kernel: worktree /Volumes/linux-cs-uinput/wt-uinput (branch j716s-uinput)
# = the daily's kernel j716s-video-observe (0933f881d736) + one commit that adds CONFIG_INPUT_UINPUT=y and
# CONFIG_UHID=y to arch/arm64/configs/j716s.config (issue #4: /dev/uinput and /dev/uhid).
# Derived from contrib/pending/video/observe-test/build-kernel-video.sh: own container (kuinput), own volume
# (linux-cs-uinput: worktree and object dir; /Volumes/linux-cs is only read, for the git objects and bindgen),
# results dir kbuild-uinput, free-space guard at 5 GiB.
# Same toolchain (Fedora 43 container, clang 21.1.8, rustc 1.99.1, aurora-bindgen of wt-daily-dcp).
# Config: the daily's .config (video-observe/kbuild-video/config) with the SYMS "is not set" lines replaced and the SUBS added, then
# olddefconfig. The diff against the daily config must be exactly those symbols, else the build stops.
# No source or DT change: the DTB must come out identical to the daily's (4a8cfe25), checked at the end.
# Modules tarball from the daily target list (targets-daily.txt).
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
W=/Volumes/linux-cs-uinput/wt-uinput
O=/Volumes/linux-cs-uinput/wt-uinput-out
KV=$HOME/Work/agents/video-observe/kbuild-video
LOG=$S/kbuild-uinput; mkdir -p "$LOG" "$O"; chmod 700 "$S" "$LOG"
[ "$(git -C $W rev-parse --abbrev-ref HEAD)" = j716s-uinput ] || { echo "wrong branch in $W"; exit 1; }
[ -z "$(git -C $W status --porcelain)" ] || { echo "$W is dirty"; exit 1; }
free_k() { df -k "$1" | awk 'NR==2{print $4}'; }
[ "$(free_k /Volumes/linux-cs-uinput)" -ge 5242880 ] || { echo "less than 5 GiB free on /Volumes/linux-cs-uinput, not building"; exit 1; }
cp "$KV/config" "$LOG/config.daily"
cp "$KV/targets-daily.txt" "$LOG/targets-daily.txt"
[ "$(shasum -a 256 "$LOG/config.daily" | cut -d' ' -f1)" = 74573d9b809bfd5f0805363bfea3eb3c2d26d59832264a36edbc307ccdad56c3 ] || { echo "daily config is not 74573d9b"; exit 1; }
SYMS="INPUT_UINPUT UHID"            # "is not set" in the daily config, =y here
SUBS=""   # their sub-options, absent from the daily config
cp "$LOG/config.daily" "$LOG/config.uinput.in"
for s in $SYMS; do
  grep -qx "# CONFIG_$s is not set" "$LOG/config.daily" || { echo "daily config: $s is not 'not set'"; exit 1; }
  sed -i '' "s/^# CONFIG_$s is not set\$/CONFIG_$s=y/" "$LOG/config.uinput.in"
done
for s in $SUBS; do
  grep -q "CONFIG_$s[ =]" "$LOG/config.daily" && { echo "daily config already mentions $s"; exit 1; }
  echo "CONFIG_$s=y" >> "$LOG/config.uinput.in"
done
for s in $SYMS $SUBS; do echo "> CONFIG_$s=y"; done | LC_ALL=C sort > "$LOG/config.diff.expected"
cp "$LOG/config.uinput.in" "$O/.config"
container rm -f kuinput >/dev/null 2>&1 || true
container run -d --name kuinput -m 16g -c 8 -v /Volumes/linux-cs:/Volumes/linux-cs -v /Volumes/linux-cs-uinput:/Volumes/linux-cs-uinput -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kuinput >/dev/null 2>&1 || true' EXIT
container exec kuinput bash -c '
set -euo pipefail
ulimit -n 1048576 2>/dev/null || ulimit -n 524288 || true
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
mk() { local lg=$1 t; shift; : > "$lg"; for t in 1 2 3 4 5 6 7 8; do "$@" >> "$lg" 2>&1 && return 0; grep -q "Too many open files" "$lg" || return 1; echo "ENFILE retry $t" >> /log/retries.txt; sleep 15; done; return 1; }
git config --global --add safe.directory "*"
O=/Volumes/linux-cs-uinput/wt-uinput-out
cd /Volumes/linux-cs-uinput/wt-uinput
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
diff <(grep -v "^#" /log/config.daily | grep .) <(grep -v "^#" /log/config | grep .) > /log/config.diff || true
if grep -v "^[0-9]" /log/config.diff | LC_ALL=C sort | cmp -s - /log/config.diff.expected; then echo "config = daily + $(sed "s/^> CONFIG_//" /log/config.diff.expected | tr "\n" " ")" >> /log/config.log; else echo "CONFIG DIFFERS from the daily beyond the expected lines"; grep -v "^[0-9]" /log/config.diff | LC_ALL=C sort | diff - /log/config.diff.expected; kill $WD; exit 1; fi
mk /log/build.log make -j8 LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION= Image.gz apple/t6050-j716s.dtb || { echo "BUILD FAILED"; grep -m8 -B3 -A8 -E " error|^error" /log/build.log; kill $WD; exit 1; }
cat $O/include/config/kernel.release > /log/kernel.release
grep -c -i "warning" /log/build.log > /log/warnings.count || true
grep -E "drivers/input/misc/uinput|drivers/hid/uhid|t6050-j716s" /log/build.log | grep -i -E "warn|error" > /log/patched-file-warnings.txt || true
grep -iE "dtc|\.dts" /log/build.log | grep -iE "warn" > /log/dtc-warnings.txt || true
cp $O/arch/arm64/boot/Image.gz /log/Image.gz
cp $O/arch/arm64/boot/dts/apple/t6050-j716s.dtb /log/t6050-j716s-uinput.dtb
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
tar -C $STAGE --owner=0 --group=0 --numeric-owner --zstd -cf /log/modules-$REL.tar.zst usr
rm -rf "$STAGE"
cd /log && sha256sum Image.gz t6050-j716s-uinput.dtb config System.map kernel.release modules-$REL.tar.zst | tee /log/SHA256SUMS
'
echo "container build finished"
# Host checks: both drivers are built in, the DTB is the daily's.
{
  for m in drivers/input/misc/uinput.ko drivers/hid/uhid.ko; do
    grep -qx "kernel/$m" "$O/modules.builtin" && echo "builtin: $m" || { echo "NOT builtin: $m"; exit 1; }
  done
  echo "System.map uinput/uhid symbols: $(grep -c -E " (uinput_|uhid_)" "$LOG/System.map")"
  d=$(shasum -a 256 "$LOG/t6050-j716s-uinput.dtb" | cut -d' ' -f1)
  [ "$d" = 4a8cfe25f33d24df351c42d3c4e1d883aed7585da895d63de1ff22ce36613a77 ] && echo "dtb: identical to the daily's (4a8cfe25)" || echo "dtb: DIFFERS from the daily's 4a8cfe25: $d"
} | tee "$LOG/checks.txt"
chmod 600 "$LOG"/modules-*.tar.zst "$LOG"/Image.gz 2>/dev/null || true
echo "warnings: $(cat "$LOG/warnings.count") (daily: $(cat "$KV/warnings.count" 2>/dev/null || echo ?))"
cat "$LOG/kernel.release"
