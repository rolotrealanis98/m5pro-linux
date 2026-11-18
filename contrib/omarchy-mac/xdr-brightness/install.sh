#!/bin/bash
# Install XDR brightness on the MacBook. Run as root from a copy of this folder:  bash install.sh [USER]
# Needs the j716s-xdr kernel to do anything; installing earlier is harmless (m5pro-xdr then says "not supported").
# Undo: bash install.sh --uninstall [USER]   (turns XDR off first)
set -euo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = --uninstall ] && { UN=1; shift; } || UN=0
U=${1:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "root" && $3 != "" {print $3; exit}')}
H=$(getent passwd "$U" | cut -d: -f6)
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
RULE=/etc/udev/rules.d/90-m5pro-xdr.rules
if [ $UN = 1 ]; then
    for a in /sys/bus/platform/drivers/apple-dcp/*/xdr_max_nits; do [ -e "$a" ] && echo 0 > "$a" || true; done
    rm -f "$H/.local/bin/m5pro-xdr" "$RULE"
    [ -f "$MENU.before-xdr" ] && cp -p "$MENU.before-xdr" "$MENU"
    udevadm control --reload
    echo "removed"; exit 0
fi
install -m644 files/etc/udev/rules.d/90-m5pro-xdr.rules "$RULE"
install -o "$U" -g "$U" -m755 home/.local/bin/m5pro-xdr "$H/.local/bin/m5pro-xdr"
udevadm control --reload
# This boot: what the rule does at the next one (no udev replay of other devices).
for a in /sys/bus/platform/drivers/apple-dcp/*/xdr_max_nits; do
    [ -e "$a" ] && chgrp video "$a" && chmod 0664 "$a"
done
if ! id -nG "$U" | tr ' ' '\n' | grep -qx video; then
    usermod -aG video "$U"
    echo "added $U to the video group: takes effect at the next login"
fi
if [ -f "$MENU" ] && ! grep -q '"system.xdr-brightness"' "$MENU"; then
    cp -p "$MENU" "$MENU.before-xdr"
    python3 - "$MENU" menu-rows.jsonc <<'PY'
import sys
p, rows = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read(); i = s.rstrip().rfind("}")
open(p, "w").write(s[:i].rstrip() + ",\n" + rows + "}\n")
PY
fi
echo installed
