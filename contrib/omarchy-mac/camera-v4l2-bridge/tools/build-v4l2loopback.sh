#!/usr/bin/env bash
# Build and install the out-of-tree v4l2loopback module for the running kernel, when the distro has no package for it.
#   sudo tools/build-v4l2loopback.sh            # KDIR defaults to /usr/lib/modules/$(uname -r)/build
#   sudo KDIR=/path/to/prepared/kernel/tree tools/build-v4l2loopback.sh
# KDIR must be the build tree of THIS kernel (same .config, `make modules_prepare` done, same -dirty/localversion): the
# kernel is shipped without a build symlink, so this usually means a checkout of the kernel branch built on the Mac.
# Not run yet. Undo: rm /usr/lib/modules/$(uname -r)/extra/v4l2loopback.ko* && depmod -a
set -euo pipefail
VER=0.15.4 SHA=21a17702648aa6a937b88a93bd71ef9f547815ead28719cafcfcc247396643dc
KREL=$(uname -r); KDIR=${KDIR:-/usr/lib/modules/$KREL/build}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$KDIR/Makefile" ] && [ -f "$KDIR/.config" ] || { echo "no kernel build tree at $KDIR (set KDIR)" >&2; exit 1; }
grep -q '^CONFIG_VIDEO_DEV=[ym]' "$KDIR/.config" || { echo "CONFIG_VIDEO_DEV is not set in $KDIR/.config" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
curl -fsSL "https://github.com/umlaeute/v4l2loopback/archive/refs/tags/v$VER.tar.gz" -o "$W/src.tgz"
echo "$SHA  $W/src.tgz" | sha256sum -c -
tar -xzf "$W/src.tgz" -C "$W"
make -C "$W/v4l2loopback-$VER" KERNEL_DIR="$KDIR" v4l2loopback
install -Dm644 "$W/v4l2loopback-$VER/v4l2loopback.ko" "/usr/lib/modules/$KREL/extra/v4l2loopback.ko"
depmod -a "$KREL"
modinfo v4l2loopback | grep -E '^(filename|version|vermagic)'
