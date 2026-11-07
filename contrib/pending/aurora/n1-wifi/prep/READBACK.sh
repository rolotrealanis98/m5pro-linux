#!/usr/bin/env bash
# READBACK.sh - read-only status dump after a W0/W1 boot. Run over ssh as root, capture on the Studio:
#   ssh $SSHO root@$HOST 'bash -s' < READBACK.sh > ~/Work/agents/n1-wifi/logs/<tag>-readback.txt 2>&1
# Changes nothing except 'modprobe phram' (maps m1n1's log RAM as /dev/mtdN, read-only use).
# The output holds per-unit data (m1n1 log, link/MAC lines): keep it on the Studio, never in a repo.
sec() { printf '\n##### %s\n' "$*"; }
sec "which payload is this"
uname -r; uptime -s
cat /proc/cmdline
grep -q 'm5.selftest=1' /proc/cmdline && echo "VERDICT: cmdline has m5.selftest=1 -> this is the TEST payload (W0/W1)" \
                                      || echo "VERDICT: no m5.selftest=1 -> this is the DAILY/prev: the test boot did NOT stay up (fallback or revert happened)"
printf 'n1 chosen var: '; tr -d '\0' < /proc/device-tree/chosen/m5pro,n1 2>/dev/null || echo "(absent: W0, or not W1)"; echo
printf 'boot-slot: '; tr -d '\0' < /proc/device-tree/chosen/m5pro,boot-slot 2>/dev/null || echo "(absent)"; echo
printf 'pmu-scrpad: '; tr -d '\0' < /proc/device-tree/chosen/m5pro,pmu-scrpad 2>/dev/null || echo "(absent)"; echo
mountpoint -q /boot || mount /dev/nvme0n1p4 /boot
echo "ESP payload hashes (boot.bin == boot.bin.prev means a fallback/revert already happened):"
sha256sum /boot/m1n1/boot.bin* 2>&1 | cut -c1-16,65-
ls -lt /boot/m1n1 /boot/r1-logs 2>&1 | head -30
sec "m5-selftest journal"
journalctl -b -t m5-selftest --no-pager 2>&1 | tail -20
sec "kernel: N1 / PCIe / DART / firmware lines"
dmesg | grep -iE 'apple-pcie|adopted|1cb0000000|centauri|n1 |pci 0000:0|apple-dart 41|wlan|hci0|firmware|SError|fault|phase[0-9]|port cycle|retrained|IPC bootstrap|Beta|Alpha|regulatory' 
sec "errors (dmesg -l err and worse)"
dmesg -l emerg,alert,crit,err
sec "device tree: port 0"
cat /proc/device-tree/pcie@1cb0000000/pci@0,0/status 2>&1; echo
ls /proc/device-tree/pcie@1cb0000000/pci@0,0 2>&1 | grep -E 'tunables|status|control|wifi|bluetooth'
sec "devices deferred"
cat /sys/kernel/debug/devices_deferred 2>&1 | head
sec "PCI devices (id only)"
for d in /sys/bus/pci/devices/*; do printf '%s %s:%s class %s\n' "$(basename "$d")" "$(cat "$d/vendor")" "$(cat "$d/device")" "$(cat "$d/class")"; done
sec "network"
ip -br link; ip -br addr
command -v iw >/dev/null && iw dev || echo "(iw not installed)"
rfkill list 2>&1
command -v btmgmt >/dev/null && btmgmt info 2>&1 | head -20 || echo "(btmgmt not installed)"
sec "m1n1 log (phram)"
if modprobe phram 2>&1; then
    cat /proc/mtd
    for m in $(awk -F'[:]' '/mtd[0-9]+/ {print $1}' /proc/mtd); do
        if tr -c '[:print:]\n' '\n' < "/dev/$m" 2>/dev/null | grep -aqE '^(n1:|pcie-t6050:)'; then
            echo "--- /dev/$m"
            tr -c '[:print:]\n' '\n' < "/dev/$m" | grep -aE '^(n1:|pcie-t6050:|chosen\.|FDT|usb: |tunable|STOP|storage|kboot|m1n1 )' | tail -80
        fi
    done
else
    echo "phram not loadable: read the n1:/pcie-t6050: lines from a photo of the panel instead"
fi
sec "end"
