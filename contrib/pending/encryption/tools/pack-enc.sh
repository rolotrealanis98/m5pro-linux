#!/bin/zsh
# Build the v4 initramfs WITH the key store copies and pack a self-reverting test boot file (encryption-2 / -3). Studio only.
#   pack-enc.sh LABEL "<extra cmdline words>" [noselftest]      e.g. pack-enc.sh enc2 " m5.crypt_selftest=var/lib/m5-enc2/scratch.img m5.crypt_selftest_prompt=1"
# Needs /Volumes/m5pro/bench/encryption/keystore/{aurora-sep-keybag.bin,aurora-sep-refkey.bin[,aurora-sep-refkey-v2.bin]}
# (copied by the orchestrator from the Mac's /var/lib; mode 600; never committed). Writes under bench/ only.
# NEXT_M1N1 (the daily's current loader) is passed through if set in the environment, exactly as for other requests.
set -eu
LABEL=${1:?label}; EXTRA=${2:-}; NOSELF=${3:-}
HERE=${0:A:h}; B=/Volumes/m5pro/bench/encryption; KS=$B/keystore; KB=/Volumes/m5pro/bench/pr-verify/kbuild-xdr
[ -s $KS/aurora-sep-keybag.bin ] && [ -s $KS/aurora-sep-refkey.bin ] || { echo "missing key store copies in $KS"; exit 1; }
REL=$(cat $KB/kernel.release)
IR=$B/initramfs-ftab-wdt2-fsck-v4-crypt-$LABEL-$(date +%Y%m%d-%H%M%S).cpio.gz     # "fsck-v" in the name: mk-next-test's NEXT_ROOT check
$HERE/build-initramfs.sh --kbuild $KB --keystore $KS --out $IR | tail -n 2
cd ~/Documents/GitHub/m5pro/m5pro-linux-re/tooling/pr-verify
env KBUILD=kbuild-xdr NEXT_LABEL=$LABEL NEXT_IR=$IR NEXT_EXTRA="$EXTRA" ${NOSELF:+NEXT_NOSELFTEST=1} python3 -I -B mk-next-test.py
echo "initramfs $IR  (kernel $REL; the module only loads into exactly that release)"
