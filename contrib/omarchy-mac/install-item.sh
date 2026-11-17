#!/usr/bin/env bash
# install-item.sh - put an item of this folder on a MacBook running Omarchy, or take it off again.
#   sudo contrib/omarchy-mac/install-item.sh [--user NAME] [--dry-run] [--remove] <item>...
# An item is a directory here with `files/` (laid over /) and/or `home/` (laid over /home/NAME). `@USER@` in a file is
# replaced by NAME. File modes come from the repo (git keeps the executable bit). Nothing is enabled or started: each
# item's README.md says which `systemctl enable`, `udevadm control --reload` or logout it needs. Existing files are
# kept as <file>.before-omarchy-mac the first time they are replaced. Run on the MacBook, as root.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${SUDO_USER:-}; DRY=0; REMOVE=0; ITEMS=()
while [ $# -gt 0 ]; do
  case $1 in
    --user) USER_NAME=$2; shift 2;;
    --dry-run) DRY=1; shift;;
    --remove) REMOVE=1; shift;;
    -h|--help) sed -n '2,8p' "$0"; exit 0;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) ITEMS+=("$1"); shift;;
  esac
done
[ ${#ITEMS[@]} -gt 0 ] || { sed -n '2,3p' "$0" >&2; exit 2; }
[ $DRY = 1 ] || [ "$(id -u)" = 0 ] || { echo "run as root (or with --dry-run)" >&2; exit 1; }
run() { if [ $DRY = 1 ]; then echo "  would: $*"; else "$@"; fi; }
for item in "${ITEMS[@]}"; do
  dir=$HERE/$item
  [ -d "$dir" ] || { echo "no such item: $item" >&2; exit 1; }
  if [ -d "$dir/home" ]; then
    [ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { echo "$item has user files: pass --user NAME" >&2; exit 1; }
    HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6); [ -n "$HOME_DIR" ] || { echo "no user $USER_NAME" >&2; exit 1; }
  fi
  echo "== $item ($([ $REMOVE = 1 ] && echo remove || echo install))"
  for tree in files home; do
    [ -d "$dir/$tree" ] || continue
    base=/; [ $tree = home ] && base=$HOME_DIR/
    while IFS= read -r -d '' src; do
      rel=${src#"$dir/$tree/"}; dst=$base$rel
      if [ $REMOVE = 1 ]; then
        [ -e "$dst" ] && { echo "  rm $dst"; run rm -f "$dst"; }
        [ -e "$dst.before-omarchy-mac" ] && run mv "$dst.before-omarchy-mac" "$dst"
        continue
      fi
      echo "  $dst"
      run mkdir -p "$(dirname "$dst")"
      [ -e "$dst" ] && [ ! -e "$dst.before-omarchy-mac" ] && run cp -p "$dst" "$dst.before-omarchy-mac"
      if [ $DRY = 0 ]; then
        sed "s/@USER@/${USER_NAME:-USER}/g" "$src" >"$dst.new" && chmod --reference="$src" "$dst.new" && mv "$dst.new" "$dst"
        [ $tree = home ] && chown "$USER_NAME": "$dst"
      fi
    done < <(find "$dir/$tree" -type f -print0 | sort -z)
  done
  [ $REMOVE = 1 ] || echo "  next: see $item/README.md (enable units, reload udev, log out)"
done
