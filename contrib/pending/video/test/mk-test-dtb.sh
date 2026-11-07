#!/bin/bash
# mk-test-dtb.sh BASE.dtb OUT_DIR
# Appends j716s-video-test.dtsi.in to the decompiled BASE.dtb twice:
#   OUT_DIR/<base>-v1.dtb  AVD only (JPEG nodes disabled)
#   OUT_DIR/<base>-v2.dtb  AVD + both JPEG engines
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$1; OUT=$2; mkdir -p "$OUT"
NAME=$(basename "$BASE" .dtb)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
dtc -q -I dtb -O dts -o "$TMP/base.dts" "$BASE"
for v in v1 v2; do
  st='"disabled"'; [ $v = v2 ] && st='"okay"'
  { cat "$TMP/base.dts"; sed "s/JPEG_STATUS/$st/" "$HERE/j716s-video-test.dtsi.in"; } > "$TMP/$v.dts"
  dtc -q -I dts -O dtb -o "$OUT/$NAME-video-$v.dtb" "$TMP/$v.dts"
  echo "$OUT/$NAME-video-$v.dtb $(shasum -a 256 "$OUT/$NAME-video-$v.dtb" | cut -c1-8)"
done
