#!/usr/bin/env bash
# mk-source.sh PKGDIR - make the source tarball a package here builds its files from: the exact repo files the Mac relies on,
# nothing else. Run in the repo; prints the sha256 for the PKGBUILD. Deterministic (sorted, mtime 0, root owner).
#   ./mk-source.sh omarchy-mac-t6050      -> omarchy-mac-t6050/m5pro-contrib-src.tar.zst
#   ./mk-source.sh aurora-audio-j716      -> aurora-audio-j716/m5pro-contrib-src.tar.zst
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
pkg=${1:?package dir}
case $pkg in
  omarchy-mac-t6050) paths=(contrib/omarchy-mac/dmesg-unrestricted/files contrib/omarchy-mac/xhci-wakeup/files
                            contrib/omarchy-mac/lid-sleep-s2idle/files contrib/omarchy-mac/module-config/files
                            contrib/omarchy-mac/audio-realtime/25-m5pro-audio-rt.conf) ;;
  aurora-audio-j716) paths=(contrib/omarchy-mac/mic-array/files contrib/validated/desktop/audio/ucm
                            contrib/validated/desktop/audio/wireplumber) ;;
  *) echo "unknown package $pkg" >&2; exit 2 ;;
esac
for p in "${paths[@]}"; do [[ -e $REPO/$p ]] || { echo "missing in the repo: $p" >&2; exit 1; }; done
out=$HERE/$pkg/m5pro-contrib-src.tar.zst
cd "$REPO"
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  find "${paths[@]}" -type f -print0 | sort -z | tar --null -T - --owner=0 --group=0 --numeric-owner --mtime='@0' -cf - | zstd -q -19 -o "$out" -f
else   # bsdtar (macOS): ownership fixed, mtimes are the files' own
  find "${paths[@]}" -type f -print0 | sort -z | tar --null -T - --uid 0 --gid 0 --numeric -cf - | zstd -q -19 -o "$out" -f
fi
echo "$out"; sha256sum "$out" 2>/dev/null || shasum -a 256 "$out"
