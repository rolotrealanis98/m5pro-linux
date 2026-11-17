#!/bin/bash
# camera-v4l2-bridge: put the on-demand clean-camera V4L2 device on the MacBook, or take it off.
#   sudo bash install.sh [USER] [--dry-run] [--force]     install (USER defaults to the logged-in desktop user)
#   sudo bash install.sh --uninstall [USER] [--dry-run]   remove (packages and the v4l2loopback module stay installed)
# Idempotent. Files that exist and differ are kept once as <file>.before-camera-v4l2-bridge. /etc/m5pro-camera-v4l2-bridge.conf is
# a settings file: it is installed only when absent and an uninstall keeps it if it was edited. --force installs even
# when a prerequisite is missing. Prerequisites are never installed here (see README.md).
set -euo pipefail
cd "$(dirname "$0")"
UN=0; DRY=0; FORCE=0; U=""
for a in "$@"; do case $a in
  --uninstall) UN=1;; --dry-run) DRY=1;; --force) FORCE=1;; -h|--help) sed -n '2,7p' "$0"; exit 0;;
  -*) echo "unknown option $a" >&2; exit 2;; *) U=$a;; esac; done
[ $DRY = 1 ] || [ "$(id -u)" = 0 ] || { echo "run as root (or --dry-run)" >&2; exit 1; }
U=${U:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "root" && $3 != "" {print $3; exit}')}
[ -n "$U" ] && id "$U" >/dev/null 2>&1 || { echo "no desktop user found: pass USER" >&2; exit 1; }
UID_=$(id -u "$U")
SFX=.before-camera-v4l2-bridge
FILES=$(cd files && find . -type f | sed 's|^\.||' | sort)
run() { if [ $DRY = 1 ]; then echo "  would: $*"; else "$@"; fi; }
as_user() { run runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus "$@"; }

if [ $UN = 1 ]; then
  as_user systemctl --user disable --now m5pro-camera-v4l2-bridge.service || true
  run systemctl --global disable m5pro-camera-v4l2-bridge.service || true
  for f in $FILES; do
    if [ "$f" = /etc/m5pro-camera-v4l2-bridge.conf ] && [ -e "$f" ] && ! cmp -s "files$f" "$f"; then
      echo "  keep $f (edited)"; continue; fi
    [ -e "$f" ] && { echo "  rm $f"; run rm -f "$f"; }
    [ -e "$f$SFX" ] && run mv "$f$SFX" "$f"
  done
  as_user systemctl --user daemon-reload || true
  if lsmod | grep -q '^v4l2loopback ' && [ "$(lsmod | awk '$1=="v4l2loopback"{print $3}')" = 0 ]; then run modprobe -r v4l2loopback || true; fi
  echo "removed. Left alone: v4l2-relayd / v4l2loopback packages and module."; exit 0
fi

# prerequisites
missing=()
modinfo v4l2loopback >/dev/null 2>&1 || missing+=("kernel module v4l2loopback (tools/build-v4l2loopback.sh, or v4l2loopback-dkms where the kernel has headers)")
command -v v4l2-relayd >/dev/null || missing+=("v4l2-relayd (makepkg -si in pkg/)")
command -v jq >/dev/null || missing+=("jq (pacman -S jq)")
command -v pw-dump >/dev/null || missing+=("pw-dump (pacman -S pipewire)")
gst-inspect-1.0 pipewiresrc >/dev/null 2>&1 || missing+=("GStreamer pipewiresrc (pacman -S gst-plugin-pipewire)")
pacman -Q aurora-camera-denoise >/dev/null 2>&1 || missing+=("aurora-camera-denoise (../camera-denoise/README.md)")
if [ ${#missing[@]} -gt 0 ]; then
  printf 'missing: %s\n' "${missing[@]}" >&2
  [ $FORCE = 1 ] || { echo "install them first, or pass --force" >&2; exit 1; }
fi
if grep -rls 'v4l2loopback' /etc/modprobe.d 2>/dev/null | grep -v m5pro-camera-v4l2-bridge | grep -q .; then
  echo "warning: another /etc/modprobe.d file sets v4l2loopback options; the options are global, check them" >&2
fi

for f in $FILES; do
  if [ "$f" = /etc/m5pro-camera-v4l2-bridge.conf ] && [ -e "$f" ]; then echo "  keep $f (settings)"; continue; fi
  if [ -e "$f" ] && cmp -s "files$f" "$f"; then echo "  same $f"; continue; fi
  echo "  $f"
  [ -e "$f" ] && [ ! -e "$f$SFX" ] && run cp -p "$f" "$f$SFX"
  run install -D -m "$(stat -c %a "files$f")" "files$f" "$f"
done
run systemctl --global enable m5pro-camera-v4l2-bridge.service
if ! lsmod | grep -q '^v4l2loopback '; then run modprobe v4l2loopback || echo "modprobe v4l2loopback failed" >&2
elif ! grep -q 'FaceTime HD Camera (Clean)' /sys/devices/virtual/video4linux/*/name 2>/dev/null; then
  echo "v4l2loopback is loaded with other options: unload it (modprobe -r v4l2loopback) or reboot, then start the service" >&2
fi
as_user systemctl --user daemon-reload
as_user systemctl --user restart m5pro-camera-v4l2-bridge.service
echo "installed for $U. Restart WirePlumber once so it applies the hide rule: systemctl --user restart wireplumber"
echo "check: journalctl --user -u m5pro-camera-v4l2-bridge -n 20; test plan: /Volumes/m5pro/bench/requests/camera-2.md (camera-v4l2-bridge)"
