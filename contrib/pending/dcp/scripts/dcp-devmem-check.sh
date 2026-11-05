#!/bin/sh
# SPDX-License-Identifier: MIT
# dcp-devmem-check.sh - READ-ONLY check of the T6050 internal DCP against the
# addresses in t6050-dcp.dtsi. Runs on the J716s under the CURRENT kernel
# (simpledrm console), as root. It never writes: every access is "devmem ADDR 32"
# (the read form). Reads of registers in a powered domain have no side effects;
# disp_cpu/disp_fe/disp_sys are on while the panel shows the console.
#
# Usage: sh dcp-devmem-check.sh [path-to-devmem]   (default: devmem in PATH)
# devmem: omarchy-m5 tools/devmem.c (static build) or busybox devmem.
set -u
DM=${1:-devmem}
command -v "$DM" >/dev/null 2>&1 || [ -x "$DM" ] || { echo "no devmem tool: $DM" >&2; exit 2; }

rd() { "$DM" "$1" 32; }              # read form only: ADDR WIDTH, no VALUE
hex() { printf '0x%08x' "$1"; }

ASC=0x48ae00000      # dcp reg[0] ("coproc")
DART_DCP=0x48a340000 # dart-dcp
DART_DISP=0x48a300000

echo "== DCP ASC (expect CPU_CONTROL bit 4 RUN set: the iBoot session is live)"
v=$(rd $((ASC + 0x44))); echo "CPU_CONTROL @$(hex $((ASC + 0x44))) = $v"
[ $(( v & 0x10 )) -ne 0 ] && echo "  -> running" || echo "  -> NOT running (unexpected: panel is lit by DCP)"

dart() { # name base sid...
	name=$1; base=$2; shift 2
	p3=$(rd $((base + 0x08))); p4=$(rd $((base + 0x0c))); pr=$(rd $((base + 0x200)))
	echo "== $name @$(hex $base): PARAMS3=$p3 PARAMS4=$p4 (num_sids=$(( p4 & 0x1ff ))) PROTECT=$pr (bit0 = TTBR/TCR locked)"
	for sid in "$@"; do
		tcr=$(rd $((base + 0x1000 + 4 * sid))); ttbr=$(rd $((base + 0x1400 + 4 * sid)))
		pa=$(( (ttbr >> 2) << 14 ))
		printf '  sid %-2s TCR=%s (xlate=%d 4level=%d bypass=%d) TTBR=%s valid=%d l1-pa=0x%x\n' \
			"$sid" "$tcr" $(( tcr & 1 )) $(( (tcr >> 3) & 1 )) $(( (tcr >> 1) & 3 )) \
			"$ttbr" $(( ttbr & 1 )) "$pa"
	done
}
# ADT: dart-dcp l1-tt-23 0x10bffea0000, l1-tt-24 0x10bffe30000 (exclave)
dart dart-dcp $DART_DCP 23 24
# ADT: dart-disp0 l1-tt-0 0x10bffed0000, -16 0x10bffe20000, -3/-4 exclave
dart dart-disp0 $DART_DISP 0 16 3 4
echo "Compare the l1-pa values with the ADT pt-region/l1-tt numbers above; a"
echo "mismatch or 0xffffffff means the dtsi address is wrong. No register was written."
