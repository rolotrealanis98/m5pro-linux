#!/bin/bash
# mk-tb-ladder.sh <tree> <outdir>  -- the round 2 bisect DTBs (K0, D1, D2, D3, T0) from dt/round2/t6050-j716s-tb-ladder.dts,
# built like kbuild (cpp + dtc, no kernel config needed) on <tree>'s in-tree t6050-j716s.dts (branch j716s-tb-r2: the daily
# + the Thunderbolt stack + the round 2 DT fix). Prints the sha256 of each. T0 (level 4) must equal the plain in-tree DTB,
# which is built last with the same host tools so that the container-built one can be compared with it.
set -e
T=$1; O=$2; mkdir -p "$O"
H=$(cd "$(dirname "$0")/.." && pwd); SRC=$H/dt/round2/t6050-j716s-tb-ladder.dts
D=$T/arch/arm64/boot/dts/apple
CPP="clang -E -nostdinc -I$D -I$T/scripts/dtc/include-prefixes -I$T/include -undef -D__DTS__ -x assembler-with-cpp"
DTC="dtc -O dtb -b 0 -i$D -i$T/scripts/dtc/include-prefixes -Wno-unique_unit_address -Wno-unit_address_vs_reg \
     -Wno-avoid_unnecessary_addr_size -Wno-alias_paths -Wno-simple_bus_reg"
i=0
for n in k0 d1 d2 d3 t0; do
  B=t6050-j716s-tb-$n
  $CPP -DTB_LEVEL=$i -o "$O/$B.dts.tmp" "$SRC"
  $DTC -o "$O/$B.dtb" "$O/$B.dts.tmp"
  shasum -a 256 "$O/$B.dtb"
  i=$((i+1))
done
$CPP -o "$O/t6050-j716s-intree.dts.tmp" "$D/t6050-j716s.dts"
$DTC -o "$O/t6050-j716s-intree.dtb" "$O/t6050-j716s-intree.dts.tmp"
shasum -a 256 "$O/t6050-j716s-intree.dtb"
cmp "$O/t6050-j716s-tb-t0.dtb" "$O/t6050-j716s-intree.dtb" && echo "T0 == in-tree DTB"
