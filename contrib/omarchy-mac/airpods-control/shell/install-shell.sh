#!/usr/bin/env bash
# install-shell.sh - AirPods controls in the Omarchy Bluetooth panel, as a clone of the stock plugin. Run as the DESKTOP USER (not root).
#   bash install-shell.sh --check      read-only: installed plugin, whether the patch applies, daemon state
#   bash install-shell.sh --stage      build ~/.config/omarchy/plugins/$USER.bluetooth (clone of omarchy.bluetooth + patch). NOTHING IS RELOADED.
#   bash install-shell.sh --enable     enable the clone. **THIS RELOADS THE BLUETOOTH PANEL IN THE RUNNING OMARCHY SHELL** (plugin hot swap, not a shell
#                                      restart; the owner must approve it first). Stages first if needed.
#   bash install-shell.sh --remove     undo: disable and remove the clone (**same hot swap back to the stock panel**); the stock panel returns.
# Needs: the airpods-control root item installed (airpods-daemon + unit), jq, patch, the omarchy-* CLI on PATH.
# Same result as `omarchy plugin clone omarchy.bluetooth` followed by applying bluetooth-panel-airpods.patch, but the shell is not
# touched until --enable. Never restarts the shell, Hyprland, PipeWire or WirePlumber.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=$HERE/bluetooth-panel-airpods.patch
SRC_ID=omarchy.bluetooth
ID="${USER:-$(id -un)}.bluetooth"
PLUGINS="$HOME/.config/omarchy/plugins"
TARGET="$PLUGINS/$ID"
mode=${1:-}
[ "$(id -u)" != 0 ] || { echo "run as the desktop user, not root" >&2; exit 1; }
need() { command -v "$1" >/dev/null || { echo "missing: $1${2:+ ($2)}" >&2; exit 1; }; }
need jq; need patch "pacman -S patch"; need omarchy-plugin-catalog

source_dir() {
  omarchy-plugin-catalog | jq -r --arg id "$SRC_ID" '.[] | select(.firstParty and .id == $id) | .sourceDir'
}

check() {
  local src; src=$(source_dir); [ -n "$src" ] && [ -d "$src" ] || { echo "stock $SRC_ID not found" >&2; return 1; }
  echo "stock plugin dir: $src"
  ( cd "$src" && sha256sum Panel.qml Model.js manifest.json )
  echo "pacman: $(pacman -Q omarchy 2>/dev/null || echo 'omarchy: not a package')   version file: $(cat "${OMARCHY_PATH:-/usr/share/omarchy}/version" 2>/dev/null || echo n/a)"
  local tmp; tmp=$(mktemp -d "$PLUGINS/.airpods-check.XXXXXX"); trap 'rm -rf "$tmp"' RETURN
  cp -aL "$src/." "$tmp/"
  if ( cd "$tmp" && patch -p5 --dry-run -s < "$PATCH" ); then echo "patch: applies cleanly to the installed plugin"; else echo "patch: DOES NOT APPLY (installed plugin differs from v4.5.0)" >&2; return 1; fi
  [ -e "$TARGET" ] && echo "clone: $TARGET exists" || echo "clone: not staged"
  echo "daemon: $(systemctl --user is-active airpods-control.service 2>&1 || true) / socket $([ -S "${XDG_RUNTIME_DIR:-/nonexistent}/airpods-control.sock" ] && echo present || echo absent)"
  omarchy-shell shell listPlugins 2>/dev/null | jq -r --arg id "$ID" '.[] | select(.id == $id or .id == "omarchy.bluetooth") | "\(.id) enabled=\(.enabled)"' || true
}

stage() {
  [ ! -e "$TARGET" ] || { echo "$TARGET already exists (use --remove first)" >&2; exit 1; }
  local src; src=$(source_dir); [ -n "$src" ] && [ -d "$src" ] || { echo "stock $SRC_ID not found" >&2; exit 1; }
  mkdir -p "$PLUGINS"
  local stage_dir; stage_dir=$(mktemp -d "$PLUGINS/.clone.XXXXXX")
  trap 'rm -rf "$stage_dir"' EXIT
  cp -aL "$src/." "$stage_dir/"
  ( cd "$stage_dir" && patch -p5 -s < "$PATCH" ) || { echo "patch does not apply to the installed plugin; nothing was changed" >&2; exit 1; }
  # the same manifest edit `omarchy plugin clone` makes: new id, "My ..." name, clonedFrom keeps the built-in IPC identity
  jq --arg id "$ID" --arg name "My Bluetooth" --arg src "$SRC_ID" '
      .id = $id | .name = $name
      | if (.barWidget | type) == "object" then .barWidget.displayName = $name else . end
      | .omarchy = ((if (.omarchy | type) == "object" then .omarchy else {} end) + { clonedFrom: $src })
      | del(.omarchy.clonePaths)' "$stage_dir/manifest.json" > "$stage_dir/manifest.json.tmp"
  mv "$stage_dir/manifest.json.tmp" "$stage_dir/manifest.json"
  mv "$stage_dir" "$TARGET"; trap - EXIT
  echo "staged $TARGET (not loaded: the shell has not been told)"
}

case $mode in
  --check) check;;
  --stage) stage;;
  --enable)
    [ -d "$TARGET" ] || stage
    echo "RELOADING the Bluetooth panel in the running Omarchy shell (plugin hot swap) ..."
    omarchy-shell shell rescanPlugins >/dev/null
    for _ in $(seq 40); do omarchy-plugin-list --json | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null && break; sleep 0.05; done
    omarchy-plugin-enable "$ID"
    echo "enabled $ID. Start the daemon if it is not running: systemctl --user enable --now airpods-control.service";;
  --remove)
    if [ -d "$TARGET" ]; then
      echo "REMOVING the clone: the stock Bluetooth panel is swapped back in the running shell ..."
      omarchy-plugin-remove --yes "$ID"
      echo "(the clone's files were moved to a hidden .$ID.bak.* folder in $PLUGINS; delete it by hand when you are sure)"
    else echo "$ID is not installed"; fi;;
  *) sed -n '2,10p' "$0"; exit 2;;
esac
