#!/bin/sh
# SPDX-License-Identifier: MIT
# esp-put - put a payload on the ESP so that the restart after it is not a restart into a busy
# NVMe controller. Runs on the MacBook (Linux, root). Replaces "scp to boot.bin.new; mv; sync".
#
#   esp-put SRC NAME SHA256
#     SRC   the payload, already on the machine (scp it to /root first), or an ESP file
#           (e.g. /boot/m1n1/boot.bin to make it boot.bin.prev)
#     NAME  boot.bin | boot.bin.prev
#   env: ESP_RW=1 leaves /boot mounted read-write (default: read-only until the reboot)
#        ESP_SETTLE=<s> idle time after the last flush (default 60: a restart while the SSD is still busy gets counted or breaks the next boot)
#
# Why: on vfat, sync(2) writes the data but sends no device FLUSH (vfat has no ->sync_fs; the
# FAT and directory buffers go out in sync_bdevs, after every other filesystem's flush), so tens
# of MB plus the FAT/directory sectors can still sit in the controller's write cache when
# `systemctl reboot` follows a second later. fsync on a vfat file or directory does end in
# blkdev_issue_flush (fs/fat/file.c fat_file_fsync), and so does fsync on the block device.
set -eu
SRC=$1; NAME=$2; SHA=$3
DEV=/dev/nvme0n1p4; ESP=/boot; D=$ESP/m1n1

case "$NAME" in boot.bin|boot.bin.prev) ;; *) echo "esp-put: NAME must be boot.bin or boot.bin.prev"; exit 2;; esac

flush_dev() {
    python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)' "$DEV" \
        2>/dev/null && return 0
    nvme flush "${DEV%p4}" >/dev/null 2>&1 && return 0
    echo "esp-put: could not send a device flush (needs python3 or nvme-cli)" >&2
    return 1
}
unsafe() { nvme smart-log /dev/nvme0 2>/dev/null | awk -F: '/unsafe_shutdowns/{gsub(/[ ,]/,"",$2); print $2}'; }

mountpoint -q "$ESP" || mount "$DEV" "$ESP"
mount -o remount,rw "$ESP"
got=$(sha256sum "$SRC" | cut -d' ' -f1)
[ "$got" = "$SHA" ] || { echo "esp-put: $SRC is $got, expected $SHA: nothing written"; exit 1; }

rm -f "$D/$NAME.new"
cp "$SRC" "$D/$NAME.new"
sync "$D/$NAME.new"                     # fsync: data, FAT, then a device FLUSH
[ "$(sha256sum "$D/$NAME.new" | cut -d' ' -f1)" = "$SHA" ] || { rm -f "$D/$NAME.new"; echo "esp-put: copy mismatch"; exit 1; }
mv -f "$D/$NAME.new" "$D/$NAME"
sync "$D/$NAME" "$D"                    # fsync the file and the directory: entry, FAT, FLUSH

umount "$ESP"                           # FSInfo and the clean-state bit written, nothing dirty
flush_dev                               # FLUSH after the unmount's own writes
echo 3 > /proc/sys/vm/drop_caches
if [ "${ESP_RW:-0}" = 1 ]; then mount "$DEV" "$ESP"; else mount -o ro "$DEV" "$ESP"; fi
got=$(sha256sum "$D/$NAME" | cut -d' ' -f1)   # cold read through the block layer
[ "$got" = "$SHA" ] || { echo "esp-put: $NAME reads back as $got after the remount: do not reboot"; exit 1; }
sleep "${ESP_SETTLE:-60}"
echo "esp-put: $NAME = ${SHA%"${SHA#????????}"} flushed, remounted $( [ "${ESP_RW:-0}" = 1 ] && echo rw || echo ro ), unsafe_shutdowns=$(unsafe)"
