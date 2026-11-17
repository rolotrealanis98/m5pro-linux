#!/bin/sh
# Switch the J716s trackpad preset and apply it to the running Hyprland session.
# Usage: switch-preset.sh macos|between|linux-default     (no argument: show the active preset)
set -eu
dir="$(dirname "$(readlink -f "$0")")"
sel="$dir/select.lua"

case "${1:-}" in
  macos|between|linux-default) ;;
  "") sed -n 's/^local PRESET = "\(.*\)"/active preset: \1/p' "$sel"; exit 0 ;;
  *) echo "usage: $0 macos|between|linux-default" >&2; exit 2 ;;
esac

sed -i "s/^local PRESET = \".*\"/local PRESET = \"$1\"/" "$sel"
if hyprctl reload >/dev/null 2>&1; then
  echo "trackpad preset: $1 (applied)"
else
  echo "trackpad preset: $1 (saved; applies when Hyprland next starts)"
fi
