#!/bin/sh
# Switch the J716s trackpad preset and apply it to the running Hyprland session.
# Usage: switch-preset.sh macos|between|linux-default|macos-exact     (no argument: show the active preset)
# macos-exact also sets the desktop side (text size, cursor size, browser scrolling) with
# ~/.local/bin/macos-feel; leaving it puts those back the way they were.
set -eu
dir="$(dirname "$(readlink -f "$0")")"
sel="$dir/select.lua"
feel="$HOME/.local/bin/macos-feel"

case "${1:-}" in
  macos|between|linux-default|macos-exact) ;;
  "") sed -n 's/^local PRESET = "\(.*\)"/active preset: \1/p' "$sel"; exit 0 ;;
  *) echo "usage: $0 macos|between|linux-default|macos-exact" >&2; exit 2 ;;
esac

sed -i "s/^local PRESET = \".*\"/local PRESET = \"$1\"/" "$sel"
if hyprctl reload >/dev/null 2>&1; then
  echo "trackpad preset: $1 (applied)"
else
  echo "trackpad preset: $1 (saved; applies when Hyprland next starts)"
fi

if [ -x "$feel" ]; then
  if [ "$1" = macos-exact ]; then "$feel" desktop on; else "$feel" desktop off; fi
fi
