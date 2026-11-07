#!/usr/bin/env bash
# Undo the Omarchy-chain test: boot.bin = the daily again (from boot.bin.prev, checked against the hash
# deploy-state.txt recorded), remove EFI/BOOT/BOOTAA64.EFI, limine.conf and m5chain/. Does NOT reboot.
# Works from the test boot (Linux through Limine) and from a fallback boot (the daily from prev).
#   HOST=root@<macbook-ip> bash cleanup-OMARCHY-CHAIN-B1.sh
# From macOS instead (Linux unreachable): host/macos/r1-deploy.sh restore prev, then delete EFI/BOOT/BOOTAA64.EFI,
# limine.conf and m5chain/ on /Volumes/OMARCHY by hand.
set -euo pipefail
W=${OMARCHY_CHAIN_WORK:-$HOME/Work/agents/omarchy-chain}   # work dir: inputs/, u-boot/, out/, private/
HOST=${HOST:?set HOST=root@<macbook-ip>}
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes -o ConnectTimeout=20)
DAILY=$(awk '/^daily: /{print $2}' "$W/deploy-state.txt")
OLDPREV=$(awk '/^before: boot.bin.prev /{print $3}' "$W/deploy-state.txt")
[ ${#DAILY} = 64 ] || { echo "no daily hash in deploy-state.txt"; exit 1; }
ssh "${SSHO[@]}" "$HOST" DAILY=$DAILY OLDPREV=$OLDPREV 'bash -s' <<'REMOTE' | tee -a "$W/deploy-state.txt"
set -eu
mountpoint -q /boot || mount /dev/nvme0n1p4 /boot
cd /boot
[ "$(sha256sum m1n1/boot.bin.prev | cut -d' ' -f1)" = "$DAILY" ] || { echo "ABORT: boot.bin.prev is not the daily $DAILY"; exit 1; }
rm -f m1n1/boot.bin.new
cp m1n1/boot.bin.prev m1n1/boot.bin.new && sync
[ "$(sha256sum m1n1/boot.bin.new | cut -d' ' -f1)" = "$DAILY" ] || { rm -f m1n1/boot.bin.new; echo "ABORT: copy mismatch"; exit 1; }
mv -f m1n1/boot.bin.new m1n1/boot.bin
rm -f EFI/BOOT/BOOTAA64.EFI limine.conf
rm -rf m5chain
rmdir EFI/BOOT 2>/dev/null || true; rmdir EFI 2>/dev/null || true
sync; cd /; umount /boot; mount /dev/nvme0n1p4 /boot; cd /boot
[ "$(sha256sum m1n1/boot.bin | cut -d' ' -f1)" = "$DAILY" ] && echo "cleanup: boot.bin = daily $DAILY (after remount)"
ls -la /boot /boot/m1n1; df -Pm /boot | tail -1
echo "boot.bin.prev is the daily too; the pre-test prev was $OLDPREV (copy it back from the Studio if wanted)"
REMOTE
