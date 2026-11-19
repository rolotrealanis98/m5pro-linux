#!/bin/bash
# Install "Login Items & Restore" (session save/restore) on the MacBook. Run as root from a copy of this folder:
#   bash install.sh [USER] [--no-start]
# Undo: bash install.sh --uninstall [USER]   (stops and removes the app, services and scripts; your settings and snapshots are kept)
set -euo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = --uninstall ] && { UN=1; shift; } || UN=0
U=${1:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "root" && $3 != "" {print $3; exit}')}
H=$(getent passwd "$U" | cut -d: -f6); UID_=$(id -u "$U")
R=(runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus)
LIB=$H/.local/lib/m5pro-session
BINS="m5pro-session-save m5pro-session-restore m5pro-session-app"
UNITS="m5pro-session-save.service m5pro-session-restore.service"
APPS=$H/.local/share/applications/org.m5pro.SessionRestore.desktop
ICON=$H/.local/share/icons/hicolor/scalable/apps/org.m5pro.SessionRestore.svg
if [ $UN = 1 ]; then
    for u in $UNITS; do "${R[@]}" systemctl --user disable --now "$u" || true; done
    for b in $BINS; do rm -f "$H/.local/bin/$b"; done
    for u in $UNITS; do rm -f "$H/.config/systemd/user/$u"; done
    rm -rf "$LIB"; rm -f "$APPS" "$ICON"
    "${R[@]}" systemctl --user daemon-reload
    "${R[@]}" gtk-update-icon-cache -f -t "$H/.local/share/icons/hicolor" 2>/dev/null || true
    echo "removed (settings in ~/.config/m5pro-session and snapshots in ~/.local/state/m5pro-session kept)"; exit 0
fi
install -o "$U" -g "$U" -d "$H/.local/bin" "$LIB" "$H/.config/systemd/user" "$H/.local/share/applications" "$(dirname "$ICON")"
install -o "$U" -g "$U" -m644 home/.local/lib/m5pro-session/m5pro_session.py "$LIB/m5pro_session.py"
for b in $BINS; do install -o "$U" -g "$U" -m755 "home/.local/bin/$b" "$H/.local/bin/$b"; done
for u in $UNITS; do install -o "$U" -g "$U" -m644 "home/.config/systemd/user/$u" "$H/.config/systemd/user/$u"; done
sed "s|@HOME@|$H|" home/.local/share/applications/org.m5pro.SessionRestore.desktop > "$APPS"
chown "$U:$U" "$APPS"; chmod 644 "$APPS"
install -o "$U" -g "$U" -m644 home/.local/share/icons/hicolor/scalable/apps/org.m5pro.SessionRestore.svg "$ICON"
"${R[@]}" update-desktop-database "$H/.local/share/applications" 2>/dev/null || true
# a stale icon-theme.cache hides new icons: refresh it when the user's hicolor folder has one
[ -e "$H/.local/share/icons/hicolor/icon-theme.cache" ] && { "${R[@]}" gtk-update-icon-cache -f -t "$H/.local/share/icons/hicolor" 2>/dev/null || true; }
"${R[@]}" systemctl --user daemon-reload
# The restore unit runs at the next login (starting it now would relaunch apps); the saver starts now.
# Mark this boot as handled so the saver's "login restore has not run yet" guard does not hold it back.
"${R[@]}" env PYTHONPATH="$LIB" python3 -c "
import time, m5pro_session as m
if m.restore_status().get('boot_id') != m.boot_id():
    m.write_restore_status(status='installed', boot_id=m.boot_id(), finished=time.time())"
"${R[@]}" systemctl --user enable m5pro-session-restore.service
if [ "${2:-}" = --no-start ]; then "${R[@]}" systemctl --user enable m5pro-session-save.service
else "${R[@]}" systemctl --user enable m5pro-session-save.service; "${R[@]}" systemctl --user restart m5pro-session-save.service; fi
echo installed
