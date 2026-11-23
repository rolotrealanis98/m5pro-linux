#!/bin/bash
# encryption-3 prep, on the J716s as root, NO reboot: copy the running root into a LUKS2 image FILE (root-in-a-file rehearsal).
# Writes only /var/lib/m5-enc3/root.img (+ loop/dm devices of its own). Reads / (read-only rsync, one file system).
# Refuses unless free space on / covers the used size + 10% + 2 GiB. Chroot in a private mount namespace, private /dev
# (m5-chroot.sh; see the 2026-11-23 incident note there). Fixed non-secret passphrase: m5-enc3-passphrase.
# usage: sudo ./enc3-prep.sh /var/tmp/m5-enc1-in/chroot-v4.tar.gz
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/m5-chroot.sh"
m5_enter_ns bash "$0" "$@"
TAR=${1:?chroot tarball}; D=/var/lib/m5-enc3; IMG=$D/root.img; W=/var/tmp/m5-enc3-prep; R=$W/root; NAME=m5enc3
PASS=m5-enc3-passphrase; LOOP=
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
[ -e "$IMG" ] && { echo "$IMG exists; bash $HERE/safe-rm.sh $D first"; exit 2; }
command -v rsync >/dev/null || { echo "rsync is required"; exit 2; }
USED=$(df -B1 --output=used / | tail -n 1 | tr -d ' '); FREE=$(df -B1 --output=avail / | tail -n 1 | tr -d ' ')
NEED=$(( USED + USED / 10 + 2*1024*1024*1024 )); SIZE=$(( NEED + 512*1024*1024 ))
echo "root used $((USED>>30)) GiB, free $((FREE>>30)) GiB, image $((SIZE>>30)) GiB"
[ "$FREE" -gt $(( SIZE + 4*1024*1024*1024 )) ] || { echo "not enough free space for the rehearsal image (+4 GiB reserve); stop"; exit 2; }
cleanup() { umount "$W/inner" 2>/dev/null; cryptsetup close $NAME 2>/dev/null; [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
            m5_chroot_teardown "$R"; echo "remove the prep tree with: bash $HERE/safe-rm.sh $W"; }
trap cleanup EXIT
mkdir -p "$D" "$W/inner"; m5_safe_rm "$R" || exit 1; mkdir -p "$R"; tar -xzf "$TAR" -C "$R"
printf '%s' "$PASS" > "$W/pass"; chmod 600 "$W/pass"
m5_chroot_setup "$R" "$W"
inroot() { chroot "$R" /bin/busybox env PATH=/sbin:/usr/sbin:/bin:/usr/bin "$@"; }
truncate -s "$SIZE" "$IMG"; chmod 600 "$IMG"
LOOP=$(losetup --find --show "$IMG"); [ "$(losetup -nO BACK-FILE "$LOOP")" = "$IMG" ] || { echo "ABORT loop mismatch"; exit 3; }
cp -a "$LOOP" "$R/dev/"
inroot /sbin/cryptsetup luksFormat --type luks2 --batch-mode --pbkdf argon2id --pbkdf-memory 65536 --pbkdf-parallel 1 --iter-time 200 "$LOOP" /mnt/pass || exit 1
inroot /sbin/cryptsetup open "$LOOP" $NAME --key-file /mnt/pass || exit 1
mkfs.ext4 -q -L m5enc3 "$R/dev/mapper/$NAME" && mount "$R/dev/mapper/$NAME" "$W/inner" || exit 1
echo "copying / (this takes a while)"
rsync -aHAXx --numeric-ids --info=stats1 --exclude=/var/lib/m5-enc*/ --exclude=/var/tmp/m5-*/ --exclude=/var/cache/pacman/pkg/ \
      --exclude=/proc/ --exclude=/sys/ --exclude=/dev/ --exclude=/run/ --exclude=/tmp/ / "$W/inner/" ; rc=$?
[ $rc = 0 ] || [ $rc = 24 ] || { echo "rsync failed rc=$rc"; exit 1; }
# the booted copy needs its own self-revert unit + script and a watchdog hand-over (init only writes them into the plain root)
for f in usr/local/sbin/m5-selftest etc/systemd/system/m5-selftest.service; do
    [ -e "$W/inner/$f" ] || { echo "ABORT: /$f missing in the copy: boot one ordinary m5.selftest=1 test payload first (init installs it), then rerun"; exit 1; }
done
mkdir -p "$W/inner/etc/systemd/system.conf.d"
[ -e "$W/inner/etc/systemd/system.conf.d/m5pro-watchdog.conf" ] || printf '[Manager]\nRuntimeWatchdogSec=60\nRebootWatchdogSec=5min\n' > "$W/inner/etc/systemd/system.conf.d/m5pro-watchdog.conf"
ln -sf /etc/systemd/system/m5-selftest.service "$W/inner/etc/systemd/system/multi-user.target.wants/m5-selftest.service"
[ -x "$W/inner/usr/local/lib/m5pro/touchid-up" ] && grep -q complete_attach "$W/inner/usr/local/lib/m5pro/touchid-up" || echo "WARNING: the copy has the old touchid-up (no complete_attach): install touchid-up.v2 on the live root first or Touch ID stays off in the rehearsal"
mkdir -p "$W/inner"/{outer,proc,sys,dev,run,tmp}; chmod 1777 "$W/inner/tmp"
df -h "$W/inner" | tail -n 1; umount "$W/inner"
inroot /sbin/cryptsetup close $NAME
PASSWORD=$PASS inroot /sbin/aurora-sep-cryptenroll "$LOOP" || exit 1
inroot /sbin/aurora-sep-cryptenroll --test "$LOOP" || exit 1
sync; echo "enc3-prep OK: $IMG"
