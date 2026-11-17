#!/usr/bin/env bash
# Build alarm-aurora's libva-v4l2-request-avd recipe with the Chrome AV1 fixes (alarm-aurora#330 =
# omacom/libva-v4l2_request#114) in an Arch Linux ARM container on the Studio (Apple `container`).
# Adds provides/conflicts/replaces for Omarchy's `libva-v4l2_request-avd` so it can replace it with pacman -U.
#
#   RECIPE=/Volumes/m5pro/bench/avd/libva-av1/recipe OUT=/Volumes/m5pro/bench/avd/libva-av1/out build-libva-avd.sh
# RECIPE holds PKGBUILD + 000{1,2,3}-*.patch from alarm-aurora packages/libva-v4l2-request-avd at PR #330's head
# (a872d7ac5d3d). Output: OUT/*.pkg.tar.*, OUT/opt/libva-avd-av1/dri/*.so (side-by-side copy), OUT/*.log
set -euo pipefail
NAME=${NAME:-avd-libva-1}
RECIPE=${RECIPE:?}; OUT=${OUT:?}
mkdir -p "$OUT"
container list 2>/dev/null | grep -q "^$NAME " || {
  container run -d --name "$NAME" -m 4g -c 6 -v "$RECIPE:/recipe" -v "$OUT:/out" menci/archlinuxarm:base-devel sleep infinity >/dev/null
  container exec "$NAME" bash -c '
    sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
    pacman-key --init >/dev/null; pacman-key --populate archlinuxarm >/dev/null
    pacman -Syu --noconfirm --needed meson ninja pkgconf linux-api-headers libva libdrm git >/dev/null
    id b >/dev/null 2>&1 || useradd -m b'; }
container exec "$NAME" bash -c '
set -euo pipefail
rm -rf /home/b/pkg; cp -r /recipe /home/b/pkg; cd /home/b/pkg
sed -i "s/^depends=.*/&\nprovides=(\"libva-v4l2_request-avd\")\nconflicts=(\"libva-v4l2_request-avd\")\nreplaces=(\"libva-v4l2_request-avd\")/" PKGBUILD
chown -R b:b /home/b/pkg
runuser -u b -- makepkg -f --noconfirm >/out/makepkg.log 2>&1
cp -f *.pkg.tar.* /out/
rm -rf /out/opt; mkdir -p /out/opt/libva-avd-av1/dri
cp pkg/libva-v4l2-request-avd/usr/lib/dri/v4l2_request_drv_video.so /out/opt/libva-avd-av1/dri/
(cd /out && sha256sum *.pkg.tar.* opt/libva-avd-av1/dri/*.so > SHA256SUMS)
grep -E "^(Ok|Fail|Expected|Skipped|Timeout):" /out/makepkg.log || true
echo built'
