#!/usr/bin/env bash
# Stage the firmware named in CONFIG_EXTRA_FIRMWARE into EXTRA_FIRMWARE_DIR.
# Usage: stage-wireless-fw.sh <linux-firmware checkout> <wireless-regdb checkout> [embed-fragment] [dest]
# Copies uncompressed files only (EXTRA_FIRMWARE cannot read .zst/.xz).
set -euo pipefail
LF=${1:?linux-firmware checkout}
REGDB=${2:?wireless-regdb checkout}
FRAG=${3:-$(dirname "$0")/../configs/omarchy-wireless-embed-fw.config}
LIST=$(sed -n 's/^CONFIG_EXTRA_FIRMWARE="\(.*\)"$/\1/p' "$FRAG")
DEST=${4:-$(sed -n 's/^CONFIG_EXTRA_FIRMWARE_DIR="\(.*\)"$/\1/p' "$FRAG")}
[ -n "$LIST" ] && [ -n "$DEST" ] || { echo "no EXTRA_FIRMWARE list/dir in $FRAG" >&2; exit 1; }
for f in $LIST; do
    case "$f" in
        regulatory.db|regulatory.db.p7s) src="$REGDB/$f" ;;
        *) src="$LF/$f" ;;
    esac
    # A git checkout of linux-firmware lacks the WHENCE "Link:" names that
    # `make install` creates (e.g. mt7662.bin -> mediatek/mt7662.bin).
    if [ ! -e "$src" ] && [ -f "$LF/WHENCE" ]; then
        tgt=$(sed -n "s|^Link: $f -> ||p" "$LF/WHENCE" | head -1)
        [ -n "$tgt" ] && src="$LF/$(dirname "$f")/$tgt"
    fi
    [ -e "$src" ] || { echo "missing $src" >&2; exit 1; }
    install -D -m 0644 "$(readlink -f "$src" 2>/dev/null || echo "$src")" "$DEST/$f"
    echo "staged $f ($(wc -c < "$DEST/$f") bytes)"
done
