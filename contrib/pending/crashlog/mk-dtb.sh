#!/bin/bash
# mk-dtb.sh SRC OUT.dtb - compile SRC/arch/arm64/boot/dts/apple/t6050-j716s.dts exactly as kbuild does
# (command replayed from wt-series-out/arch/arm64/boot/dts/apple/.t6050-j716s.dtb.cmd), with the
# kernel's own dtc. Works on a sparse worktree (only the DT include dirs are needed).
set -euo pipefail
SRC=$1; OUT=$2
DTC=/Volumes/linux-cs/wt-series-out/scripts/dtc/dtc
CLANG=/opt/homebrew/opt/llvm/bin/clang
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D=$SRC/arch/arm64/boot/dts/apple
"$CLANG" -E -Wp,-MMD,"$T/pre.d" -nostdinc -I "$SRC/scripts/dtc/include-prefixes" -undef -D__DTS__ \
    -x assembler-with-cpp -o "$T/dts.tmp" "$D/t6050-j716s.dts"
"$DTC" -o "$OUT" -b 0 -i"$D/" -i"$SRC/scripts/dtc/include-prefixes" -Wno-unique_unit_address \
    -Wno-unit_address_vs_reg -Wno-avoid_unnecessary_addr_size -Wno-alias_paths -Wno-interrupt_map \
    -Wno-simple_bus_reg -d "$T/dtc.d" "$T/dts.tmp"
shasum -a 256 "$OUT"
