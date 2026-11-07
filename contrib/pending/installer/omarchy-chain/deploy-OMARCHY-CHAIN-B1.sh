#!/usr/bin/env bash
# Deploy the J716s Omarchy-chain test B1 onto the ESP. Does NOT reboot.
#   HOST=root@<macbook-ip> bash deploy-OMARCHY-CHAIN-B1.sh
# Run it from the running DAILY (primary slot, no m5.selftest). It
#   0. checks the machine state and the ESP (room, at most four payloads, no EFI loader or Limine yet),
#   1. copies BOOTAA64.EFI, limine.conf, m5chain/Image, m5chain/initramfs-ftab.cpio.gz and boot.bin.new
#      to temporary names, checks every sha256, then moves them into place,
#   2. makes boot.bin.prev = the running daily and boot.bin = B1 (both verified),
#   3. unmounts and remounts the ESP by device and hashes everything again (first-boot-of-a-new-file
#      observation, RESULTS.md),
# and records the before/after hashes in deploy-state.txt on the Studio (cleanup uses it).
# The boot itself must be a COLD start (full power-off, then the power button): B1's stage 2 has no
# warm-N1 entry, and a loader without it hangs once after a restart with the N1 in use.
set -euo pipefail
W=${OMARCHY_CHAIN_WORK:-$HOME/Work/agents/omarchy-chain}   # work dir: inputs/, u-boot/, out/, private/
HOST=${HOST:?set HOST=root@<macbook-ip>}
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes -o ConnectTimeout=20)
ESP=$W/out/esp; PESP=$W/private/esp
( cd "$ESP" && shasum -a 256 -c SHA256SUMS >/dev/null ) && ( cd "$PESP" && shasum -a 256 -c SHA256SUMS >/dev/null ) \
    || { echo "Studio copies do not match their SHA256SUMS: rebuild (build.sh, mk-esp.py)"; exit 1; }
sha() { awk -v f="$2" '$2==f{print $1}' "$1/SHA256SUMS"; }
B1=$(sha "$ESP" m1n1/boot.bin); EFI=$(sha "$ESP" EFI/BOOT/BOOTAA64.EFI); CONF=$(sha "$ESP" limine.conf)
IMG=$(sha "$ESP" m5chain/Image); IRD=$(sha "$PESP" m5chain/initramfs-ftab.cpio.gz)
NEED_MB=$(( ( $(stat -f %z "$ESP/m1n1/boot.bin" "$ESP/EFI/BOOT/BOOTAA64.EFI" "$ESP/limine.conf" "$ESP/m5chain/Image" \
    "$PESP/m5chain/initramfs-ftab.cpio.gz" | paste -sd+ - | bc) + 64*1024*1024 ) / 1048576 ))   # + room for boot.bin.prev.new

# ---- 0. preflight
ssh "${SSHO[@]}" "$HOST" NEED_MB=$NEED_MB 'bash -s' <<'REMOTE' | tee "$W/deploy-state.txt"
set -eu
if grep -q 'm5.selftest=1' /proc/cmdline; then echo "ABORT: the running payload is a test (m5.selftest=1): boot the daily first"; exit 1; fi
if grep -q 'm5.chain=' /proc/cmdline; then echo "ABORT: this boot already came through the Omarchy chain: run cleanup first"; exit 1; fi
slot=$(tr -d '\0' < /proc/device-tree/chosen/m5pro,boot-slot 2>/dev/null || echo unknown)
[ "$slot" = primary ] || { echo "ABORT: running from slot '$slot', not primary: boot.bin may be a failed test; fix the ESP first"; exit 1; }
mountpoint -q /boot || mount /dev/nvme0n1p4 /boot
cd /boot
for p in EFI/BOOT/BOOTAA64.EFI limine.conf m5chain; do
    if [ -e "$p" ]; then echo "ABORT: /boot/$p already exists (not expected on this ESP): look before replacing it"; exit 1; fi
