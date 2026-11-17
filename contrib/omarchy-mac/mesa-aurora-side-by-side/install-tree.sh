#!/usr/bin/env bash
# Put a staged Aurora Mesa tree on the MacBook SIDE BY SIDE (new /opt/mesa-aurora-<date>), changing nothing else:
# no session env, no pacman, no /usr. Refuses to overwrite an existing prefix.
#   install-tree.sh root@MACBOOK /path/mesa-aurora-20261117.tar.zst   (SSH_OPTS env for the key)
# Undo: rm -rf /opt/mesa-aurora-20261117 /home/<user>/gpu-ab
set -euo pipefail
HOST=${1:?host}; TB=${2:?tarball}; NAME=$(basename "$TB" .tar.zst)
read -r -a SSHO <<< "${SSH_OPTS:--i $HOME/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes}"
[[ -f ${TB%/*}/SHA256SUMS ]] && (cd "$(dirname "$TB")" && grep -F "  $(basename "$TB")" SHA256SUMS | shasum -a 256 -c -)
scp "${SSHO[@]}" "$TB" "$HOST:/root/" >/dev/null
ssh "${SSHO[@]}" "$HOST" NAME="$NAME" bash -s <<'REMOTE'
set -euo pipefail
P=/opt/$NAME; [[ ! -e $P ]] || { echo "$P exists; not touching it" >&2; exit 1; }
st=$(mktemp -d /opt/.stage.XXXXXX); trap 'rm -rf "$st"' EXIT
tar --zstd -C "$st" -xf /root/$NAME.tar.zst; mv "$st/$NAME" "$P"
for f in lib/libgallium-*.so lib/libEGL_aurora.so.0 lib/libGLX_aurora.so.0 lib/libgbm.so.1 lib/libvulkan_asahi.so \
         share/glvnd/egl_vendor.d/50_aurora.json share/vulkan/icd.d/asahi_icd.aarch64.json MESA_COMMIT; do
  ls $P/$f >/dev/null 2>&1 && echo "ok   $f" || { echo "FAIL $f"; exit 1; }
done
grep -q "$P/lib" $P/share/vulkan/icd.d/asahi_icd.aarch64.json && echo "ok   ICD json points at $P"
! LD_LIBRARY_PATH=$P/lib ldd $P/lib/libvulkan_asahi.so $P/lib/libgallium-*.so $P/lib/libEGL_aurora.so.0 | grep -q "not found" && echo "ok   libraries resolve"
echo "installed $P commit $(cat $P/MESA_COMMIT); nothing else changed"
REMOTE
