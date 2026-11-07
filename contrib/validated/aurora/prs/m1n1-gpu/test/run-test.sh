#!/bin/bash
# Host test of pr/t6050-gpu-handoff's dt_set_gpu_t6050() against the private J716s runtime ADT and a J716s DTB
# (adapted from gpu-e1/test). Copies the m1n1 sources it needs into ./src with host stubs (no MMIO), builds with
# ASan/UBSan, runs. Writes only inside this directory. Usage: run-test.sh <dtb> <mode> [out.dtb]
#   modes: asis | enable (gpu + pmgr_gfx okay) | bad-sgx | bad-role | bad-irq | one-mbox
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); M=${M1N1_SRC:-$HERE/../tree/src}; S=$HERE/src   # M1N1_SRC: a pr/t6050-gpu-handoff src/
rm -rf "$S"; mkdir -p "$S"
cp $M/xnuboot.h "$S"/; cp -R $M/libfdt "$S"/
cp $HERE/stub/legacy-c-adt.c "$S"/adt.c; cp $HERE/stub/legacy-c-adt.h "$S"/adt.h
sed -e "/^typedef u64 uintptr_t;/d" -e "/^typedef s64 ptrdiff_t;/d" -e "/^typedef s64 ssize_t;/d" $M/types.h > "$S"/types.h
cp $HERE/stub/utils.h "$S"/utils.h
{ awk '/^#define bail\(/{p=1} p{print} p&&/while \(0\)/{exit}' $M/kboot_gpu.c
  awk '/^static int dt_set_resvmem\(/{p=1} p{print} p&&/^}/{exit}' $M/kboot_gpu.c
  awk '/^static int g15_dt_reg_by_name\(/{p=1} p{print} p&&/^}/{exit}' $M/kboot_gpu.c
  awk '/^ \* T6050 \(M5 Pro, G17S\)\./{p=1; print "/*"} /^int dt_set_gpu_m4\(void \*dt\);/{p=0} p' $M/kboot_gpu.c
} > "$S"/t6050-extract.inc
clang -std=gnu11 -O1 -g -fsanitize=address,undefined -Wall -Wno-format -I"$S" -I"$S"/libfdt -o $HERE/test-t6050 \
    $HERE/test-t6050.c "$S"/adt.c "$S"/libfdt/fdt.c "$S"/libfdt/fdt_ro.c "$S"/libfdt/fdt_rw.c \
    "$S"/libfdt/fdt_wip.c "$S"/libfdt/fdt_strerror.c "$S"/libfdt/fdt_addresses.c
$HERE/test-t6050 ~/Work/studio-artifacts/adt-runtime-j716s.bin "$1" "$2" ${3:-}
