#!/usr/bin/env bash
# install.sh - put the "macos-exact" feel on the MacBook for one user, or take it off again.
#   sudo contrib/omarchy-mac/macos-feel/install.sh --user NAME [--apply]     install (and switch to it)
#   sudo contrib/omarchy-mac/macos-feel/install.sh --user NAME --uninstall   back to the files it replaced
# Installs (user-level only; nothing under /etc, /boot or the kernel):
#   ~/.config/hypr/trackpad/{curves,macos-exact,select}.lua, switch-preset.sh  (from contrib/validated/desktop/trackpad/)
#   ~/.local/bin/macos-feel                                                     (from home/ here)
#   one hook line at the end of ~/.config/hypr/hyprland.lua (runs macos-exact after pointer-tuning.lua)
# Replaced files are kept once as <file>.before-macos-feel. select.lua keeps the active preset; --apply
# then runs `switch-preset.sh macos-exact` as the user (one `hyprctl reload`, plus `macos-feel desktop on`).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TP=$HERE/../../validated/desktop/trackpad/hypr/trackpad
USER_NAME=""; APPLY=0; UNINSTALL=0
while [ $# -gt 0 ]; do
  case $1 in
    --user) USER_NAME=$2; shift 2;;
    --apply) APPLY=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    *) sed -n '2,9p' "$0" >&2; exit 2;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$USER_NAME" ] || { echo "pass --user NAME" >&2; exit 2; }
H=$(getent passwd "$USER_NAME" | cut -d: -f6); UID_N=$(id -u "$USER_NAME")
HOOK='if M5PRO_TRACKPAD_LATE then M5PRO_TRACKPAD_LATE() end'
FILES=(".config/hypr/trackpad/curves.lua" ".config/hypr/trackpad/macos-exact.lua" ".config/hypr/trackpad/select.lua"
       ".config/hypr/trackpad/switch-preset.sh" ".local/bin/macos-feel")
as_user() {
  local sig; sig=$(ls -t "/run/user/$UID_N/hypr" 2>/dev/null | head -1 || true)
  runuser -u "$USER_NAME" -- env HOME="$H" XDG_RUNTIME_DIR="/run/user/$UID_N" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    PATH="$H/.local/bin:/usr/local/bin:/usr/bin" "$@"
}

if [ $UNINSTALL = 1 ]; then
  # Leave the preset first so the desktop settings come back, then restore the files.
  if [ -x "$H/.config/hypr/trackpad/switch-preset.sh" ] && grep -q '^local PRESET = "macos-exact"' "$H/.config/hypr/trackpad/select.lua"; then
    as_user "$H/.config/hypr/trackpad/switch-preset.sh" macos || true
  fi
  for f in "${FILES[@]}"; do
    if [ -e "$H/$f.before-macos-feel" ]; then mv "$H/$f.before-macos-feel" "$H/$f"; echo "restored ~/$f"
    elif [ -e "$H/$f" ]; then rm -f "$H/$f"; echo "removed ~/$f"; fi
  done
  sed -i "\#^-- A trackpad preset that must win over pointer-tuning.lua#d; \#^$HOOK\$#d" "$H/.config/hypr/hyprland.lua"
  echo "hook removed from ~/.config/hypr/hyprland.lua (takes effect at the next hyprctl reload)"
  exit 0
fi

put() { # src dst-relative mode
  local dst=$H/$2
  install -d -o "$USER_NAME" -g "$USER_NAME" "$(dirname "$dst")"
  [ -e "$dst" ] && [ ! -e "$dst.before-macos-feel" ] && cp -p "$dst" "$dst.before-macos-feel"
  install -o "$USER_NAME" -g "$USER_NAME" -m "$3" "$1" "$dst"
  echo "  ~/$2"
}
prev=$(sed -n 's/^local PRESET = "\(.*\)"/\1/p' "$H/.config/hypr/trackpad/select.lua" 2>/dev/null || true)
put "$TP/curves.lua" .config/hypr/trackpad/curves.lua 644
put "$TP/macos-exact.lua" .config/hypr/trackpad/macos-exact.lua 644
put "$TP/select.lua" .config/hypr/trackpad/select.lua 644
put "$TP/switch-preset.sh" .config/hypr/trackpad/switch-preset.sh 755
put "$HERE/home/.local/bin/macos-feel" .local/bin/macos-feel 755
[ -n "$prev" ] && sed -i "s/^local PRESET = \".*\"/local PRESET = \"$prev\"/" "$H/.config/hypr/trackpad/select.lua"
if ! grep -qxF "$HOOK" "$H/.config/hypr/hyprland.lua"; then
  [ -e "$H/.config/hypr/hyprland.lua.before-macos-feel" ] || cp -p "$H/.config/hypr/hyprland.lua" "$H/.config/hypr/hyprland.lua.before-macos-feel"
  printf -- '-- A trackpad preset that must win over pointer-tuning.lua (macos-exact) registers this in select.lua.\n%s\n' "$HOOK" >>"$H/.config/hypr/hyprland.lua"
  echo "  ~/.config/hypr/hyprland.lua (hook appended)"
fi
echo "active preset kept: ${prev:-macos}"
if [ $APPLY = 1 ]; then
  as_user "$H/.config/hypr/trackpad/switch-preset.sh" macos-exact
fi
