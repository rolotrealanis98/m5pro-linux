#!/bin/bash
# Install the DCP desktop session files on the MacBook. Nothing restarts: the
# new launcher and profile take effect at the next Hyprland start (next boot,
# or logout of tty2). Existing files are kept as <file>.pre-dcp (once).
#   From the Studio:   ./install.sh root@<macbook> [--dry-run|--uninstall]
#   On the MacBook:    bash install.sh --local [--dry-run|--uninstall]   (as root, from this directory)
# Installs:
#   /usr/local/lib/hypr-cards.sh        card discovery by driver (shared)
#   /usr/local/bin/hypr-gpu-session     GPU launcher: DCP path or simpledrm path
#   /usr/local/bin/hypr-dcp-verify      post-boot verification (run as root)
#   /usr/local/bin/hypr-dcp-precheck    which card is apple / GPU on this boot
#   ~USER/.local/bin/hypr-session       tty2 launcher with the 30 s software fallback
#   ~USER/.config/hypr/m5pro-dcp.lua    session profile for the DCP path
#   ~USER/.config/hypr/hyprland.lua     one block: load m5pro-dcp.lua or m5pro.lua (hyprland.lua.patch)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FILES=(hypr-cards.sh hypr-gpu-session hypr-session hypr-dcp-verify hypr-dcp-precheck.sh m5pro-dcp.lua hyprland.lua.patch install.sh)

if [ "${1:-}" != --local ]; then
  host=${1:?usage: install.sh root@HOST [--dry-run|--uninstall]  or  install.sh --local}; shift
  for f in "${FILES[@]}"; do [ -r "$HERE/$f" ] || { echo "missing $HERE/$f"; exit 1; }; done
  tar -C "$HERE" -cf - "${FILES[@]}" |
    ssh -i "${SSH_KEY:-$HOME/.ssh/mbp}" -o BatchMode=yes "$host" \
      "d=\$(mktemp -d) && tar -xf - -C \"\$d\" && bash \"\$d/install.sh\" --local $* ; rc=\$?; rm -rf \"\$d\"; exit \$rc"
  exit $?
fi
shift
DRY=0 UNINSTALL=0
for a in "$@"; do case $a in --dry-run) DRY=1;; --uninstall) UNINSTALL=1;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
U=${HYPR_USER:-rolo}
UH=$(getent passwd "$U" | cut -d: -f6); [ -n "$UH" ] || { echo "no user $U"; exit 1; }
run() { echo "+ $*"; [ $DRY = 1 ] || "$@"; }

# dest  source  mode  owner
MAP=(
  "/usr/local/lib/hypr-cards.sh      hypr-cards.sh         0644 root"
  "/usr/local/bin/hypr-gpu-session   hypr-gpu-session      0755 root"
  "/usr/local/bin/hypr-dcp-verify    hypr-dcp-verify       0755 root"
  "/usr/local/bin/hypr-dcp-precheck  hypr-dcp-precheck.sh  0755 root"
  "$UH/.local/bin/hypr-session       hypr-session          0755 $U"
  "$UH/.config/hypr/m5pro-dcp.lua    m5pro-dcp.lua         0644 $U"
)
HL=$UH/.config/hypr/hyprland.lua

if [ $UNINSTALL = 1 ]; then
  for m in "${MAP[@]}"; do
    read -r dst _ _ _ <<<"$m"
    if [ -e "$dst.pre-dcp" ]; then run mv -f "$dst.pre-dcp" "$dst"; elif [ -e "$dst" ]; then run rm -f "$dst"; fi
  done
  [ -e "$HL.pre-dcp" ] && run mv -f "$HL.pre-dcp" "$HL"
  echo "uninstalled (takes effect at the next Hyprland start)"; exit 0
fi

for m in "${MAP[@]}"; do
  read -r dst src mode owner <<<"$m"
  if [ -e "$dst" ] && cmp -s "$dst" "$HERE/$src"; then echo "= $dst (unchanged)"; continue; fi
  [ -e "$dst" ] && [ ! -e "$dst.pre-dcp" ] && run cp -p "$dst" "$dst.pre-dcp"
  run install -D -m "$mode" -o "$owner" -g "$(id -gn "$owner")" "$HERE/$src" "$dst"
done

# hyprland.lua: replace the plain require("hypr.m5pro") with the profile switch.
if grep -q 'M5PRO_HYPR_PROFILE' "$HL"; then
  echo "= $HL (profile switch already present)"
elif grep -q '^require("hypr.m5pro")$' "$HL"; then
  [ -e "$HL.pre-dcp" ] || run cp -p "$HL" "$HL.pre-dcp"
  if [ $DRY = 1 ]; then echo "+ patch $HL < hyprland.lua.patch"; patch --dry-run -s -o /dev/null "$HL" < "$HERE/hyprland.lua.patch"
  else patch -s --no-backup-if-mismatch "$HL" < "$HERE/hyprland.lua.patch"; chown "$U:$(id -gn "$U")" "$HL"; fi
else
  echo "! $HL has no plain require(\"hypr.m5pro\") line: add the block from hyprland.lua.patch by hand"; exit 1
fi
command -v luac >/dev/null && [ $DRY = 0 ] && { luac -p "$HL" "$UH/.config/hypr/m5pro-dcp.lua" && echo "lua syntax ok"; }
bash -n /usr/local/bin/hypr-gpu-session "$UH/.local/bin/hypr-session" /usr/local/bin/hypr-dcp-verify 2>/dev/null && echo "shell syntax ok"
echo
echo "installed for $U; active at the next Hyprland start. This boot:"
bash "$HERE/hypr-dcp-precheck.sh" || true
