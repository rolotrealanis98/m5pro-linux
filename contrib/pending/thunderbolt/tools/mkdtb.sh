#!/bin/bash
# mkdtb.sh <tree> <board> <outdir>  -- dtc build like kbuild (cpp + dtc), no kernel config needed
set -e
T=$1; B=$2; O=$3; mkdir -p "$O"
D=$T/arch/arm64/boot/dts/apple
clang -E -nostdinc -I$D -I$T/scripts/dtc/include-prefixes -I$T/include -undef -D__DTS__ \
  -x assembler-with-cpp -o "$O/$B.dts.tmp" "$D/$B.dts"
dtc -O dtb -o "$O/$B.dtb" -b 0 -i$D -i$T/scripts/dtc/include-prefixes -Wno-unique_unit_address \
  -Wno-unit_address_vs_reg -Wno-avoid_unnecessary_addr_size -Wno-alias_paths \
  -Wno-simple_bus_reg -d "$O/$B.d" "$O/$B.dts.tmp"
shasum -a 256 "$O/$B.dtb"
