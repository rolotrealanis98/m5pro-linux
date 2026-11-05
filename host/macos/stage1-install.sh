#!/bin/bash
# SPDX-License-Identifier: MIT
# Run ON THE M5 in macOS: register IMAGE as the stub's stage-1 boot object (finish-install.sh, then
# the 1TR ceremony), and keep every image in ~/Work/m1n1/stage1/ on the stub System volume under
# /m1n1/ so a stage-1 that boot-loops can be swapped from a 1TR Terminal (power-hold -> Options ->
# Utilities -> Terminal) with one command, no macOS round trip:
#
#   kmutil configure-boot -c /Volumes/Omarchy/m1n1/boot-plain.bin --raw --entry-point 2048 \
#       --lowest-virtual-address 0 -v /Volumes/Omarchy
#
#   sudo host/macos/stage1-install.sh ~/Work/m1n1/stage1/boot-plain.bin
set -euo pipefail
OM=${OMARCHY_M5:-$HOME/Work/omarchy-m5}; SRC=$HOME/Work/m1n1/stage1; STUB_NAME=${STUB_NAME:-Omarchy}
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HOME_DIR=$(eval echo "~${SUDO_USER:-root}"); SRC=$HOME_DIR/Work/m1n1/stage1
IMG=${1:?image to install}; [ -f "$IMG" ] || { echo "no $IMG" >&2; exit 1; }
echo "installing $(basename "$IMG"): $(stat -f %z "$IMG") bytes, sha256 $(shasum -a 256 "$IMG" | cut -c1-16)..."
(cd "$OM" && scripts/finish-install.sh --m1n1 "$IMG")
SYS_VOL=$(diskutil apfs list -plist | python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read()); name = sys.argv[1]
for c in d["Containers"]:
    for v in c.get("Volumes", []):
        if "System" in v.get("Roles", []) and v.get("Name") == name: print(v["DeviceIdentifier"])' "$STUB_NAME")
MNT=$(diskutil info "$SYS_VOL" | awk -F': *' '/Mount Point/{print $2}')
mount -u -w "$MNT" 2>/dev/null || true
mkdir -p "$MNT/m1n1"; cp "$SRC"/*.bin "$MNT/m1n1/"; sync
echo; echo "images available from a 1TR Terminal at /Volumes/$STUB_NAME/m1n1/:"; ls -la "$MNT/m1n1/"
echo; echo "Next: sudo shutdown -h now; hold power -> Omarchy -> step2 -> enter to reboot."
