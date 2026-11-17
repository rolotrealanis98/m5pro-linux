#!/bin/bash
# Install the frictionless Startup Disk on the J716s. Run as root on the MacBook from a copy of this folder,
# with the NVRAM tools folder (contrib/pending/nvram/tools, or /root/nvram-j716s) as $1:
#   bash install.sh /root/nvram-j716s [USER]
# Undo: bash install.sh --uninstall [USER]
set -euo pipefail
cd "$(dirname "$0")"
U=${2:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "root" && $3 != "" {print $3; exit}')}
H=$(getent passwd "$U" | cut -d: -f6)
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
if [ "${1:-}" = --uninstall ]; then
    rm -f /usr/local/sbin/m5pro-startup-disk /usr/share/polkit-1/actions/org.m5pro.startup-disk.policy
    rm -rf /usr/local/lib/m5pro/nvram
    [ -f "$H/.local/bin/omarchy-startup-disk.before-frictionless" ] && mv "$H/.local/bin/omarchy-startup-disk.before-frictionless" "$H/.local/bin/omarchy-startup-disk"
    [ -f "$MENU.before-frictionless-startup-disk" ] && cp -p "$MENU.before-frictionless-startup-disk" "$MENU"
    echo "removed"; exit 0
fi
TOOLS=${1:?usage: install.sh NVRAM_TOOLS_DIR [USER]}
for f in nvram-next-boot.sh nvram-probe.sh v3-nvram.py; do [ -r "$TOOLS/$f" ] || { echo "missing $TOOLS/$f"; exit 1; }; done
command -v asahi-bless >/dev/null || { echo "asahi-bless missing (install-j716s.sh installs it)"; exit 1; }
install -d -m755 /usr/local/lib/m5pro/nvram
for f in nvram-next-boot.sh nvram-probe.sh v3-nvram.py; do install -m755 -o root -g root "$TOOLS/$f" /usr/local/lib/m5pro/nvram/; done
install -m755 -o root -g root m5pro-startup-disk /usr/local/sbin/m5pro-startup-disk
install -m644 -o root -g root org.m5pro.startup-disk.policy /usr/share/polkit-1/actions/org.m5pro.startup-disk.policy
B=$H/.local/bin/omarchy-startup-disk
[ -f "$B" ] && [ ! -f "$B.before-frictionless" ] && cp -p "$B" "$B.before-frictionless"
install -m755 -o "$U" -g "$U" omarchy-startup-disk "$B"
# Menu: rows run without a terminal now; add the Startup Disk choices.
if [ -f "$MENU" ]; then
    [ -f "$MENU.before-frictionless-startup-disk" ] || cp -p "$MENU" "$MENU.before-frictionless-startup-disk"
    python3 - "$MENU" menu-rows.jsonc <<'EOF'
import re, sys
path, rows_path = sys.argv[1], sys.argv[2]
text = open(path).read()
rows = open(rows_path).read().rstrip()
# drop the old startup-disk rows (they opened a terminal and asked for sudo + WRITE)
keep = [l for l in text.split("\n") if not re.match(r'\s*"system\.(reboot-macos|startup-disk[^"]*)"\s*:', l)]
text = "\n".join(keep)
end = text.rindex("}")
body = re.sub(r"//[^\n]*", "", text[:end]).rstrip()
sep = "" if body.endswith(("{", ",")) else ","
open(path, "w").write(text[:end].rstrip() + "\n" + sep + "\n" + rows + "\n" + text[end:])
EOF
    chown "$U:$U" "$MENU"
fi
/usr/local/sbin/m5pro-startup-disk status
echo "installed for $U"
