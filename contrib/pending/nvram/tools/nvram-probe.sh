#!/bin/bash
# SPDX-License-Identifier: MIT
# nvram-probe.sh: read-only checks of the J716s boot NOR and its NVRAM from Linux.
#
# Run as root on the MacBook after booting the payload whose DTB has the qspi node (patch 0001) with the
# stock spi-apple-qspi module. Nothing here programs or erases the flash and nothing arms the driver.
# On success it writes $STATE/probe.pass, which nvram-next-boot.sh requires before it will touch anything.
#
# usage: nvram-probe.sh [--macos-names FILE]
#   FILE: variable names from macOS, e.g. `nvram -p | cut -f1 | sort > names.txt` (names only)
#
# The dumps hold the user's NVRAM values (tokens, network names). They stay in $STATE (root only, mode 700):
# do not copy them off the machine or into a repository.
set -u
SYS=${SYS:-/sys}
PROCFS=${PROCFS:-/proc}
DEVDIR=${DEVDIR:-/dev}
STATE=${STATE:-/var/lib/nvram-t6050}
ASAHI_NVRAM=${ASAHI_NVRAM:-asahi-nvram}
ASAHI_BLESS=${ASAHI_BLESS:-asahi-bless}
EXPECT_JEDEC=${EXPECT_JEDEC:-c88317}     # macOS ioreg: spinor "JEDEC-ID" = 0xc88317
EXPECT_SIZE=${EXPECT_SIZE:-786432}       # ADT anvram reg: 0xc0000
HERE=$(cd "$(dirname "$0")" && pwd)
QSPI=$SYS/bus/platform/devices/505118000.spi
PARAM=$SYS/module/spi_apple_qspi/parameters/read_only

fail=0
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
info() { printf '      %s\n' "$*"; }

macos_names=
if [ "${1:-}" = "--macos-names" ]; then macos_names=${2:?FILE}; [ -r "$macos_names" ] || { echo "cannot read $macos_names"; exit 2; }; fi
if [ -z "${NVRAM_PROBE_NOROOT:-}" ] && [ "$(id -u)" != 0 ]; then echo "run as root"; exit 2; fi

umask 077
mkdir -p "$STATE" && chmod 700 "$STATE"
rm -f "$STATE/probe.pass"
out=$STATE/probe-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"

echo "== controller and flash"
[ -d "$QSPI" ] || { modprobe spi-apple-qspi 2>/dev/null; sleep 1; }
if [ -d "$QSPI" ]; then ok "platform device 505118000.spi present (qspi node enabled in the DTB)"; else bad "no 505118000.spi: wrong DTB, or the node is not enabled"; fi
if [ -L "$QSPI/driver" ]; then ok "bound to $(basename "$(readlink "$QSPI/driver")")"; else bad "spi-apple-qspi is not bound (modprobe spi-apple-qspi; dmesg | grep -i qspi)"; fi
if [ "$(cat "$PARAM" 2>/dev/null)" = Y ]; then ok "read_only=Y (driver refuses every program and erase)"; else bad "read_only is not Y: $(cat "$PARAM" 2>/dev/null || echo missing)"; fi

fs=$(cat "$QSPI/flash_status" 2>/dev/null || true)
jedec=$(printf '%s' "$fs" | sed -n 's/.*jedec=\([0-9a-f]\{6\}\).*/\1/p')
sr1=$(printf '%s' "$fs" | sed -n 's/.* sr1\{0,1\}=\([0-9a-f][0-9a-f]\).*/\1/p')
info "flash_status: ${fs:-unreadable}"
if [ "$jedec" = "$EXPECT_JEDEC" ]; then ok "JEDEC ID $jedec matches the ID macOS reports"; else bad "JEDEC ID '${jedec:-none}' is not $EXPECT_JEDEC: the board row does not apply, do not arm anything"; fi
if [ -n "$sr1" ]; then
    wip=$((0x$sr1 & 3)); bp=$((0x$sr1 & 0x7c))
    if [ "$wip" -eq 0 ]; then ok "status idle (WIP and WEL clear)"; else bad "WIP/WEL set in sr1=$sr1"; fi
    if [ "$bp" -eq 0 ]; then ok "no block-protect bit set in sr1=$sr1 (row bp_ok 0 fits)"; else info "NOTE block-protect bits set (sr1 & 0x7c = $(printf '%#x' "$bp")): the J716s row would refuse writes; see REPORT.md, bp_ok"; fi
else
    bad "could not parse sr1 from flash_status"
fi
nor=$(find "$SYS"/bus/spi/devices/ -maxdepth 2 -name spi-nor 2>/dev/null | head -n1)
if [ -n "$nor" ]; then
    nj=$(tr -d ':\n' < "$nor/jedec_id")
    info "spi-nor: jedec_id $nj, partname $(cat "$nor/partname" 2>/dev/null), manufacturer $(cat "$nor/manufacturer" 2>/dev/null)"
    if [ "$nj" = "$EXPECT_JEDEC" ]; then ok "spi-nor identified the flash"; else bad "spi-nor jedec_id $nj differs from $EXPECT_JEDEC"; fi
