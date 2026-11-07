#!/bin/bash
# e1-readback.sh - GPU step E1 readback on the J716s. Read-only: no MMIO, no /dev/mem, no writes outside
# the log directory. Run as root on the E1 boot (or on any boot, to compare):
#   bash e1-readback.sh            # logs to /boot/r1-logs/e1-<UTC>/ (or --out DIR)
# Prints one VERDICT line at the end; the log directory holds dmesg, the DT nodes m1n1 filled in, the genpd
# summary, the deferred-probe list and the device bindings.
set -u
OUT=""
[ "${1:-}" = "--out" ] && OUT=${2:-}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -n "$OUT" ] || { mountpoint -q /boot || mount /dev/nvme0n1p4 /boot; OUT=/boot/r1-logs/e1-$(date -u +%Y%m%dT%H%M%SZ); }
mkdir -p "$OUT" || exit 1
L=$OUT/readback.log
say() { echo "$*" | tee -a "$L"; }
DT=/proc/device-tree
GPU=$DT/soc@2300000000/gpu@2300000000
PM=$DT/soc@2300000000/power-management@2300e80000

say "== E1 readback $(date -u +%FT%TZ)"
say "uname: $(uname -r)"
say "cmdline: $(cat /proc/cmdline)"
say "boot.bin: $(sha256sum /boot/m1n1/boot.bin 2>/dev/null | cut -c1-8) prev: $(sha256sum /boot/m1n1/boot.bin.prev 2>/dev/null | cut -c1-8)"
var=$(tr -d '\0' 2>/dev/null < $DT/chosen/m5pro,gpu || echo unset)
say "gpu chosen var: $var"
zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_(RUST|DRM_ASAHI|APPLE_PMP)=|^# CONFIG_APPLE_PMP is not set' | tee -a "$L"

dmesg > "$OUT/dmesg.txt" 2>&1
cp /proc/iomem "$OUT/iomem.txt" 2>/dev/null

say "== DT as m1n1 left it"
node() { # <path> <label>
    local p=$1 st reg
    [ -d "$p" ] || { say "  $2: missing"; return; }
    st=$(tr -d '\0' 2>/dev/null < "$p/status" || echo okay)
    reg=$(od -An -tx1 -v "$p/reg" 2>/dev/null | tr -d ' \n' | sed 's/\(.\{16\}\)/\1 /g')
    say "  $2: status=$st reg=$reg"
}
for r in uat-ttbs uat-pagetables uat-handoff uat-l2-pagetables gpu-fw-text gpu-fw-data; do node $DT/reserved-memory/$r $r; done
node $DT/soc@2300000000/mailbox@2302600000 gfx_mbox
node $DT/soc@2300000000/mailbox@2302e00000 gfx1_mbox
node $GPU gpu
node $PM pmgr_gfx

say "== m1n1 stage-2 log (GPU lines only; phram, label m1n1_stage2.log)"
mtd=""
for n in /sys/class/mtd/mtd*/name; do [ "$(cat "$n" 2>/dev/null)" = m1n1_stage2.log ] && mtd=/dev/$(basename "$(dirname "$n")"); done
if [ -n "$mtd" ] && [ -r "$mtd" ]; then
    tr -d '\0' < "$mtd" | grep -aE 'FDT: GPU|m5pro,gpu|ADT: GPU' | tee -a "$L" > "$OUT/m1n1-gpu-lines.txt"
else
    say "  no m1n1_stage2.log mtd (phram not built in?)"
fi

say "== kernel lines"
grep -aE 'reserved mem: .*(gpu-fw|uat-)|2300e80000|2300000000\.gpu|aurora|GPU ID registers|Core masks|bare-metal GPU|No M5 configuration|Invalid core counts' "$OUT/dmesg.txt" | tee -a "$L" > "$OUT/gpu-lines.txt"
grep -aiE 'SError|Unhandled fault|Internal error|Oops|Kernel panic|dart.*fault|fault.*dart|BUG:|WARNING:.*(asahi|aurora|pmgr)|rcu.*stall|blocked for more than' "$OUT/dmesg.txt" > "$OUT/bad-lines.txt"
say "bad lines: $(wc -l < "$OUT/bad-lines.txt")"; head -20 "$OUT/bad-lines.txt" | tee -a "$L"

say "== power domains (gpx afr cs gfx)"
grep -E '^\s*(gpx|afr|cs|gfx)\s' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | tee -a "$L"
cp /sys/kernel/debug/pm_genpd/pm_genpd_summary "$OUT/" 2>/dev/null
say "== deferred probes"
cat /sys/kernel/debug/devices_deferred 2>/dev/null | tee -a "$L" > "$OUT/devices_deferred.txt"
say "== bindings"
for d in 2300000000.gpu 2302600000.mailbox 2302e00000.mailbox; do
    p=/sys/bus/platform/devices/$d
    if [ -e $p ]; then say "  $d: driver=$(basename "$(readlink $p/driver 2>/dev/null)" 2>/dev/null)"; else say "  $d: no device"; fi
done
say "== network"
ip -br addr 2>/dev/null | grep -v '^lo' | tee -a "$L"
ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && net=up || net=down
say "network: $net"
journalctl -b -t m5-selftest --no-pager 2>/dev/null | tail -5 | tee -a "$L"

# ---- verdict
ids=$(grep -a 'GPU ID registers' "$OUT/dmesg.txt" | tail -1 | sed 's/.*GPU ID registers: //')
refuse=$(grep -ac 'M5 Pro bare-metal GPU tables not yet available' "$OUT/dmesg.txt")
bad=$(wc -l < "$OUT/bad-lines.txt")
gst=$(tr -d '\0' 2>/dev/null < $GPU/status || echo missing)
v="VERDICT:"
if [ "$var" != 1 ]; then
    v="$v CONTROL (no gpu var): gpu node $gst"
    [ "$gst" = disabled ] && v="$v = as designed" || v="$v = UNEXPECTED"
elif [ "$gst" != okay ]; then
    v="$v STOP: m1n1 left the GPU node $gst: $(grep -a 'T6050: ' "$OUT/m1n1-gpu-lines.txt" 2>/dev/null | grep -v STOP | tail -1)"
elif [ "$bad" -gt 0 ]; then
    v="$v STOP: $bad fault/oops lines (bad-lines.txt)"
elif [ -z "$ids" ]; then
    v="$v NO PROBE: GPU ID registers never printed (devices_deferred, bindings above)"
elif [ "$refuse" -gt 0 ] && [ "${ids%% *}" = 0xb031100 ]; then
    v="$v PASS E1: ID $ids, clean refusal"
else
    v="$v LOOK: ID $ids, refusal lines $refuse"
fi
[ "$net" = up ] || v="$v; network DOWN"
say "$v"
say "logs: $OUT"
sync