done
rm -f m1n1/boot.bin.new m1n1/boot.bin.prev.new
n=$(ls m1n1/boot.bin* | wc -l); [ "$n" -le 4 ] || { echo "ABORT: $n payloads on the ESP, at most four (ESP-POLICY.md)"; exit 1; }
free=$(df -Pm /boot | awk 'NR==2{print $4}')
[ "$free" -ge "$NEED_MB" ] || { echo "ABORT: ESP has $free MB free, need $NEED_MB"; exit 1; }
echo "preflight ok: slot primary, $n payloads, $free MB free (need $NEED_MB)"
echo "before: boot.bin      $(sha256sum m1n1/boot.bin | cut -d' ' -f1)"
echo "before: boot.bin.prev $(sha256sum m1n1/boot.bin.prev | cut -d' ' -f1)"
df -Pm /boot | tail -1
REMOTE

# ---- 1. copy to temporary names, verify, move into place (boot.bin last, in step 2)
ssh "${SSHO[@]}" "$HOST" 'mkdir -p /boot/EFI/BOOT /boot/m5chain'
scp "${SSHO[@]}" "$ESP/EFI/BOOT/BOOTAA64.EFI" "$HOST:/boot/EFI/BOOT/BOOTAA64.EFI.new"
scp "${SSHO[@]}" "$ESP/limine.conf" "$HOST:/boot/limine.conf.new"
scp "${SSHO[@]}" "$ESP/m5chain/Image" "$HOST:/boot/m5chain/Image.new"
scp "${SSHO[@]}" "$PESP/m5chain/initramfs-ftab.cpio.gz" "$HOST:/boot/m5chain/initramfs-ftab.cpio.gz.new"
scp "${SSHO[@]}" "$ESP/m1n1/boot.bin" "$HOST:/boot/m1n1/boot.bin.new"

# ---- 2. verify, rotate prev = the running daily, boot.bin = B1
ssh "${SSHO[@]}" "$HOST" B1=$B1 EFI=$EFI CONF=$CONF IMG=$IMG IRD=$IRD 'bash -s' <<'REMOTE' | tee -a "$W/deploy-state.txt"
set -eu
cd /boot; sync
chk() { [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] || { echo "ABORT: $1 does not match $2"; exit 1; }; }
chk EFI/BOOT/BOOTAA64.EFI.new "$EFI"; chk limine.conf.new "$CONF"; chk m5chain/Image.new "$IMG"
chk m5chain/initramfs-ftab.cpio.gz.new "$IRD"; chk m1n1/boot.bin.new "$B1"
mv -f EFI/BOOT/BOOTAA64.EFI.new EFI/BOOT/BOOTAA64.EFI; mv -f limine.conf.new limine.conf
mv -f m5chain/Image.new m5chain/Image; mv -f m5chain/initramfs-ftab.cpio.gz.new m5chain/initramfs-ftab.cpio.gz
cur=$(sha256sum m1n1/boot.bin | cut -d' ' -f1)
cp m1n1/boot.bin m1n1/boot.bin.prev.new && sync && chk m1n1/boot.bin.prev.new "$cur"
mv -f m1n1/boot.bin.prev.new m1n1/boot.bin.prev
mv -f m1n1/boot.bin.new m1n1/boot.bin
sync
echo "daily: $cur (now boot.bin.prev)"
echo "after: boot.bin = B1 $B1"
REMOTE

# ---- 3. remount by device, hash everything again
ssh "${SSHO[@]}" "$HOST" B1=$B1 EFI=$EFI CONF=$CONF IMG=$IMG IRD=$IRD 'bash -s' <<'REMOTE' | tee -a "$W/deploy-state.txt"
set -eu
sync; umount /boot; mount /dev/nvme0n1p4 /boot; cd /boot
chk() { [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] && echo "ok  $1" || { echo "BAD $1 after remount"; exit 1; }; }
chk m1n1/boot.bin "$B1"; chk EFI/BOOT/BOOTAA64.EFI "$EFI"; chk limine.conf "$CONF"; chk m5chain/Image "$IMG"
chk m5chain/initramfs-ftab.cpio.gz "$IRD"
ls -l m1n1/ EFI/BOOT/ m5chain/ limine.conf; df -Pm /boot | tail -1
echo "deployed. Next: an ATTENDED cold start: 'systemctl poweroff', wait 15 s, press the power button."
REMOTE
