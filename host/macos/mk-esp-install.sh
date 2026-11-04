#!/bin/bash
# Build (1) the stage-2 payload for the ESP and (2) a one-shot initramfs that writes it there.
# No network path exists from a macOS host to the M5, so the payload rides inside an initramfs
# booted over the tether with rdinit=/esp-install.sh: it mounts /dev/nvme0n1p4, copies the payload
# to m1n1/boot.bin, checks the sha256 and reboots into stage-1 m1n1.
#
#   host/macos/mk-esp-install.sh [--kernel Image.gz] [--dtb t6050-j716s.dtb] [--initramfs F] [--m1n1 plain.bin]
#   LINUX_INITRD=~/Work/omarchy-m5/build/initramfs-esp-install.cpio.gz \
#   LINUX_ARGS="... rdinit=/esp-install.sh" host/macos/m5.sh boot-linux
#
# Defaults are the October Linux-side builds in ~/Work/studio-artifacts. The stage-2 m1n1 is a
# plain (CHAINLOADING=0) build; the installed stage-1 is a CHAINLOADING=1 build with
# "chainload=<ESP PARTUUID>;m1n1/boot.bin" appended (see docs/boot-and-recovery.md).
set -euo pipefail
O=$HOME/Work/omarchy-m5; A=$HOME/Work/studio-artifacts
KERNEL=$A/Image.gz; DTB=$A/t6050-j716s.dtb; IRF=$A/initramfs.cpio.gz; M1N1=$A/m1n1-plain.bin; FWDIR=""
ARGS=${PAYLOAD_ARGS:-"earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5"}
while [ $# -gt 0 ]; do case "$1" in
    --kernel) KERNEL=$2; shift 2 ;; --dtb) DTB=$2; shift 2 ;; --initramfs) IRF=$2; shift 2 ;; --m1n1) M1N1=$2; shift 2 ;;
    --firmware) FWDIR=$2; shift 2 ;;   # lib/firmware tree (e.g. build/firmware with apple/tpmtfw-j716s.bin): also copied into the Arch root on p5
    *) echo "unknown arg $1" >&2; exit 2 ;; esac; done
# mkpayload.sh derives the DTB from --board under vendor/linux; give it ours through a temp board name
cp "$DTB" "$O/vendor/linux/arch/arm64/boot/dts/apple/t6050-espboard.dtb"
(cd "$O" && scripts/mkpayload.sh --board espboard --m1n1 "$M1N1" --kernel "$KERNEL" --initramfs "$IRF" \
    --out build/m1n1-payload-j716s.bin --bootargs "$ARGS" | tail -8)
rm -f "$O/vendor/linux/arch/arm64/boot/dts/apple/t6050-espboard.dtb"
W=$O/build/esp-install; rm -rf "$W"; mkdir -p "$W/root"
cp "$O/build/m1n1-payload-j716s.bin" "$W/root/m1n1-payload.bin"
[ -n "$FWDIR" ] && { mkdir -p "$W/root/fw"; cp -R "$FWDIR"/. "$W/root/fw/"; }
cat > "$W/root/esp-install.sh" <<'INIT'
#!/bin/sh
BB=/bin/busybox
$BB mkdir -p /proc /sys /dev /mnt /tmp
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys; $BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo; echo "=========== esp-install: cpus=$($BB grep -c ^processor /proc/cpuinfo) ==========="
i=0; while [ ! -b /dev/nvme0n1p4 ] && [ $i -lt 90 ]; do $BB sleep 1; i=$((i+1)); done
if ! $BB mount -t vfat /dev/nvme0n1p4 /mnt; then echo "esp-install: mount of /dev/nvme0n1p4 FAILED"; exec $BB sh; fi
$BB mkdir -p /mnt/m1n1
if $BB cp /m1n1-payload.bin /mnt/m1n1/boot.bin && $BB sync; then
    $BB ls -la /mnt/m1n1; $BB sha256sum /m1n1-payload.bin /mnt/m1n1/boot.bin
    $BB umount /mnt && $BB sync
    if [ -d /fw ]; then   # also install the firmware tree into the Arch root (p5, ext4)
        if $BB mount -t ext4 /dev/nvme0n1p5 /mnt; then
            $BB mkdir -p /mnt/usr/lib/firmware && $BB cp -r /fw/. /mnt/usr/lib/firmware/ && $BB sync
            echo "esp-install: firmware installed into p5:"; $BB find /mnt/usr/lib/firmware/apple -type f 2>/dev/null
            $BB umount /mnt
        else echo "esp-install: could not mount p5 for the firmware copy"; fi
    fi
    echo "esp-install: DONE, rebooting into m1n1 in 8 s"; $BB sleep 8; $BB reboot -f
    echo "esp-install: reboot did not happen, hold the power button"; exec $BB sh
else
    echo "esp-install: copy FAILED"; exec $BB sh
fi
INIT
chmod 755 "$W/root/esp-install.sh"
(cd "$W/root" && find . -mindepth 1 | cpio -o --format newc 2>/dev/null | gzip -9 > "$W/overlay.cpio.gz")
cat "$IRF" "$W/overlay.cpio.gz" > "$O/build/initramfs-esp-install.cpio.gz"
ls -la "$O/build/m1n1-payload-j716s.bin" "$O/build/initramfs-esp-install.cpio.gz"
echo "boot it:  LINUX_INITRD=$O/build/initramfs-esp-install.cpio.gz LINUX_ARGS=\"earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 rdinit=/esp-install.sh\" host/macos/m5.sh boot-linux"
