#!/usr/bin/env bash
# daily-dcp CAPTURE kernel: copy of ~/Work/agents/daily-dcp/build-kernel.sh with these changes only:
# - worktree /Volumes/linux-cs-capture/wt-daily-dcp-capture (branch j716s-daily-dcp-capture = j716s-daily-dcp bd53915f2ef1
#   + one commit adding arch/arm64/configs/j716s-capture.config: CONFIG_DRM_ASAHI=m), objects in
#   /Volumes/linux-cs-capture/wt-daily-dcp-capture-out. /Volumes/linux-cs-capture is a case-sensitive APFS sparse bundle on
#   the internal disk (~/Work/agents/daily-dcp/capture-vol/), because /Volumes/linux-cs must keep >= 15 GB free.
# - configs: the daily-dcp list + j716s-capture.config; checks DRM_ASAHI=m (the rest as before); diffconfig vs daily-dcp.
# - container kdailydcpcap (not kdailydcp), both volumes mounted; bindgen reused from the wt-daily-dcp tree (read only).
# - module list: the daily's 128 targets + drivers/gpu/drm/asahi/aurora.ko; unresolved aurora symbols fail the build.
# - a guard kills make if /Volumes/linux-cs drops below 15 GiB free.
# No LOCALVERSION: release 7.3.0-g<capture tip>. Results to ~/Work/agents/daily-dcp/capture/kbuild.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
CONFIGS=${CONFIGS:-"defconfig asahi.config j716s.config j716s-gpu.config j716s-dcp.config j716s-dcp-trace.config j716s-capture.config"}
LV=${LV:-}
W=/Volumes/linux-cs-capture/wt-daily-dcp-capture
O=/Volumes/linux-cs-capture/wt-daily-dcp-capture-out
LOG=$S/kbuild; mkdir -p "$LOG" "$O"
cp ~/Documents/GitHub/m5pro-linux/contrib/pending/dcp/aurora/j716s-dcp.config $W/arch/arm64/configs/j716s-dcp.config
cp ~/Work/agents/daily-dcp/j716s-dcp-trace.config $W/arch/arm64/configs/j716s-dcp-trace.config
container rm -f kdailydcpcap >/dev/null 2>&1 || true
container run -d --name kdailydcpcap -m 24g -c 12 -v /Volumes/linux-cs:/Volumes/linux-cs -v /Volumes/linux-cs-capture:/Volumes/linux-cs-capture -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kdailydcpcap >/dev/null 2>&1 || true; rm -f $W/arch/arm64/configs/j716s-dcp.config $W/arch/arm64/configs/j716s-dcp-trace.config' EXIT
container exec -e CONFIGS="$CONFIGS" -e LV="$LV" kdailydcpcap bash -c '
set -euo pipefail
echo "file-max before: $(cat /proc/sys/fs/file-max) nr_open: $(cat /proc/sys/fs/nr_open)" > /log/filemax.txt; sysctl -w fs.file-max=8388608 >> /log/filemax.txt 2>&1 || true; sysctl -w fs.nr_open=4194304 >> /log/filemax.txt 2>&1 || true; ulimit -n 1048576 2>>/log/filemax.txt || ulimit -n 524288 || true
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
# ENFILE ("Too many open files in system") from the Studio: make is incremental, rerun (up to 8 times) when the log shows only that
mk() { local lg=$1 t; shift; : > "$lg"; for t in 1 2 3 4 5 6 7 8; do "$@" >> "$lg" 2>&1 && return 0; grep -q "Too many open files" "$lg" || return 1; echo "ENFILE retry $t" >> /log/retries.txt; sleep 15; done; return 1; }
git config --global --add safe.directory "*"
O=/Volumes/linux-cs-capture/wt-daily-dcp-capture-out
cd /Volumes/linux-cs-capture/wt-daily-dcp-capture
export BINDGEN=/Volumes/linux-cs/wt-daily-dcp/tools/aurora-bindgen/build/bin/bindgen
[ -x $BINDGEN ] || { echo "bindgen missing"; exit 1; }
{ git log --oneline -1; clang --version | head -1; rustc --version; $BINDGEN --version; echo "configs: $CONFIGS"; } > /log/toolchain.txt
( while sleep 10; do a=$(df -k "$O" | awk "NR==2{print \$4}"); b=$(df -k /Volumes/linux-cs | awk "NR==2{print \$4}"); if [ "$a" -lt 786432 ] || [ "$b" -lt 15728640 ]; then echo "LOW DISK (out $a KiB, linux-cs $b KiB): killing make" >> /log/lowdisk.txt; pkill -f "make.*O=$O"; fi; done ) &
WD=$!
make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN rustavailable > /log/rustavailable.txt 2>&1 || true
cat /log/rustavailable.txt >> /log/toolchain.txt
grep -q "Rust is available" /log/rustavailable.txt || { echo "rust not available"; exit 1; }
make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=$LV $CONFIGS > /log/config.log 2>&1
cp $O/.config /log/config
for c in FTRACE TRACING EVENT_TRACING TRACEPOINTS DRM_APPLE; do grep -q "^CONFIG_$c=y" $O/.config || { echo "CONFIG_$c is not =y in the resulting .config"; exit 1; }; done
grep -q "^CONFIG_DRM_ASAHI=m" $O/.config || { echo "CONFIG_DRM_ASAHI is not =m"; exit 1; }
grep -E "^CONFIG_(RUST|DRM_ASAHI|DRM_APPLE|APPLE_PMP|MTD_PHRAM|APPLE_MAILBOX|FTRACE|TRACING|EVENT_TRACING|TRACEPOINTS|DEBUG_FS|FUNCTION_TRACER|DYNAMIC_DEBUG|LOCALVERSION)=|^# CONFIG_(APPLE_PMP|DRM_APPLE|DRM_ASAHI_M5) is not set" $O/.config > /log/config-key.txt || true
scripts/diffconfig /Volumes/linux-cs/wt-series-out/.config $O/.config > /log/diffconfig-vs-daily.txt || true
scripts/diffconfig /log/config-daily-dcp $O/.config > /log/diffconfig-vs-daily-dcp.txt || true
mk /log/build.log make -j8 LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=$LV Image.gz apple/t6050-j716s.dtb || { echo "BUILD FAILED"; grep -m8 -B3 -A8 -E " error|^error" /log/build.log; kill $WD; exit 1; }
cat $O/include/config/kernel.release > /log/kernel.release
grep -c -i "warning" /log/build.log > /log/warnings.count || true
cp $O/arch/arm64/boot/Image.gz /log/Image.gz
cp $O/arch/arm64/boot/dts/apple/t6050-j716s.dtb /log/t6050-j716s-daily-dcp.dtb
cp $O/System.map /log/System.map
REL=$(cat $O/include/config/kernel.release)
grep -vxF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets.txt || true
grep -xF -f <(sed "s|^kernel/||" $O/modules.builtin) /log/targets-daily.txt > /log/targets-builtin.txt || true
sha256sum $O/arch/arm64/boot/Image.gz > /log/image.before
mk /log/modules-build.log make LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION=$LV KBUILD_MODPOST_WARN=1 -j8 $(tr "\n" " " < /log/targets.txt) || { echo "MODULE BUILD FAILED"; grep -m8 -B3 -A6 -E " error|^error" /log/modules-build.log; kill $WD; exit 1; }
kill $WD
if grep -E "undefined!" /log/modules-build.log | grep -q "asahi/aurora"; then echo "aurora.ko has unresolved symbols:"; grep -E "undefined!" /log/modules-build.log | grep "asahi/aurora"; exit 1; fi
grep -E "undefined!" /log/modules-build.log > /log/modpost-undefined.txt || true
[ -f $O/drivers/gpu/drm/asahi/aurora.ko ] || { echo "aurora.ko not built"; exit 1; }
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
depmod -b $STAGE/usr -n $REL > /log/depmod-check.txt 2> /log/depmod-errors.txt || true
modinfo -F alias $D/kernel/drivers/gpu/drm/asahi/aurora.ko > /log/aurora-aliases.txt || true
modinfo -F depends $D/kernel/drivers/gpu/drm/asahi/aurora.ko > /log/aurora-depends.txt || true
sha256sum $O/arch/arm64/boot/Image.gz > /log/image.after
cmp /log/image.before /log/image.after
tar -C $STAGE --owner=0 --group=0 --numeric-owner --zstd -cf /log/modules-$REL.tar.zst usr
rm -rf "$STAGE"
cd /log && sha256sum Image.gz t6050-j716s-daily-dcp.dtb config System.map kernel.release modules-$REL.tar.zst | tee /log/SHA256SUMS
'
echo "container build finished"
