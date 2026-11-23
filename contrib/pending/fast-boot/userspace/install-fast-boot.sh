#!/bin/bash
# install-fast-boot.sh: the userspace half of the quiet-fast boot, with undo. Run as root ON the J716s, after the owner approved.
#
#   bash install-fast-boot.sh [--user rolo] [--dry-run]     install
#   bash install-fast-boot.sh --undo [--user rolo]          put every file back exactly as it was
#   bash install-fast-boot.sh --status                      what is installed
#
# What it changes (each file is backed up first, under /var/lib/m5pro-fast-boot/backup; the undo restores or removes it):
#   /etc/systemd/system/getty@tty2.service.d/zz-fast-boot.conf          autologin getty: Type=simple (no Type=idle wait), no banner
#   /usr/lib/systemd/system-shutdown/m5pro-settle.sh                    the 20 s pre-restart wait only after a write burst
#   /usr/local/lib/m5pro/io-sample, /etc/systemd/system/m5pro-iosample.{service,timer}   the write counter that decides it
#   /usr/local/lib/m5pro/panel-floor + systemd-backlight@.service.d/10-m5pro-panel-floor.conf   boot panel never below 30 %
#   ~USER/.local/bin/m5pro-lock-at-login                                v2: lock at once, keep the panel lit for 120 s
#   ~USER/.hushlogin                                                    no "Last login" line on the console
# It never restarts a service, never touches /boot (ESP), NVRAM or the running session; the getty and lock changes apply at
# the next boot / login. No rm -rf, no bind mounts.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
U=rolo; MODE=install; DRY=0
while [ $# -gt 0 ]; do case "$1" in
    --user) U=$2; shift 2 ;; --undo) MODE=undo; shift ;; --status) MODE=status; shift ;; --dry-run) DRY=1; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
UH=$(getent passwd "$U" | cut -d: -f6); [ -n "$UH" ] && [ -d "$UH" ] || { echo "no home for user $U" >&2; exit 1; }
BK=/var/lib/m5pro-fast-boot; MAN=$BK/manifest
run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

# source-in-this-folder  destination  mode  owner
FILES=(
  "getty-tty2-fast.conf|/etc/systemd/system/getty@tty2.service.d/zz-fast-boot.conf|0644|root"
  "backlight-floor.conf|/etc/systemd/system/systemd-backlight@.service.d/10-m5pro-panel-floor.conf|0644|root"
  "panel-floor|/usr/local/lib/m5pro/panel-floor|0755|root"
  "m5pro-iosample|/usr/local/lib/m5pro/io-sample|0755|root"
  "m5pro-iosample.service|/etc/systemd/system/m5pro-iosample.service|0644|root"
  "m5pro-iosample.timer|/etc/systemd/system/m5pro-iosample.timer|0644|root"
  "m5pro-settle.sh|/usr/lib/systemd/system-shutdown/m5pro-settle.sh|0755|root"
  "m5pro-lock-at-login|$UH/.local/bin/m5pro-lock-at-login|0755|$U"
)
HUSH=$UH/.hushlogin
tag() { echo "$1" | tr '/@' '__'; }

status() {
    for e in "${FILES[@]}"; do IFS='|' read -r src dst m o <<<"$e"
        if [ -e "$dst" ] && cmp -s "$HERE/$src" "$dst"; then echo "installed   $dst"; else echo "not ours    $dst"; fi; done
    [ -e "$HUSH" ] && echo "present     $HUSH" || echo "absent      $HUSH"
    [ -r "$MAN" ] && echo "backups: $BK ($(wc -l < "$MAN") entries)" || echo "no backup dir (nothing installed by this script)"
    systemctl is-enabled m5pro-iosample.timer 2>/dev/null || true
}

install_all() {
    [ -n "${M5_FASTBOOT_TEST:-}" ] || grep -q 'apple,j716s' /proc/device-tree/compatible 2>/dev/null || { echo "not a J716s: refusing" >&2; exit 1; }
    for e in "${FILES[@]}"; do IFS='|' read -r src dst m o <<<"$e"; [ -r "$HERE/$src" ] || { echo "missing $HERE/$src" >&2; exit 1; }; done
    [ -e "$MAN" ] && { echo "already installed ($MAN exists): run --undo first" >&2; exit 1; }
    run install -d -m 0700 "$BK" "$BK/backup"
    [ "$DRY" = 1 ] || : > "$BK/manifest.new"
    for e in "${FILES[@]}"; do IFS='|' read -r src dst m o <<<"$e"
        if [ -e "$dst" ]; then
            run cp -p "$dst" "$BK/backup/$(tag "$dst")"; state=replaced
        else state=absent; fi
        [ "$DRY" = 1 ] || echo "$state|$dst" >> "$BK/manifest.new"
        run install -d -m 0755 "$(dirname "$dst")"
        run install -m "$m" -o "$o" -g "$([ "$o" = root ] && echo root || id -gn "$o")" "$HERE/$src" "$dst"
        echo "  $state -> installed $dst"
    done
    if [ ! -e "$HUSH" ]; then [ "$DRY" = 1 ] || echo "absent|$HUSH" >> "$BK/manifest.new"; run install -m 0644 -o "$U" -g "$(id -gn "$U")" /dev/null "$HUSH"; fi
    [ "$DRY" = 1 ] || mv "$BK/manifest.new" "$MAN"
    run systemctl daemon-reload
    run systemctl enable --now m5pro-iosample.timer
    echo "done. Applies at the next boot (getty, lock) / next shutdown (settle). Undo: bash $0 --undo"
}

undo_all() {
    [ -r "$MAN" ] || { echo "no manifest: nothing to undo" >&2; exit 1; }
    while IFS='|' read -r state dst; do
        [ -n "$dst" ] || continue
        if [ "$state" = replaced ]; then
            run cp -p "$BK/backup/$(tag "$dst")" "$dst"; echo "  restored $dst"
        else
            run rm -f "$dst"; echo "  removed  $dst"
        fi
    done < "$MAN"
    run systemctl disable --now m5pro-iosample.timer 2>/dev/null || true
    run rm -f /run/m5pro-io-samples /run/m5pro-io-samples.tmp
    for d in /etc/systemd/system/getty@tty2.service.d /etc/systemd/system/systemd-backlight@.service.d; do run rmdir "$d" 2>/dev/null || true; done
    run systemctl daemon-reload
    run mv -f "$MAN" "$BK/manifest.undone-$(date +%Y%m%d-%H%M%S)"
    echo "undone. The backups stay in $BK/backup."
}

case $MODE in install) install_all ;; undo) undo_all ;; status) status ;; esac
