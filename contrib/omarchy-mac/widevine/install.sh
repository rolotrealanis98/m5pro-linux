#!/bin/bash
# widevine: Widevine CDM for the browser actually used on the MacBook (aarch64, 16K pages). Runs as the desktop USER, no root.
#   bash install.sh [--browser chrome|chromium|firefox] [--root DIR] [--force]    install if missing (idempotent)
#   bash install.sh --check [--browser B] [--online]                              read-only report (exit 0 = CDM usable)
#   bash install.sh --uninstall [--browser B]                                     remove what this script installed
# The CDM is never stored in the repo: it is downloaded at install time from Google's component update service (the same
# source and the same signed CRX3 Chrome's own updater uses; sha256 and the publisher signature are checked, see
# widevine_tool.py). Its 64K-aligned segments load on 16K pages as shipped, so no Asahi-style patching is done.
# Google Chrome's arm64 .deb already bundles the same CDM in /opt/google/chrome/WidevineCdm: for chrome the script then only
# checks it and installs nothing unless --force. --root DIR overrides the browser's user-data dir (tests).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=(python3 -I "$HERE/widevine_tool.py")
MODE=install B=""; FORCE=0; ONLINE=0; ROOT=""
while [ $# -gt 0 ]; do case $1 in
  --check) MODE=check;; --uninstall) MODE=uninstall;; --force) FORCE=1;; --online) ONLINE=1;;
  --browser) B=${2:?}; shift;; --root) ROOT=${2:?}; shift;;
  -h|--help) sed -n '2,10p' "$0"; exit 0;;
  *) echo "unknown option $1" >&2; exit 2;; esac; shift; done

[ "$(id -u)" != 0 ] || { echo "run as the desktop user, not root (the CDM lives in the user's browser profile)" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "aarch64 only (this is $(uname -m))" >&2; exit 1; }
command -v python3 >/dev/null && command -v openssl >/dev/null || { echo "needs python3 and openssl" >&2; exit 1; }

# which browser: --browser, else the desktop default, else the first installed
detect() {
  local d; d=$(xdg-settings get default-web-browser 2>/dev/null || true)
  case $d in google-chrome*) echo chrome; return;; chromium*) echo chromium; return;; firefox*) echo firefox; return;; esac
  [ -x /opt/google/chrome/chrome ] && { echo chrome; return; }
  command -v chromium >/dev/null && { echo chromium; return; }
  command -v firefox >/dev/null && { echo firefox; return; }
  echo none
}
[ -n "$B" ] || B=$(detect)
case $B in
  chrome)   UDD=${ROOT:-$HOME/.config/google-chrome}; BUNDLED=/opt/google/chrome/WidevineCdm;;
  chromium) UDD=${ROOT:-$HOME/.config/chromium}; BUNDLED=/usr/lib/chromium/WidevineCdm;;
  firefox)  UDD=${ROOT:-$HOME/.local/share/m5pro-widevine}; BUNDLED="";;
  *) echo "no supported browser found (chrome, chromium, firefox); use --browser" >&2; exit 1;;
esac
LIBREL=_platform_specific/linux_arm64/libwidevinecdm.so
MARK=.m5pro-widevine
POINTER=$UDD/WidevineCdm/latest-component-updated-widevine-cdm      # what Chrome's component updater writes
ENVF=$HOME/.config/environment.d/50-m5pro-widevine.conf               # Firefox: MOZ_GMP_PATH
GMP=$UDD/gmp-widevinecdm/system-installed
say() { echo "[widevine:$B] $*"; }
running() { pgrep -x "$1" >/dev/null 2>&1; }
procname() { case $B in chrome) echo chrome;; *) echo "$B";; esac; }

cdm_ok() {   # $1 = dir holding manifest.json and $LIBREL
  [ -f "$1/$LIBREL" ] && "${TOOL[@]}" elfcheck "$1/$LIBREL" >/dev/null && "${TOOL[@]}" dlopen "$1/$LIBREL" >/dev/null 2>&1
}
ver_of() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$1/manifest.json" 2>/dev/null || echo "?"; }
current_dir() {   # the CDM dir the browser will use, "" if none
  if [ "$B" = firefox ]; then [ -f "$GMP/libwidevinecdm.so" ] && echo "$GMP"; return 0; fi
  if [ -f "$POINTER" ]; then
    local p; p=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["Path"])' "$POINTER" 2>/dev/null || true)
    [ -n "$p" ] && [ -f "$p/manifest.json" ] && { echo "$p"; return 0; }
  fi
  [ -n "$BUNDLED" ] && [ -f "$BUNDLED/manifest.json" ] && echo "$BUNDLED"
  return 0
}