else
    bad "spi-nor did not bind to flash@0 (dmesg | grep -i -E 'spi-nor|qspi')"
fi

echo "== mtd partition"
line=$(awk '$4 == "\"nvram\"" { print }' "$PROCFS/mtd" 2>/dev/null | head -n1)
mtd=${line%%:*}
if [ -z "$mtd" ]; then bad "no mtd partition named nvram in $PROCFS/mtd"; else
    sz=$((0x$(echo "$line" | awk '{print $2}'))); es=$((0x$(echo "$line" | awk '{print $3}')))
    info "$mtd size $sz erasesize $es"
    if [ "$sz" -eq "$EXPECT_SIZE" ]; then ok "partition size $sz"; else bad "partition size $sz, expected $EXPECT_SIZE"; fi
    if [ "$es" -eq 4096 ]; then ok "erase size 4096 (CONFIG_MTD_SPI_NOR_USE_4K_SECTORS)"; else bad "erase size $es: the driver only admits 4 KiB sector erases"; fi
    dev=$DEVDIR/$mtd
    if [ -e "$dev" ]; then ok "$dev present"; else bad "$dev missing"; fi
fi
al=$(tr -d '\0' < "$PROCFS/device-tree/aliases/nvram" 2>/dev/null || true)
if [ -n "$al" ]; then ok "DT alias nvram = $al"; else bad "no nvram alias in the live DT"; fi

echo "== dmesg"
dmesg 2>/dev/null | grep -i -E 'qspi|spi-nor|mtd|NVRAM' | tail -n 12 | sed 's/^/      /'
if dmesg 2>/dev/null | grep -q 'NVRAM write fault'; then bad "driver logged a write fault"; fi

if [ "$fail" -ne 0 ] || [ -z "${dev:-}" ]; then echo; echo "NOT READY: fix the FAIL lines before reading further"; exit 1; fi

echo "== read the partition twice"
dd if="$dev" of="$out/a.bin" bs=64k status=none && dd if="$dev" of="$out/b.bin" bs=64k status=none
if [ "$(stat -c %s "$out/a.bin" 2>/dev/null || wc -c < "$out/a.bin")" -eq "$EXPECT_SIZE" ]; then ok "dump is $EXPECT_SIZE bytes"; else bad "dump has the wrong size"; fi
if cmp -s "$out/a.bin" "$out/b.bin"; then ok "two reads identical"; else bad "two reads differ: unstable read path"; fi
sha=$(sha256sum "$out/a.bin" | cut -d' ' -f1)
info "sha256 $sha"
python3 -I "$HERE/v3-nvram.py" show "$out/a.bin" | head -n 2 | sed 's/^/      /'
if python3 -I "$HERE/v3-nvram.py" names "$out/a.bin" > "$out/names-dump.txt"; then ok "3VVN banks parse, CRCs valid ($(wc -l < "$out/names-dump.txt") variables)"; else bad "dump does not parse as 3VVN"; fi
if grep -qx boot-volume "$out/names-dump.txt"; then ok "boot-volume present"; else bad "boot-volume missing"; fi

echo "== asahi-nvram and asahi-bless (read subcommands only)"
if "$ASAHI_NVRAM" -d "$dev" read 2>/dev/null | cut -d= -f1 | sed 's/^[a-z]*://' | sort -u > "$out/names-tool.txt" && [ -s "$out/names-tool.txt" ]; then
    ok "asahi-nvram read lists $(wc -l < "$out/names-tool.txt") variables"
    if cmp -s "$out/names-tool.txt" <(sort -u "$out/names-dump.txt"); then ok "tool and dump agree on the variable names"; else bad "asahi-nvram and the dump disagree on names"; fi
else
    bad "asahi-nvram read failed (needs a build with the multi-bank parser, commit 70b16a2 or later)"
fi
for a in "--list-volumes" "--get-boot" "--get-boot --next"; do
    # shellcheck disable=SC2086
    if res=$("$ASAHI_BLESS" -d "$dev" $a 2>&1); then ok "asahi-bless $a"; printf '%s\n' "$res" | sed 's/^/        /'; else bad "asahi-bless $a: $res"; fi
done

if [ -n "$macos_names" ]; then
    echo "== names macOS showed, absent from the flash (informational: iBoot and macOS keep some in RAM)"
    sort -u "$macos_names" | comm -23 - "$out/names-dump.txt" | sed 's/^/      /'
fi

echo
if [ "$fail" -eq 0 ]; then
    { echo "dump_sha256=$sha"; echo "dev=$dev"; echo "jedec=$jedec"; echo "flash_status=$fs"; echo "kernel=$(uname -r)"; echo "time=$(date -u +%FT%TZ)"; echo "dir=$out"; } > "$STATE/probe.pass"
    echo "READ-ONLY TEST PASSED. Marker: $STATE/probe.pass. Dumps in $out (keep them off the repo)."
else
    echo "READ-ONLY TEST FAILED. No marker written."; exit 1
fi
