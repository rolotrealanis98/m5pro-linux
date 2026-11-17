#!/usr/bin/env bash
# install.sh - put the macOS profile of the Pointer panel (rolo.pointer) on the MacBook for one user.
#   sudo contrib/omarchy-mac/macos-feel/install.sh --user NAME [--macos]     install (and switch the panel to macOS)
#   sudo contrib/omarchy-mac/macos-feel/install.sh --user NAME --uninstall   back to the files it replaced
# Installs (user-level only):
#   ~/.config/omarchy/plugins/rolo.pointer/{Panel.qml,apply-pointer.py,manifest.json}  (contrib/omarchy-mac/plugin-rolo-pointer/)
#   ~/.config/hypr/trackpad/curves.lua                                                (contrib/validated/desktop/trackpad/)
#   ~/.local/bin/macos-feel                                                           (home/ here)
# and converts ~/.config/hypr/pointer-tuning.json to the two-profile format (the old values become
# the "custom" profile). It also removes the earlier macos-exact preset and its hyprland.lua hook
# (2026-11-17), so the panel is the only source of pointer settings. Replaced files are kept once as
# <file>.before-macos-profile. Hyprland's auto-reload is held off while files change, then one
# `hyprctl reload` applies everything.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TP=$HERE/../../validated/desktop/trackpad/hypr/trackpad
PLUGIN=$HERE/../plugin-rolo-pointer/home/.config/omarchy/plugins/rolo.pointer
USER_NAME=""; MACOS=0; UNINSTALL=0
while [ $# -gt 0 ]; do
  case $1 in
    --user) USER_NAME=$2; shift 2;;
    --macos) MACOS=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    *) sed -n '2,13p' "$0" >&2; exit 2;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$USER_NAME" ] || { echo "pass --user NAME" >&2; exit 2; }
H=$(getent passwd "$USER_NAME" | cut -d: -f6); UID_N=$(id -u "$USER_NAME")
B=.before-macos-profile
FILES=(".config/omarchy/plugins/rolo.pointer/Panel.qml" ".config/omarchy/plugins/rolo.pointer/apply-pointer.py"
       ".config/omarchy/plugins/rolo.pointer/manifest.json" ".config/hypr/trackpad/curves.lua" ".local/bin/macos-feel"
       ".config/hypr/pointer-tuning.json" ".config/hypr/pointer-tuning.lua")
as_user() {
  local sig; sig=$(ls -t "/run/user/$UID_N/hypr" 2>/dev/null | head -1 || true)
  runuser -u "$USER_NAME" -- env HOME="$H" XDG_RUNTIME_DIR="/run/user/$UID_N" XCURSOR_THEME=Adwaita \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    PATH="$H/.local/bin:/usr/local/bin:/usr/bin" "$@"
}
hold_reload() { as_user hyprctl eval 'hl.config({ misc = { disable_autoreload = true } })' >/dev/null 2>&1 || true; }

hold_reload
if [ $UNINSTALL = 1 ]; then
  as_user "$H/.local/bin/macos-feel" desktop off 2>/dev/null || true
  for f in "${FILES[@]}"; do
    if [ -e "$H/$f$B" ]; then mv "$H/$f$B" "$H/$f"; echo "restored ~/$f"; fi
  done
else
  put() { # src dst-relative mode
    local dst=$H/$2
    install -d -o "$USER_NAME" -g "$USER_NAME" "$(dirname "$dst")"
    [ -e "$dst" ] && [ ! -e "$dst$B" ] && cp -p "$dst" "$dst$B"
    install -o "$USER_NAME" -g "$USER_NAME" -m "$3" "$1" "$dst"
    echo "  ~/$2"
  }
  for f in .config/hypr/pointer-tuning.json .config/hypr/pointer-tuning.lua; do
    [ -e "$H/$f" ] && [ ! -e "$H/$f$B" ] && cp -p "$H/$f" "$H/$f$B"
  done
  put "$PLUGIN/Panel.qml" .config/omarchy/plugins/rolo.pointer/Panel.qml 644
  put "$PLUGIN/apply-pointer.py" .config/omarchy/plugins/rolo.pointer/apply-pointer.py 755
  put "$PLUGIN/manifest.json" .config/omarchy/plugins/rolo.pointer/manifest.json 644
  put "$TP/curves.lua" .config/hypr/trackpad/curves.lua 644
  put "$HERE/home/.local/bin/macos-feel" .local/bin/macos-feel 755
  # Retire the earlier macos-exact preset: the panel's macOS profile replaces it.
  if grep -q 'M5PRO_TRACKPAD_LATE' "$H/.config/hypr/hyprland.lua"; then
    cp -p "$H/.config/hypr/hyprland.lua" "$H/.config/hypr/hyprland.lua$B"
    sed -i '\#^-- A trackpad preset that must win over pointer-tuning.lua#d; /^if M5PRO_TRACKPAD_LATE then M5PRO_TRACKPAD_LATE() end$/d' "$H/.config/hypr/hyprland.lua"
    echo "  ~/.config/hypr/hyprland.lua (macos-exact hook removed)"
  fi
  T=$H/.config/hypr/trackpad
  for f in select.lua switch-preset.sh; do
    [ -e "$T/$f.before-macos-feel" ] && mv "$T/$f.before-macos-feel" "$T/$f" && echo "  ~/.config/hypr/trackpad/$f (pre-macos-exact version restored)"
  done
  [ -e "$T/macos-exact.lua" ] && rm -f "$T/macos-exact.lua" && echo "  ~/.config/hypr/trackpad/macos-exact.lua removed"
  rm -f "$T/curves.lua.before-macos-feel" "$H/.config/hypr/hyprland.lua.before-macos-feel"
  # Convert the JSON (old flat values -> "custom"), pick the profile, write the .lua (no live apply).
  as_user python3 "$H/.config/omarchy/plugins/rolo.pointer/apply-pointer.py" --generate >/dev/null
  if [ $MACOS = 1 ]; then
    as_user python3 - "$H/.config/hypr/pointer-tuning.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["profile"] = "macos"; json.dump(d, open(p, "w"), indent=2)
EOF
    as_user python3 "$H/.config/omarchy/plugins/rolo.pointer/apply-pointer.py" --generate >/dev/null
    size=$(as_user python3 "$H/.config/omarchy/plugins/rolo.pointer/apply-pointer.py" --read | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor_size"])')
    as_user gsettings set org.gnome.desktop.interface cursor-size "$size" || true
    as_user "$H/.local/bin/macos-feel" desktop on || true
  fi
fi
as_user hyprctl reload >/dev/null && echo "applied (one hyprctl reload)"
