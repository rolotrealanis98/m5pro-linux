#!/bin/bash
# encryption-2 prep, on the J716s as root, NO reboot: create the scratch LUKS2 image the reboot test opens in the initramfs.
# Writes only /var/lib/m5-enc2/scratch.img (64 MiB, sparse) and the loop/dm devices it creates; the chroot lives in a private
# mount namespace with a private /dev (see m5-chroot.sh for the 2026-11-23 incident). Fixed, non-secret passphrase below.
# usage: sudo ./enc2-prep.sh /var/tmp/m5-enc1-in/chroot-v4.tar.gz
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/m5-chroot.sh"
m5_enter_ns bash "$0" "$@"
TAR=${1:?chroot tarball}; D=/var/lib/m5-enc2; IMG=$D/scratch.img; W=/var/tmp/m5-enc2-prep; R=$W/root; NAME=m5enc2
PASS=m5-enc2-passphrase; LOOP=
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
[ -e "$IMG" ] && { echo "$IMG exists; bash $HERE/safe-rm.sh $D first"; exit 2; }
cleanup() { umount "$W/fs" 2>/dev/null; cryptsetup close $NAME 2>/dev/null; [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
            m5_chroot_teardown "$R"; echo "remove the prep tree with: bash $HERE/safe-rm.sh $W"; }
trap cleanup EXIT
mkdir -p "$D" "$W" "$W/fs"; m5_safe_rm "$R" || exit 1; mkdir -p "$R"; tar -xzf "$TAR" -C "$R"
printf '%s' "$PASS" > "$W/pass"; chmod 600 "$W/pass"
m5_chroot_setup "$R" "$W"
inroot() { chroot "$R" /bin/busybox env PATH=/sbin:/usr/sbin:/bin:/usr/bin "$@"; }
truncate -s 64M "$IMG"; chmod 600 "$IMG"
LOOP=$(losetup --find --show "$IMG"); [ "$(losetup -nO BACK-FILE "$LOOP")" = "$IMG" ] || { echo "ABORT loop mismatch"; exit 3; }
cp -a "$LOOP" "$R/dev/"
inroot /sbin/cryptsetup luksFormat --type luks2 --batch-mode --pbkdf argon2id --pbkdf-memory 65536 --pbkdf-parallel 1 --iter-time 200 "$LOOP" /mnt/pass || exit 1
inroot /sbin/cryptsetup open "$LOOP" $NAME --key-file /mnt/pass || exit 1
mkfs.ext4 -q -L m5enc2 "$R/dev/mapper/$NAME" && mount "$R/dev/mapper/$NAME" "$W/fs" || exit 1
echo "m5-crypt-canary-enc2" > "$W/fs/canary"; umount "$W/fs"
inroot /sbin/cryptsetup close $NAME
PASSWORD=$PASS inroot /sbin/aurora-sep-cryptenroll "$LOOP" || exit 1
inroot /sbin/aurora-sep-cryptenroll --test "$LOOP" || exit 1
inroot /sbin/aurora-sep-cryptenroll --status "$LOOP"
sync; echo "enc2-prep OK: $IMG (keep it; the reboot test opens it)"
