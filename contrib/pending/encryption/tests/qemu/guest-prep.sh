#!/bin/sh
# QEMU guest driver (rdinit=/qemu-guest), test builds only. qt.mode=prep: build the test disks, then power off.
# qt.mode=boot: load the modules and hand over to the real /init (init.v4) with the SEP faked by the user-key plugin.
BB=/bin/busybox
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys; $BB mount -t devtmpfs devtmpfs /dev
$BB mkdir -p /run /tmp
for m in $($BB cat /lib/modules/qemu/load-order.txt); do $BB insmod /lib/modules/qemu/$m 2>/dev/null || echo "qemu-guest: insmod $m failed"; done
# virtio disks are named in probe order, which varies: find them by serial (-device ...,serial=qcrypt|qplain)
i=0; while [ $i -lt 100 ] && [ ! -b /dev/qcrypt -o ! -b /dev/qplain -o ! -b /dev/qesp ]; do
    for b in /sys/block/vd*; do [ -e $b/serial ] && $BB ln -sf /dev/${b##*/} /dev/$($BB cat $b/serial); done
    $BB sleep 0.1; i=$((i+1)); done
MODE=$($BB sed -n 's/.*qt\.mode=\([^ ]*\).*/\1/p' /proc/cmdline)
PASS=qemu-test-passphrase
mkroot() {   # mkroot DEVICE: ext4 with a tiny userspace whose /sbin/init reports and powers off
    $BB mkdir -p /tmp/r; $BB mount -t ext4 $1 /tmp/r || return 1
    $BB mkdir -p /tmp/r/sbin /tmp/r/bin /tmp/r/proc /tmp/r/sys /tmp/r/dev /tmp/r/var/log
    $BB cp /bin/busybox.static /tmp/r/bin/busybox; $BB cp /qemu-root-init /tmp/r/sbin/init; $BB chmod 755 /tmp/r/sbin/init
    echo "m5-crypt-canary-$2" > /tmp/r/canary
    $BB umount /tmp/r
}
if [ "$MODE" = prep ]; then
    echo "qemu-guest: prep"
    # vdb: LUKS2 root (passphrase + aurora-sep token)
    echo -n $PASS | /sbin/cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/qcrypt - || echo "PREP-FAIL luksFormat"
    echo -n $PASS | /sbin/cryptsetup open /dev/qcrypt prep - || echo "PREP-FAIL open"
    /sbin/mke2fs -q -t ext4 -L qcrypt /dev/mapper/prep && mkroot /dev/mapper/prep crypt-root
    /sbin/cryptsetup close prep
    PASSWORD=$PASS /sbin/aurora-sep-cryptenroll /dev/qcrypt || echo "PREP-FAIL enrol"
    /sbin/aurora-sep-cryptenroll --status /dev/qcrypt
    # vdc: plain ext4 root that carries a scratch LUKS2 image file (selftest mode) and a plain control
    /sbin/mke2fs -q -t ext4 -L qplain /dev/qplain && mkroot /dev/qplain plain-root
    $BB mount -t ext4 /dev/qplain /tmp/r; $BB dd if=/dev/zero of=/tmp/r/scratch.img bs=1M count=32 2>/dev/null; $BB umount /tmp/r
    $BB mount -t ext4 /dev/qplain /tmp/r
    echo -n $PASS | /sbin/cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /tmp/r/scratch.img - || echo "PREP-FAIL scratch format"
    echo -n $PASS | /sbin/cryptsetup open /tmp/r/scratch.img prep2 - || echo "PREP-FAIL scratch open"
    /sbin/mke2fs -q -t ext4 /dev/mapper/prep2; $BB mkdir -p /tmp/s; $BB mount -t ext4 /dev/mapper/prep2 /tmp/s; echo "m5-crypt-canary-scratch" > /tmp/s/canary; $BB umount /tmp/s
    /sbin/cryptsetup close prep2
    PASSWORD=$PASS /sbin/aurora-sep-cryptenroll /tmp/r/scratch.img || echo "PREP-FAIL scratch enrol"
    # rootfile.img: LUKS2 file holding a tiny system with /outer (root-in-a-file rehearsal)
    $BB dd if=/dev/zero of=/tmp/r/rootfile.img bs=1M count=48 2>/dev/null
    echo -n $PASS | /sbin/cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 /tmp/r/rootfile.img - || echo "PREP-FAIL rootfile format"
    echo -n $PASS | /sbin/cryptsetup open /tmp/r/rootfile.img prep3 - || echo "PREP-FAIL rootfile open"
    /sbin/mke2fs -q -t ext4 /dev/mapper/prep3 && mkroot /dev/mapper/prep3 rootfile-root && { $BB mount -t ext4 /dev/mapper/prep3 /tmp/s && $BB mkdir -p /tmp/s/outer && $BB umount /tmp/s; }
    /sbin/cryptsetup close prep3
    PASSWORD=$PASS /sbin/aurora-sep-cryptenroll /tmp/r/rootfile.img || echo "PREP-FAIL rootfile enrol"
    $BB umount /tmp/r; $BB sync
    # qesp: a FAT "ESP" with m5sep/ key store copies (T10: init must prefer them over the embedded ones)
    if [ -b /dev/qesp ]; then $BB mkfs.vfat /dev/qesp >/dev/null 2>&1; $BB mkdir -p /tmp/e; $BB mount -t vfat /dev/qesp /tmp/e && $BB mkdir -p /tmp/e/m5sep \
        && echo esp-keybag > /tmp/e/m5sep/aurora-sep-keybag.bin && echo esp-refkey > /tmp/e/m5sep/aurora-sep-refkey.bin; $BB umount /tmp/e; fi
    echo "PREP-DONE"; $BB poweroff -f
fi
export M5C_SEP_FAKE=1
exec /init
