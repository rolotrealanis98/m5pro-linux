#!/bin/bash
# Install auto brightness on the MacBook. Run as root from a copy of this folder:  bash install.sh [USER] [--no-start]
# Undo: bash install.sh --uninstall [USER]   (leaves the panel where it is)
set -euo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = --uninstall ] && { UN=1; shift; } || UN=0
U=${1:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "root" && $3 != "" {print $3; exit}')}
H=$(getent passwd "$U" | cut -d: -f6); UID_=$(id -u "$U")
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
R=(runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus)
if [ $UN = 1 ]; then
    "${R[@]}" systemctl --user disable --now m5pro-auto-brightness.service || true
    rm -f "$H/.local/bin/m5pro-auto-brightness" "$H/.config/systemd/user/m5pro-auto-brightness.service" /usr/lib/modules-load.d/m5pro-aop-als.conf
    [ -f "$MENU.before-auto-brightness" ] && cp -p "$MENU.before-auto-brightness" "$MENU"
    "${R[@]}" systemctl --user daemon-reload
    echo "removed (config in ~/.config/m5pro-auto-brightness and state in ~/.local/state/m5pro-auto-brightness kept)"; exit 0
fi
install -m644 files/usr/lib/modules-load.d/m5pro-aop-als.conf /usr/lib/modules-load.d/m5pro-aop-als.conf
modprobe aop_als || true
install -o "$U" -g "$U" -m755 home/.local/bin/m5pro-auto-brightness "$H/.local/bin/m5pro-auto-brightness"
install -o "$U" -g "$U" -d "$H/.config/m5pro-auto-brightness"
[ -e "$H/.config/m5pro-auto-brightness/config.toml" ] || install -o "$U" -g "$U" -m644 home/.config/m5pro-auto-brightness/config.toml "$H/.config/m5pro-auto-brightness/config.toml"
install -o "$U" -g "$U" -m644 home/.config/systemd/user/m5pro-auto-brightness.service "$H/.config/systemd/user/m5pro-auto-brightness.service"
if ! grep -q '"system.auto-brightness"' "$MENU"; then
    cp -p "$MENU" "$MENU.before-auto-brightness"
    python3 - "$MENU" menu-rows.jsonc <<'PY'
import sys
p, rows = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read(); i = s.rstrip().rfind("}")
open(p, "w").write(s[:i].rstrip() + ",\n" + rows + "}\n")
PY
fi
"${R[@]}" systemctl --user daemon-reload
[ "${2:-}" = --no-start ] || "${R[@]}" systemctl --user enable --now m5pro-auto-brightness.service
echo installed
