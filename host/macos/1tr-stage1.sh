#!/bin/sh
# 1TR helper, served from the Studio. In the recovery Terminal (power-hold -> Options -> Utilities -> Terminal):
#   export STUDIO_IP=<studio-ip>      # the Studio's LAN address
#   sh <(curl -s $STUDIO_IP:8000/stage1.sh) <image>      e.g. probe-macosbuild | boot-plain | chain-esp-macosbuild
#   sh <(curl -s $STUDIO_IP:8000/stage1.sh) list
# Downloads the image, registers it as the stub's stage-1 boot object (kmutil asks for the macOS admin
# password), restores the stub markers and reboots. Rollback is the same command with boot-plain.
set -e
SRV=http://${STUDIO_IP:?export STUDIO_IP=<the Studio LAN address> first}:8000
img=${1:?image name, e.g. boot-plain}
if [ "$img" = list ]; then curl -s $SRV/ | sed -n 's/.*href="\([^"]*\.bin\)".*/\1/p'; exit 0; fi
app=$(ls -d /Volumes/*/"Finish Installation.app" 2>/dev/null | head -1)
[ -n "$app" ] || { echo "Finish Installation.app not found under /Volumes"; ls /Volumes; exit 1; }
res="$app/Contents/Resources"; sys="${app%/*}"
echo "stub system volume: $sys"
if [ "$img" = check ]; then
    echo "boot.bin on the stub:"; ls -l "$res/boot.bin"; shasum -a 256 "$res/boot.bin"
    echo "known: 5ddf1026 boot-plain | 312eeac8 probe-macosbuild | f4b379d7 probe-linuxbuild | 45a4bfa7 chain-esp-linuxbuild | b73fd5f4 chain-esp-macosbuild | see server for others"
    echo "markers:"; ls -la "$sys" | grep -iE 'IAPhysical'; ls -la "$sys/System/Library/CoreServices" | grep -i SystemVersion
    mount | grep "$sys"; exit 0
fi
curl -f -s -o /tmp/stage1.bin "$SRV/$img.bin" || { echo "download of $img.bin failed"; exit 1; }
ls -l /tmp/stage1.bin
mount -u -w "$sys" 2>/dev/null || true
mkdir -p "$sys/m1n1" 2>/dev/null && cp /tmp/stage1.bin "$sys/m1n1/$img.bin" 2>/dev/null || true
if cp /tmp/stage1.bin "$res/boot.bin"; then echo "boot.bin updated: $(shasum -a 256 "$res/boot.bin" | cut -c1-16)"; else
    echo "ERROR: could not write $res/boot.bin (volume read-only?) - step2 would install the OLD image. Stopping."; mount | grep "$sys"; exit 1; fi
cs="$sys/System/Library/CoreServices"
arm() {
    # Only the stub's *paired* recoveryOS may write its LocalPolicy ("code pairing" error otherwise).
    # Arm the install-media marker so that picking "Omarchy" in the picker boots that recovery and
    # auto-runs step2.sh (bputil -nc + kmutil with Resources/boot.bin = the image just copied).
    mount -u -w "$sys" 2>/dev/null || true
    [ -e "$cs/SystemVersion.plist" ] && mv -f "$cs/SystemVersion.plist" "$cs/SystemVersion-disabled.plist"
    [ -e "$sys/IAPhysicalMedia-disabled.plist" ] && mv -f "$sys/IAPhysicalMedia-disabled.plist" "$sys/.IAPhysicalMedia"
    echo "armed: $img is boot.bin. Rebooting in 5 s; then HOLD POWER -> pick Omarchy -> step2 runs the ceremony."
    sleep 5; reboot
}
if [ "${2:-}" = arm ]; then arm; fi
echo "kmutil will ask for your macOS admin password:"
if kmutil configure-boot -c /tmp/stage1.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v "$sys"; then
    mount -u -w "$sys" 2>/dev/null || true
    if [ -e "$sys/.IAPhysicalMedia" ]; then mv "$sys/.IAPhysicalMedia" "$sys/IAPhysicalMedia-disabled.plist"; fi
    if [ -e "$cs/SystemVersion-disabled.plist" ]; then mv -f "$cs/SystemVersion-disabled.plist" "$cs/SystemVersion.plist"; fi
    echo "installed $img as stage-1. Rebooting in 5 s."; sleep 5; reboot
else
    echo "kmutil refused (not the stub's paired recovery?) - arming the install-media path instead"; arm
fi
