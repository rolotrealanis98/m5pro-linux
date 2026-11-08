#!/usr/bin/env bash
# Install the gl2 tree (/opt/mesa-aurora-gl2) on the MacBook. Copies the
# tarball, checks its SHA-256, unpacks it next to the current tree and verifies
# the files. Changes nothing else: /opt/mesa-aurora-gl, /opt/mesa-aurora and
# /etc/mesa-aurora/session.env stay as they are; no session change.
#   install-gl2.sh root@100.99.249.67 [tarball.tar.zst]
# Env: SSH_OPTS (default: -i ~/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes)
set -euo pipefail
HOST=${1:?usage: install-gl2.sh root@host [tarball.tar.zst]}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/../out}
TARBALL=${2:-$(ls -t "$OUT"/mesa-aurora-gl2-*.tar.zst | head -1)}
TB=$(basename "$TARBALL")
SUMS=$OUT/SHA256SUMS
ENVF=$HERE/session-gl2.env
read -r -a SSHO <<< "${SSH_OPTS:--i $HOME/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes}"
[[ -f $TARBALL && -f $SUMS && -f $ENVF ]] || { echo "missing tarball, $SUMS or $ENVF" >&2; exit 1; }

echo "== local checksum"
(cd "$(dirname "$TARBALL")" && grep -F "  $TB" "$SUMS" | shasum -a 256 -c -)

echo "== copy to $HOST:/root"
grep -F "  $TB" "$SUMS" > "${TMPDIR:-/tmp}/gl2.SHA256SUMS.$$"
scp "${SSHO[@]}" "$TARBALL" "$ENVF" "$HOST:/root/" >/dev/null
scp "${SSHO[@]}" "${TMPDIR:-/tmp}/gl2.SHA256SUMS.$$" "$HOST:/root/gl2.SHA256SUMS" >/dev/null
rm -f "${TMPDIR:-/tmp}/gl2.SHA256SUMS.$$"

echo "== unpack and verify on $HOST"
ssh "${SSHO[@]}" "$HOST" TB="$TB" bash -s <<'REMOTE'
set -euo pipefail
P=/opt/mesa-aurora-gl2
cd /root
sha256sum -c gl2.SHA256SUMS
before=$(cat /opt/mesa-aurora-gl/MESA_COMMIT 2>/dev/null || echo none)
stage=$(mktemp -d /opt/.gl2-stage.XXXXXX)
trap 'rm -rf "$stage"' EXIT
tar --zstd -C "$stage" -xf "/root/$TB"
[[ -d $stage/mesa-aurora-gl2 ]] || { echo "tarball does not unpack to mesa-aurora-gl2" >&2; exit 1; }
rm -rf "$P.old"; [[ -d $P ]] && mv "$P" "$P.old"
mv "$stage/mesa-aurora-gl2" "$P"
rm -rf "$P.old"

fail=0; chk() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
chk "MESA_COMMIT present" "[[ -s $P/MESA_COMMIT ]]"
for f in lib/libgallium-*.so lib/libEGL_aurora.so.0 lib/libGLX_aurora.so.0 lib/libgbm.so.1 lib/libvulkan_asahi.so \
         lib/libasahi_noop_drm_shim.so lib/dri/asahi_dri.so \
         share/glvnd/egl_vendor.d/50_aurora.json share/vulkan/icd.d/asahi_icd.aarch64.json; do
  chk "$f" "ls $P/$f >/dev/null 2>&1"
done
chk "egl vendor json points at gl2" "grep -q '$P/lib/libEGL_aurora.so.0' $P/share/glvnd/egl_vendor.d/50_aurora.json"
chk "vulkan icd json points at gl2" "grep -q '$P/lib/libvulkan_asahi.so' $P/share/vulkan/icd.d/asahi_icd.aarch64.json"
chk "no JSON file names the other tree" "! grep -rEl '/opt/mesa-aurora-gl(/|\")' $P/share --include='*.json'"
chk "no library hardcodes the other tree" "! grep -rlE '/opt/mesa-aurora-gl/' $P/lib 2>/dev/null | grep -q ."
chk "libraries resolve (no 'not found')" "! LD_LIBRARY_PATH=$P/lib ldd $P/lib/libEGL_aurora.so.0 $P/lib/libgallium-*.so $P/lib/libvulkan_asahi.so 2>&1 | grep -q 'not found'"
after=$(cat /opt/mesa-aurora-gl/MESA_COMMIT 2>/dev/null || echo none)
chk "/opt/mesa-aurora-gl untouched ($before)" "[[ $before == $after ]]"
install -Dm644 /root/session-gl2.env /usr/local/share/mesa-aurora/session-gl2.env
echo "gl2 commit: $(cat $P/MESA_COMMIT)"
[[ $fail == 0 ]] || { echo "VERIFY FAILED" >&2; exit 1; }
echo "VERIFY OK: $P installed; /opt/mesa-aurora-gl and /etc/mesa-aurora/session.env not touched (no session change)"
REMOTE
echo "env file for one-process use: $HOST:/usr/local/share/mesa-aurora/session-gl2.env (the session env /etc/mesa-aurora/session.env is untouched)"
