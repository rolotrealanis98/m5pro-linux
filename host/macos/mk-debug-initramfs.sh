#!/usr/bin/env bash
# mk-debug-initramfs.sh - make the omarchy-m5 bring-up initramfs debuggable.
#
# Appends an overlay cpio to an existing initramfs (the kernel unpacks
# concatenated archives; later entries win) that:
#   * replaces /init: waits up to 60 s (not 10 s) for m5.root, and keeps the
#     USB gadget network + an SSH server (dropbear, Alpine package) running
#     while it waits, so a boot whose root never appears can still be read
#     with `eem-vm.py --keep 'dmesg'` instead of a photo of the panel;
#   * ships dropbear + its libs from the Alpine 3.21 aarch64 repository
#     (the base initramfs is the Alpine minirootfs already);
#   * authorizes ~/.ssh/mbp.pub for root and unlocks the root account in
#     /etc/shadow (dropbear refuses locked accounts even for key auth).
#
# Nothing here changes what happens on a successful boot: dropbear is killed
# right before switch_root, exactly where the old init handed over.
#
# Usage: mk-debug-initramfs.sh [--base IN.cpio.gz] [--out OUT.cpio.gz]
#                              [--pubkey ~/.ssh/mbp.pub] [--cache DIR] [--wait SECONDS]
set -euo pipefail

BASE=$HOME/Work/omarchy-m5/build/initramfs-tp.cpio.gz
OUT=$HOME/Work/omarchy-m5/build/initramfs-debug.cpio.gz
PUBKEY=$HOME/.ssh/mbp.pub
CACHE=$HOME/Work/omarchy-m5/build/cache/apk-debug
WAIT=60
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --pubkey) PUBKEY=$2; shift 2 ;;
        --cache) CACHE=$2; shift 2 ;;
        --wait) WAIT=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -f "$BASE" ] || { echo "base initramfs missing: $BASE" >&2; exit 1; }
[ -f "$PUBKEY" ] || { echo "pubkey missing: $PUBKEY" >&2; exit 1; }

REPO=https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64
PKGS="dropbear-2024.86-r0 zlib-1.3.2-r1 utmps-libs-0.1.2.3-r2 skalibs-libs-2.14.3.0-r0"
mkdir -p "$CACHE"
for p in $PKGS; do
    [ -s "$CACHE/$p.apk" ] || curl -fsS --max-time 120 -o "$CACHE/$p.apk" "$REPO/$p.apk"
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ov"
for p in $PKGS; do
    # .apk = concatenated gzip members (signature, control, data); gzip -dc
    # joins them, tar extracts all three, we drop the control/signature files.
    (cd "$T/ov" && gzip -dc "$CACHE/$p.apk" | tar -xf - 2>/dev/null || true)
done
rm -f "$T/ov/.PKGINFO" "$T"/ov/.SIGN.* 2>/dev/null || true
[ -x "$T/ov/usr/sbin/dropbear" ] || { echo "dropbear binary not found in packages" >&2; exit 1; }

mkdir -p "$T/ov/etc/dropbear" "$T/ov/root/.ssh" "$T/ov/dev/pts" "$T/ov/var/run"
chmod 700 "$T/ov/root" "$T/ov/root/.ssh"
cp "$PUBKEY" "$T/ov/root/.ssh/authorized_keys"; chmod 600 "$T/ov/root/.ssh/authorized_keys"
# Alpine ships root:*:: (locked). Empty hash = no password login, key auth OK.
printf 'root::0:0:99999:7:::\n' > "$T/ov/etc/shadow"; chmod 600 "$T/ov/etc/shadow"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$T/ov/etc/passwd"

cat > "$T/ov/init" <<EOF
#!/bin/sh
# omarchy-m5 bring-up init, debug variant (m5pro-linux host/macos/mk-debug-initramfs.sh).
BB=/bin/busybox
\$BB mkdir -p /proc /sys /dev /tmp /run
\$BB mount -t proc     proc     /proc
\$BB mount -t sysfs    sysfs    /sys
\$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
\$BB mount -t tmpfs    tmpfs    /tmp
\$BB mkdir -p /dev/pts && \$BB mount -t devpts devpts /dev/pts 2>/dev/null

echo
echo "================================================"
echo " omarchy-m5: userspace is alive on T6050 (M5 Pro)  [debug initramfs]"
echo "================================================"
echo "kernel:  \$(\$BB uname -a)"
echo "cpus:    \$(\$BB grep -c ^processor /proc/cpuinfo)"
echo "cmdline: \$(\$BB cat /proc/cmdline)"
echo

# USB gadget network, then an SSH server on it so a failed root mount is
# still reachable: eem-vm.py --keep 'dmesg'  (root@10.55.0.2, key ~/.ssh/mbp)
[ -x /usr/sbin/usb-gadget-net ] && /usr/sbin/usb-gadget-net
/usr/sbin/dropbear -R -E -p 22 2>/tmp/dropbear.log && echo "debug: dropbear listening on the gadget link"

ROOT=\$(\$BB sed -n 's/.*\\bm5\\.root=\\([^ ]*\\).*/\\1/p' /proc/cmdline)
if [ -n "\$ROOT" ]; then
    i=0; while [ ! -b "\$ROOT" ] && [ \$i -lt $((WAIT * 10)) ]; do
        [ \$((i % 100)) -eq 0 ] && echo "debug: waiting for \$ROOT (\$((i / 10)) s)"
        \$BB sleep 0.1; i=\$((i+1))
    done
    if [ -b "\$ROOT" ]; then
        echo "debug: \$ROOT appeared after \$((i / 10)) s"
        if \$BB mount -t ext4 -o noatime "\$ROOT" /mnt 2>/dev/null; then
            \$BB killall dropbear 2>/dev/null
            \$BB umount /dev/pts 2>/dev/null
            \$BB umount /proc /sys /dev /tmp 2>/dev/null
            exec \$BB switch_root /mnt /sbin/init
        fi
        echo "debug: mount of \$ROOT failed"
    fi
    echo "m5.root=\$ROOT did not mount after $WAIT s; staying in initramfs (sshd up)"
    \$BB dmesg > /tmp/dmesg.txt 2>/dev/null
fi
exec \$BB sh
EOF
chmod 755 "$T/ov/init"

(cd "$T/ov" && find . -mindepth 1 | sed 's#^\./##' | sort | cpio -o -H newc -R 0:0 2>/dev/null > "$T/overlay.cpio")
# ONE gzip member: m1n1's payload loader (src/payload.c decompress_gz) treats
# every gzip member as a separate payload and kboot_set_initrd() keeps only
# the last one, so two members would drop the base archive. The kernel is
# happy with concatenated cpio archives inside a single stream (4-byte
# aligned, zero padding allowed).
gzip -dc "$BASE" > "$T/base.cpio"
pad=$(( (4 - $(stat -f %z "$T/base.cpio") % 4) % 4 )); [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero >> "$T/base.cpio"
mkdir -p "$(dirname "$OUT")"
cat "$T/base.cpio" "$T/overlay.cpio" | gzip -9n > "$OUT"
echo "==> $OUT ($(stat -f %z "$OUT") bytes; raw base $(stat -f %z "$T/base.cpio") + overlay $(stat -f %z "$T/overlay.cpio"))"
echo "    root wait ${WAIT}s, dropbear on the gadget link, key $(cut -c1-40 "$PUBKEY")..."
shasum -a 256 "$OUT"
