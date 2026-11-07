#!/bin/bash
# Host test of m1n1 0026's dt_set_gpu_t6050() against the private J716s ADT and a J716s DTB.
# Copies the few m1n1 sources it needs into ./src (with host stubs for types.h/utils.h: no MMIO), builds with
# ASan/UBSan, runs. Writes only inside this directory. Usage: run-test.sh <dtb> [chosen value] [out.dtb]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); M=$HERE/../m1n1/src; S=$HERE/src
rm -rf "$S"; mkdir -p "$S"
cp $M/pmgr.c $M/pmgr.h $M/xnuboot.h "$S"/; cp -R $M/libfdt "$S"/
cp $HERE/stub/adt-c-legacy.c "$S"/adt.c; cp $HERE/stub/adt-legacy.h "$S"/adt.h   # m1n1 C ADT code before its Rust port (same API)
sed -e "/^typedef u64 uintptr_t;/d" -e "/^typedef s64 ptrdiff_t;/d" -e "/^typedef s64 ssize_t;/d" $M/types.h > "$S"/types.h
cp $HERE/stub/utils.h "$S"/utils.h
awk '/^#define T6050_GPU_PFX/{p=1} /^int dt_set_gpu\(void \*dt\)/{p=0} p' $M/kboot_gpu.c > "$S"/t6050-extract.inc
clang -std=gnu11 -O1 -g -fsanitize=address,undefined -Wall -Wno-format -I"$S" -I"$S"/libfdt -o $HERE/test-t6050 \
    $HERE/test-t6050.c "$S"/adt.c "$S"/pmgr.c "$S"/libfdt/fdt.c "$S"/libfdt/fdt_ro.c "$S"/libfdt/fdt_rw.c \
    "$S"/libfdt/fdt_wip.c "$S"/libfdt/fdt_strerror.c "$S"/libfdt/fdt_addresses.c
$HERE/test-t6050 ~/Work/studio-artifacts/adt-runtime-j716s.bin "$1" ${2:-} ${3:-}
