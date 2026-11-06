#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# mk-selftest-initramfs.sh - debug initramfs plus a self-reverting test boot.
#
# Same base as host/macos/mk-debug-initramfs.sh (appends an overlay cpio to an existing
# initramfs; dropbear on the USB gadget link; 60 s root wait; the nvme-apple rebind loop),
# and in addition:
#   * when the root does not mount, prints a DIAG block on the panel
#     (bound platform drivers, nvme/sart/smc/mailbox/rtkit/dockchannel lines, platform
#     devices without a driver);
#   * when the root mounts and the kernel command line has m5.selftest=1, it installs
#     /usr/local/sbin/m5-selftest and m5-selftest.service into the root before switch_root.
#     The service waits 90 s; if there is no route and no ping to 1.1.1.1 it saves
#     dmesg/journal/links/cmdline and the failed boot.bin to /boot/r1-logs/selftest-*/,
#     copies /boot/m1n1/boot.bin.prev over /boot/m1n1/boot.bin and reboots.
#   * Limit: the revert only exists once the root has mounted. A payload that never
#     reaches the root stays in the initramfs and needs a manual recovery.
#   * Before deploying a test payload, boot.bin.prev on the ESP must hold the last
#     known-good payload.
#
# Written for macOS (BSD stat/shasum). Output is ONE gzip member (m1n1 keeps only the last).
#
# Usage: mk-selftest-initramfs.sh [--base IN.cpio.gz] [--out OUT.cpio.gz]
#                                 [--pubkey ~/.ssh/mbp.pub] [--cache DIR] [--wait SECONDS]
set -euo pipefail

BASE=$HOME/Work/omarchy-m5/build/initramfs-tp.cpio.gz
OUT=$HOME/Work/omarchy-m5/build/initramfs-selftest.cpio.gz
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
# omarchy-m5 bring-up init, selftest variant (m5pro-linux contrib/pending/aurora/tools/mk-selftest-initramfs.sh).
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
    # T6050 2026-11-05: the ANS (storage coprocessor) firmware sometimes needs
    # ~3 s to come up, the RTKit transport waits 1 s and nvme-apple gives up
    # for good ("ANS did not boot", "Reset failure status: -62"). A rebind
    # of the driver a few seconds later succeeds, so retry every 12 s.
    NVME=45dcc0000.nvme; DRV=/sys/bus/platform/drivers/nvme-apple
    i=0; while [ ! -b "\$ROOT" ] && [ \$i -lt $((WAIT * 10)) ]; do
        [ \$((i % 100)) -eq 0 ] && echo "debug: waiting for \$ROOT (\$((i / 10)) s)"
        if [ \$i -gt 0 ] && [ \$((i % 120)) -eq 0 ] && [ -d \$DRV ] && \$BB dmesg | \$BB grep -q "ANS did not"; then
            echo "debug: ANS did not boot in time, rebinding \$NVME"
            echo \$NVME > \$DRV/unbind 2>/dev/null; \$BB sleep 1; echo \$NVME > \$DRV/bind 2>/dev/null
        fi
        \$BB sleep 0.1; i=\$((i+1))
    done
    if [ -b "\$ROOT" ]; then
        echo "debug: \$ROOT appeared after \$((i / 10)) s"
        if \$BB mount -t ext4 -o noatime "\$ROOT" /mnt 2>/dev/null; then
            if \$BB grep -q "m5.selftest=1" /proc/cmdline; then
                echo "selftest: installing the self-revert watchdog into the root (90 s, reverts to boot.bin.prev without network)"
                \$BB mkdir -p /mnt/usr/local/sbin /mnt/etc/systemd/system/multi-user.target.wants
                \$BB cat > /mnt/usr/local/sbin/m5-selftest <<'SFT'
#!/bin/bash
# m5pro-linux self-revert: a payload booted with m5.selftest=1 must reach the network
# within 90 s, or it is replaced by boot.bin.prev and the machine reboots.
sleep 90
if ip route get 1.1.1.1 >/dev/null 2>&1 && ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
    logger -t m5-selftest "network OK, keeping this payload"; exit 0
fi
mountpoint -q /boot || mount /dev/nvme0n1p4 /boot
D=/boot/r1-logs/selftest-\$(date +%Y%m%d-%H%M); mkdir -p "\$D"
dmesg > "\$D/dmesg.txt"; journalctl -b --no-pager > "\$D/journal.txt" 2>&1; ip -br link > "\$D/links.txt"
ls /sys/bus/usb/devices > "\$D/usb-devices.txt" 2>&1; cat /proc/cmdline > "\$D/cmdline.txt"
cp /boot/m1n1/boot.bin "\$D/boot.bin.failed" 2>/dev/null
cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin && sync && echo "reverted to boot.bin.prev" > "\$D/REVERTED"
sync; systemctl reboot
SFT
                \$BB chmod 755 /mnt/usr/local/sbin/m5-selftest
                \$BB cat > /mnt/etc/systemd/system/m5-selftest.service <<'SFT'
[Unit]
Description=m5pro-linux self-reverting test boot
ConditionKernelCommandLine=m5.selftest=1
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/m5-selftest
[Install]
WantedBy=multi-user.target
SFT
                \$BB ln -sf /etc/systemd/system/m5-selftest.service /mnt/etc/systemd/system/multi-user.target.wants/m5-selftest.service
            fi
            \$BB killall dropbear 2>/dev/null
            \$BB umount /dev/pts 2>/dev/null
            \$BB umount /proc /sys /dev /tmp 2>/dev/null
            exec \$BB switch_root /mnt /sbin/init
        fi
        echo "debug: mount of \$ROOT failed"
    fi
    echo "m5.root=\$ROOT did not mount after $WAIT s; staying in initramfs (sshd up)"
    \$BB dmesg > /tmp/dmesg.txt 2>/dev/null
    echo "================ DIAG: drivers bound ================"
    \$BB ls /sys/bus/platform/drivers | \$BB tr '\\n' ' ' | \$BB fold -w 150
    echo
    echo "================ DIAG: nvme/sart/smc/mailbox/rtkit/deferred ================"
    \$BB dmesg | \$BB grep -iE "nvme|sart|smc|mailbox|rtkit|ans|dockchannel|deferred|probe .*fail|error -[0-9]" | \$BB grep -vE "pmgr|Failed to reach power|syslog message" | \$BB tail -42
    echo "================ DIAG: devices without driver (platform) ================"
    for d in /sys/bus/platform/devices/*nvme* /sys/bus/platform/devices/*smc* /sys/bus/platform/devices/*sart* /sys/bus/platform/devices/*mtp* /sys/bus/platform/devices/*input*; do [ -e "\$d" ] && echo "\$d -> \$(\$BB readlink \$d/driver 2>/dev/null || echo NO-DRIVER)"; done
    echo "================ END DIAG (photograph) ================"
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
