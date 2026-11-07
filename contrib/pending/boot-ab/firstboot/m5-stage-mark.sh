#!/bin/sh
# SPDX-License-Identifier: MIT
# m5-stage-mark - userspace boot-stage marks in iBoot's PMU scratchpad, plus a dump of it.
# Runs on the MacBook root (shared by every payload), as root. EXPERIMENTAL, remove after the hunt.
#
#   m5-stage-mark.sh dump      print scratchpad bytes 0xf800-0xf80f (boot_stage is 0xf801,
#                              counts 0xf802, the error stage 0xf803, shutdown flag 0xf80f bit 3)
#   m5-stage-mark.sh root      boot_stage = 0x33 (root mounted, userspace running)
#   m5-stage-mark.sh net       boot_stage = 0x34 (network up / self-test passed)
#
# macsmc-reboot writes 0x30 at probe and 0 from its reboot notifier, so a clean reboot is
# unaffected. After an abrupt reset iBoot copies boot_stage into the error stage, which the
# stage-1 hands on as the third byte of chosen.m5pro,pmu-scrpad:
#   30 = died in the kernel or initramfs (before the root unit), 33 = after the root mounted,
#   34 = after the network came up, 00 = in its own orderly restart.
# Hook it with two oneshot units: After=local-fs.target (root), After=network-online.target
# (net); ExecStart=/usr/local/sbin/m5-stage-mark.sh <mode>.
set -eu
dev=
for d in /sys/bus/nvmem/devices/*; do
    of=$(readlink -f "$d/of_node" 2>/dev/null || true)
    case "$of" in *spmi@28a014000/pmic@e*) dev=$d/nvmem; break;; esac
done
[ -n "$dev" ] || { echo "m5-stage-mark: PMU nvmem (spmi@28a014000/pmic@e) not found"; exit 1; }
put() { printf "\\$(printf '%03o' "$1")" | dd of="$dev" bs=1 seek=$((0xf801)) conv=notrunc status=none; }
case "${1:-dump}" in
dump) dd if="$dev" bs=1 skip=$((0xf800)) count=16 status=none | od -An -tx1 | tr -s ' ' | sed 's/^/m5-stage-mark: f800:/' ;;
root) put $((0x33)); echo "m5-stage-mark: boot_stage 0x33" ;;
net)  put $((0x34)); echo "m5-stage-mark: boot_stage 0x34" ;;
*) echo "usage: $0 dump|root|net"; exit 2 ;;
esac
