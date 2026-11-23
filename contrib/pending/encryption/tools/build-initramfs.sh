#!/bin/zsh
# Build the LUKS-capable initramfs: base (v3, busybox/Alpine 3.22) + overlay = cryptsetup + aurora-sep token plugin + init.v4
# + m5-crypt.sh + apple-sep.ko (+ key store copies). Host-side wrapper; the compile runs in an Alpine 3.22 container
# (`container`, arm64, same musl as the base). It only writes under OUT's folder; it never touches the MacBook.
#   build-initramfs.sh --kbuild /Volumes/m5pro/bench/pr-verify/kbuild-xdr [--keystore DIR] [--test] [--out FILE]
# --kbuild: supplies apple-sep.ko and the release (modules-<release>.tar.zst); the initramfs is only good for that kernel.
# --keystore DIR: aurora-sep-keybag.bin, aurora-sep-refkey.bin [, aurora-sep-refkey-v2.bin] copied from the MacBook's
#   /var/lib by the orchestrator; ends up 0600 inside the (gzip, ESP-readable) initramfs. Omit = no SEP unlock, passphrase only.
# --test: plugin built with kernel "user" keys instead of the SEP (QEMU test only; refuses --keystore).
set -eu
HERE=${0:A:h}; SRC=${HERE:h}
BASE=/Volumes/m5pro/bench/fsck/initramfs-ftab-wdt2-fsck-v3.cpio.gz
SEPREPO=${SEPREPO:-/Volumes/m5pro/wt/encryption-src/sep}
KBUILD= KEYSTORE= TEST=prod OUT= EXTRA=
while [ $# -gt 0 ]; do case $1 in
  --kbuild) KBUILD=$2; shift 2;; --keystore) KEYSTORE=$2; shift 2;; --test) TEST=test; shift;; --out) OUT=$2; shift 2;;
  --base) BASE=$2; shift 2;; --extra-cpio) EXTRA=$2; shift 2;; *) echo "unknown $1"; exit 2;; esac; done
[ -z "$KEYSTORE" ] || [ $TEST = prod ] || { echo "--test never carries a key store"; exit 2; }
D=/Volumes/m5pro/bench/encryption/build; STAMP=$(date +%Y%m%d-%H%M%S); W=$D/$STAMP; mkdir -p $W/in
cp $SRC/initramfs/{init.v4,m5-crypt.sh,m5-unlock,m5-crypt.conf} $W/in/; cp $SRC/tools/in-container.sh $W/
gzip -dc $BASE | cpio -it 2>/dev/null | sed 's|^\./||' > $W/in/base.list
if [ -n "$KBUILD" ]; then
  REL=$(cat $KBUILD/kernel.release); zstd -dc $KBUILD/modules-$REL.tar.zst | tar -xOf - usr/lib/modules/$REL/kernel/drivers/soc/apple/apple-sep.ko > $W/in/apple-sep.ko
  echo $REL > $W/in/apple-sep.release
fi
[ -z "$KEYSTORE" ] || { mkdir -p $W/in/keystore; cp $KEYSTORE/aurora-sep-*.bin $W/in/keystore/; chmod 600 $W/in/keystore/*; }
container run --rm -m 6g -c 8 -v /Volumes/m5pro:/Volumes/m5pro alpine:3.22 sh $W/in-container.sh $W $SEPREPO $W/in $TEST 2>&1 | tail -n 25 || true
[ -s $W/overlay.cpio ] || { echo "overlay build failed, see $W"; exit 1; }
[ -n "$OUT" ] || OUT=$D/initramfs-crypt-${TEST}-${KBUILD:+${REL}-}$STAMP.cpio.gz
# one gzip member: v3's cpio stream (it is several archives concatenated) + the overlay as one more archive (later entries win, init included)
{ gzip -dc $BASE; cat $W/overlay.cpio; [ -z "$EXTRA" ] || cat $EXTRA; } | gzip -9 -n > $OUT
echo "initramfs: $OUT  $(wc -c < $OUT) bytes  sha256 $(shasum -a 256 $OUT | cut -d' ' -f1)"
cp $W/manifest.txt $OUT.manifest
