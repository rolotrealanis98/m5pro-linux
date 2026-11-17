#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# power-profiles: install omarchy-power-profiles-daemon 0.30-9 from Omarchy's edge repo (signed), or put 0.30-3 back.
#
#   sudo bash install.sh            install 0.30-9, restart the daemon, show the profiles
#   sudo bash install.sh --remove   reinstall the stable 0.30-3 from the pacman cache, restart the daemon
#
# Omarchy's stable repo (pkgs.omarchy.org/stable, both arches) still ships 0.30-3, which on the J716s probes neither
# CPU driver (no writable cpufreq boost switch) nor the CLPC platform profile (it only reads the ACPI file), so it
# falls back to the placeholder. 0.30-9 is the same PKGBUILD from omacom/omarchy-pkgs master (0c5eaedb87), built and
# signed by Omarchy on edge. pacman keeps it until stable publishes a newer pkgrel.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
PKG=omarchy-power-profiles-daemon-0.30-9-aarch64.pkg.tar.zst
SHA=b43dac2d14ffe364dffb3b603817f8bd8e47a7969dff7e8615ed6a8eef7338c5
OLD=/var/cache/pacman/pkg/omarchy-power-profiles-daemon-0.30-3-aarch64.pkg.tar.zst
DIR=/var/tmp/ppd-build

show() {
    systemctl is-active power-profiles-daemon
    powerprofilesctl
    grep . /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
}

if [ "${1:-}" = --remove ]; then
    [ -e "$OLD" ] || { echo "missing $OLD: pacman -Sw omarchy-power-profiles-daemon first" >&2; exit 1; }
    pacman -U --noconfirm "$OLD"
    systemctl restart power-profiles-daemon
    show
    exit 0
fi

mkdir -p "$DIR"
cd "$DIR"
for f in "$PKG" "$PKG.sig"; do
    [ -e "$f" ] || curl -fsSL -o "$f" "https://pkgs.omarchy.org/edge/aarch64/$f"
done
echo "$SHA  $PKG" | sha256sum -c -
pacman-key --verify "$PKG.sig" "$PKG"
pacman -U --noconfirm "$PKG"
systemctl restart power-profiles-daemon
sleep 2
show
