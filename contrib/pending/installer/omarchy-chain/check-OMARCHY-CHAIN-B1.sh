#!/usr/bin/env bash
# Read the result of the Omarchy-chain test boot over ssh (read-only). Prints a verdict line first.
#   HOST=root@<macbook-ip> bash check-OMARCHY-CHAIN-B1.sh | tee check-$(date +%Y%m%d-%H%M).log
set -euo pipefail
HOST=${HOST:?set HOST=root@<macbook-ip>}
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes -o ConnectTimeout=20)
ssh "${SSHO[@]}" "$HOST" 'bash -s' <<'REMOTE'
ch() { tr -d '\0' < "/proc/device-tree/chosen/$1" 2>/dev/null || echo "(absent)"; }
chain=$(grep -o 'm5.chain=[a-z-]*' /proc/cmdline || echo "m5.chain=(none)")
slot=$(ch m5pro,boot-slot); stage2=$(ch m5pro,stage2)
if [ "$chain" != "m5.chain=(none)" ] && [ "$stage2" = omarchy-chain-boot-b1 ]; then
    echo "VERDICT: PASS - booted through m1n1 stage 2 -> U-Boot -> Limine ($chain), slot $slot"
elif [ "$stage2" = "(absent)" ]; then
    echo "VERDICT: FALLBACK - this is the daily (slot $slot): B1 did not reach Linux (or a first-boot fallback; retry once)"
else
    echo "VERDICT: UNEXPECTED - stage2=$stage2 chain=$chain slot=$slot"
fi
echo "--- cmdline";               cat /proc/cmdline
echo "--- chosen";                ls /proc/device-tree/chosen/
for p in m5pro,boot-slot m5pro,pmu-scrpad m5pro,stage1 m5pro,stage2 asahi,efi-system-partition asahi,nvme-adopt \
         u-boot,version bootargs; do printf '%-32s %s\n' "$p" "$(ch $p)"; done
echo "--- EFI (U-Boot as firmware, Limine as loader)"
dmesg | grep -i -E 'efi: EFI v|EFI stub|Remapping and enabling EFI|efi: (ESRT|RTPROP|MEMRESERVE|INITRD|SMBIOS)' | head
[ -d /sys/firmware/efi ] && echo "/sys/firmware/efi present" || echo "/sys/firmware/efi ABSENT (not an EFI boot)"
for v in LoaderInfo LoaderEntrySelected LoaderTimeExecUSec; do
    f=$(ls /sys/firmware/efi/efivars/$v-* 2>/dev/null | head -1)
    [ -n "$f" ] && printf '%-22s %s\n' "$v" "$(tail -c +5 "$f" | tr -d '\0')"
done
[ -d /proc/device-tree/bootstage ] && echo "U-Boot bootstage record: $(ls /proc/device-tree/bootstage | wc -l) entries"
echo "--- CPUs, storage, network"
echo "nproc $(nproc)"; findmnt -no SOURCE,FSTYPE /
dmesg | grep -i -E 'nvme|apple-nvme' | head -8
ip -br addr | grep -v '^lo'
echo "--- watchdog"; cat /sys/class/watchdog/watchdog0/state 2>/dev/null; cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null
echo "--- reserved memory from U-Boot (ANS RTKit buffers, if U-Boot started the session)"
ls /proc/device-tree/reserved-memory/ 2>/dev/null | grep -i -E 'ans|rtkit' || echo "(none named ans-rtkit)"
echo "--- ESP"; mountpoint -q /boot || mount /dev/nvme0n1p4 /boot; ls -l /boot/m1n1/; sha256sum /boot/m1n1/boot.bin*
REMOTE
