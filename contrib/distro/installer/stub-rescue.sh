#!/bin/sh
# SPDX-License-Identifier: MIT
# stub-rescue.sh - put a known stage-1 back from a recovery Terminal, with no network and no
# second machine. The installer copies this script and the images it names to the stub System
# volume (/Volumes/<stub>/m1n1/), the way host/macos/stage1-install.sh:26 already keeps images there.
#
#   sh /Volumes/Omarchy/m1n1/rescue.sh list
#   sh /Volumes/Omarchy/m1n1/rescue.sh check
#   sh /Volumes/Omarchy/m1n1/rescue.sh install known-good    (or: proxy, pending)
#
# What "install" can and cannot do (m5pro-linux docs/boot-and-recovery.md:183-190):
#   - kmutil configure-boot only works from the stub's *paired* recoveryOS in 1TR. From the
#     "Options" recovery it fails with "Boot policy error: ... code pairing".
#   - So "install" first tries kmutil (works if you are already in the stub's paired 1TR, e.g.
#     step2's shell), and otherwise ARMS the install-media path: the image becomes the
#     Finish Installation.app's Resources/boot.bin, the .IAPhysicalMedia marker is restored and
#     SystemVersion.plist hidden, exactly as omarchy-m5 finish-install.sh:343-374 leaves it.
#     Then: shut down, HOLD power, pick the stub; its recoveryOS runs step2.sh
#     (bputil -nc + kmutil with that boot.bin).
#   - iBoot counts failed boots and only a completed macOS boot clears the count
#     (boot-and-recovery.md:137-142). If macOS still boots, prefer: boot macOS once, then run the
#     macOS-side repair. Use this script when macOS itself does not boot.
set -eu

app=$(ls -d /Volumes/*/"Finish Installation.app" 2>/dev/null | head -1 || true)
[ -n "$app" ] || { echo "Finish Installation.app not found under /Volumes:"; ls /Volumes; exit 1; }
res="$app/Contents/Resources"; sys="${app%/*}"; dir="$sys/m1n1"; cs="$sys/System/Library/CoreServices"
echo "stub System volume: $sys"

verify() {   # verify NAME: the image exists and matches SHA256SUMS written by the installer
    f="$dir/$1.bin"
    [ -f "$f" ] || { echo "no $f"; exit 1; }
    want=$(sed -n "s/^\([0-9a-f]\{64\}\)  $1\.bin\$/\1/p" "$dir/SHA256SUMS" 2>/dev/null | head -1)
    got=$(shasum -a 256 "$f" | cut -d' ' -f1)
    [ -n "$want" ] || { echo "$1.bin is not listed in $dir/SHA256SUMS; refusing"; exit 1; }
    [ "$want" = "$got" ] || { echo "$1.bin checksum mismatch ($got != $want); refusing"; exit 1; }
    size=$(stat -f %z "$f")
    [ $((size % 65536)) -eq 0 ] || { echo "$1.bin is $size bytes, not a 64 KiB multiple; refusing"; exit 1; }
    echo "$1.bin ok: $size bytes, sha256 $(echo "$got" | cut -c1-16)"
}

arm() {
    mount -u -w "$sys" 2>/dev/null || true
    [ -e "$cs/SystemVersion.plist" ] && mv -f "$cs/SystemVersion.plist" "$cs/SystemVersion-disabled.plist"
    [ -e "$sys/IAPhysicalMedia-disabled.plist" ] && mv -f "$sys/IAPhysicalMedia-disabled.plist" "$sys/.IAPhysicalMedia"
    [ -e "$sys/.IAPhysicalMedia" ] || { echo "could not restore $sys/.IAPhysicalMedia; run the macOS-side repair instead"; exit 1; }
    echo
    echo "Armed. Next: shut down (not restart), wait 10 s, HOLD power until 'Loading startup options',"
    echo "pick '$(basename "$sys")'. Its recoveryOS opens step2.sh, which asks for your macOS password twice."
}

case "${1:-list}" in
list)
    ls -l "$dir"/*.bin 2>/dev/null || echo "no images in $dir"
    [ -f "$dir/README.txt" ] && cat "$dir/README.txt" ;;
check)
    echo "Resources/boot.bin (what step2 installs):"; shasum -a 256 "$res/boot.bin"
    [ -f "$dir/SHA256SUMS" ] && { echo "known images:"; cat "$dir/SHA256SUMS"; }
    echo "markers:"
    for m in "$sys/.IAPhysicalMedia" "$sys/IAPhysicalMedia-disabled.plist" \
             "$cs/SystemVersion.plist" "$cs/SystemVersion-disabled.plist"; do
        [ -e "$m" ] && echo "  present: $m"
    done; true ;;
install)
    name=${2:?image name: known-good, proxy or pending}
    verify "$name"
    mount -u -w "$sys" 2>/dev/null || true
    cp "$dir/$name.bin" "$res/boot.bin" || { echo "could not write $res/boot.bin (read-only?)"; exit 1; }
    echo "Resources/boot.bin <- $name.bin"
    if kmutil configure-boot -c "$res/boot.bin" --raw --entry-point 2048 --lowest-virtual-address 0 -v "$sys"; then
        mount -u -w "$sys" 2>/dev/null || true
        [ -e "$sys/.IAPhysicalMedia" ] && mv "$sys/.IAPhysicalMedia" "$sys/IAPhysicalMedia-disabled.plist"
        [ -e "$cs/SystemVersion-disabled.plist" ] && mv -f "$cs/SystemVersion-disabled.plist" "$cs/SystemVersion.plist"
        echo "Installed $name as stage-1. Restart to use it."
    else
        echo "kmutil refused (not the stub's paired 1TR). Arming the install-media path instead."
        arm
    fi ;;
*) echo "usage: $0 list | check | install known-good|proxy|pending"; exit 2 ;;
esac
