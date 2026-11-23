#!/usr/bin/env bash
# install.sh - airpods-control: put `airpods-mode` on the Mac. Idempotent; run as root.
#   sudo contrib/omarchy-mac/airpods-control/install.sh [--with-librepods] [--remove]
# Default: /usr/local/bin/airpods-mode, /usr/local/bin/airpods-daemon and the user unit /usr/lib/systemd/user/airpods-control.service
# (python3 stdlib; needs bluez-utils for bluetoothctl, dbus for dbus-monitor, all stock on Omarchy). The unit is NOT enabled here:
# the desktop user runs `systemctl --user enable --now airpods-control.service`. The Bluetooth panel part is shell/install-shell.sh (user, not root).
# --with-librepods: also build and install the LibrePods Qt tray app (librepods, librepods-ctl) with makepkg as the invoking user.
# The BlueZ DeviceID change is a separate step: bluez-deviceid.sh (not needed for noise control). Nothing is restarted here.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ITEM=$(basename "$HERE"); ROOT=$(dirname "$HERE")
with_lp=0; remove=0
for a in "$@"; do case $a in --with-librepods) with_lp=1;; --remove) remove=1;; *) echo "unknown option $a" >&2; exit 2;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
if [ $remove = 1 ]; then
  U=${SUDO_USER:-}
  if [ -n "$U" ] && [ "$U" != root ]; then  # best effort: stop and disable the user service for the invoking user
    sudo -u "$U" env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" systemctl --user disable --now airpods-control.service 2>/dev/null || true
  fi
  "$ROOT/install-item.sh" --remove "$ITEM"
  pacman -Q librepods >/dev/null 2>&1 && OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -R --noconfirm librepods
  exit 0
fi
command -v python3 >/dev/null || { echo "python3 missing" >&2; exit 1; }
command -v bluetoothctl >/dev/null || { echo "bluetoothctl missing: pacman -S --needed bluez-utils" >&2; exit 1; }
python3 -c 'import socket; socket.AF_BLUETOOTH; socket.BTPROTO_L2CAP' || { echo "this python has no Bluetooth sockets" >&2; exit 1; }
"$ROOT/install-item.sh" "$ITEM"
for f in /usr/local/bin/airpods-mode /usr/local/bin/airpods-daemon; do
  python3 -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" "$f" && echo "installed: $f"
done
command -v dbus-monitor >/dev/null || echo "note: dbus-monitor not found (pacman -S dbus); the daemon then polls BlueZ every 15 s"
echo "next, as the desktop user:  systemctl --user daemon-reload && systemctl --user enable --now airpods-control.service"
echo "(the daemon takes the one AAP connection: it replaces direct use, and airpods-mode then talks to it; close LibrePods first)"
if [ $with_lp = 1 ]; then
  U=${SUDO_USER:-}; [ -n "$U" ] && [ "$U" != root ] || { echo "--with-librepods needs sudo from a normal user (makepkg refuses root)" >&2; exit 1; }
  OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm base-devel git cmake qt6-base qt6-declarative qt6-connectivity qt6-multimedia qt6-tools openssl libpulse
  B=$(sudo -u "$U" mktemp -d /var/tmp/librepods-build.XXXXXX)
  sudo -u "$U" cp "$HERE/librepods/PKGBUILD" "$B/"
  ( cd "$B" && sudo -u "$U" makepkg -f --noconfirm )
  OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -U --noconfirm "$B"/librepods-*.pkg.tar.*
  rm -rf "$B"
  echo "librepods installed. Start it with: librepods --hide   (control it with: librepods-ctl noise:anc)"
fi