report() {
  say "page size $(getconf PAGESIZE), glibc $(ldd --version | head -1 | awk '{print $NF}'), browser $B, data $UDD"
  local rc=1 d
  if [ -n "$BUNDLED" ] && [ -f "$BUNDLED/manifest.json" ]; then
    say "bundled by the package: $BUNDLED $(ver_of "$BUNDLED")"; cdm_ok "$BUNDLED" && { say "  bundled CDM loads (ELF 16K-aligned, dlopen ok)"; rc=0; } || say "  bundled CDM does NOT load"
  fi
  d=$(current_dir)
  if [ -n "$d" ] && [ "$d" != "$BUNDLED" ]; then
    say "in use: $d $(ver_of "$d")$([ -e "$d/$MARK" ] && echo ' (installed by this script)')"
    cdm_ok "$d" && { say "  loads (ELF 16K-aligned, dlopen ok)"; rc=0; } || { say "  does NOT load"; rc=1; }
  fi
  [ -z "$d" ] && say "no CDM found for this browser"
  [ "$B" != firefox ] && [ -d "$UDD/WidevineCdm" ] && say "component dir: $(ls "$UDD/WidevineCdm" | tr '\n' ' ')"
  [ $ONLINE = 1 ] && say "Google currently offers $("${TOOL[@]}" latest)"
  running "$(procname)" && say "browser is running: restart it after a change, then see README step 2 (chrome://components)"
  return $rc
}

case $MODE in
check) report; exit $? ;;
uninstall)
  if [ "$B" = firefox ]; then
    [ -e "$UDD/$MARK" ] && { say "rm $UDD"; rm -rf "$UDD"; }
    [ -e "$ENVF" ] && { say "rm $ENVF"; rm -f "$ENVF"; }
    for p in "$HOME"/.mozilla/firefox/*/user.js; do [ -f "$p" ] && sed -i '/m5pro-widevine/d' "$p"; done
  else
    for v in "$UDD"/WidevineCdm/*/"$MARK"; do [ -e "$v" ] || continue; say "rm $(dirname "$v")"; rm -rf "$(dirname "$v")"; done
    if [ -f "$POINTER.before-m5pro-widevine" ]; then say "restore the previous pointer"; mv -f "$POINTER.before-m5pro-widevine" "$POINTER"
    elif [ -f "$POINTER" ] && ! [ -f "$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["Path"]+"/manifest.json")' "$POINTER" 2>/dev/null)" ]; then
      say "rm dangling pointer"; rm -f "$POINTER"; fi
  fi
  say "removed (the package's bundled CDM and Chrome's own component downloads are untouched)"; exit 0;;
esac

# install
if [ $FORCE = 0 ]; then
  d=$(current_dir)
  if [ -n "$d" ] && cdm_ok "$d"; then say "a working CDM is already in use ($d $(ver_of "$d")); nothing to do (--force to reinstall)"; exit 0; fi
fi
[ "$B" = chrome ] && [ -f /opt/google/chrome/WidevineCdm/manifest.json ] && [ $FORCE = 0 ] && \
  say "WARNING: the package's bundled CDM does not load; installing the signed component build instead"
T=$(mktemp -d "${TMPDIR:-/tmp}/m5pro-widevine.XXXXXXXX"); trap 'rm -rf "$T"' EXIT
say "downloading from Google's component update service"
VER=$("${TOOL[@]}" fetch "$T/cdm" | sed -n 's/^VERSION=//p')
[ -n "$VER" ] || { say "download failed"; exit 1; }
say "Widevine licence (accepting means you read it): $(tr '\n' ' ' < "$T/cdm/LICENSE" | cut -c1-300)"
"${TOOL[@]}" elfcheck "$T/cdm/$LIBREL" && "${TOOL[@]}" dlopen "$T/cdm/$LIBREL" || { say "the downloaded CDM does not load on this system"; exit 1; }

if [ "$B" = firefox ]; then
  mkdir -p "$GMP" "$(dirname "$ENVF")"
  install -m 0755 "$T/cdm/$LIBREL" "$GMP/libwidevinecdm.so"; install -m 0644 "$T/cdm/manifest.json" "$T/cdm/LICENSE" "$GMP/"
  touch "$UDD/$MARK"
  printf 'MOZ_GMP_PATH=${MOZ_GMP_PATH:+$MOZ_GMP_PATH:}%s\n' "$GMP" > "$ENVF"
  for p in "$HOME"/.mozilla/firefox/*/; do [ -f "$p/prefs.js" ] || continue
    grep -q m5pro-widevine "$p/user.js" 2>/dev/null || cat >> "$p/user.js" <<P
user_pref("media.gmp-widevinecdm.version", "system-installed"); // m5pro-widevine
user_pref("media.gmp-widevinecdm.visible", true); // m5pro-widevine
user_pref("media.gmp-widevinecdm.enabled", true); // m5pro-widevine
user_pref("media.gmp-widevinecdm.autoupdate", false); // m5pro-widevine
user_pref("media.eme.enabled", true); // m5pro-widevine
P
  done
  say "installed $VER in $GMP; log out and in (MOZ_GMP_PATH), then restart Firefox"
else
  DEST=$UDD/WidevineCdm/$VER
  mkdir -p "$UDD/WidevineCdm"
  if [ -e "$POINTER" ] && [ ! -e "$POINTER.before-m5pro-widevine" ] && ! grep -q "WidevineCdm/$VER\"" "$POINTER"; then cp -p "$POINTER" "$POINTER.before-m5pro-widevine"; fi
  rm -rf "$DEST"; mkdir -p "$DEST"; cp -a "$T/cdm/." "$DEST/"; touch "$DEST/$MARK"
  printf '{"Path":"%s"}' "$DEST" > "$POINTER.tmp" && mv -f "$POINTER.tmp" "$POINTER"
  say "installed $VER in $DEST; restart $B"
fi
report || true
