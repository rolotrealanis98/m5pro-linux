#!/bin/bash
# 1Password Touch ID unlock from a fresh start (m5pro-1p-touchid). Idempotent. Run as root on the MacBook
# from a copy of this folder:
#   bash install.sh [--user NAME]              install (the owner then runs: m5pro-1p-touchid setup)
#   bash install.sh [--user NAME] --uninstall  remove everything, destroying the saved password records
# Never touches PAM, apple_sep, fprintd or the enrolled fingerprints.
set -euo pipefail
cd "$(dirname "$0")"
U=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" { print $3; exit }')
UNINSTALL=0
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -n "$U" ] && id "$U" >/dev/null 2>&1 || { echo "no desktop user found: pass --user NAME"; exit 1; }
UID_U=$(id -u "$U"); H=$(getent passwd "$U" | cut -d: -f6)
STAMP=$(date +%Y%m%d-%H%M%S)
LIBEXEC=/usr/local/libexec/m5pro-1p-touchid
POLICY=/usr/share/polkit-1/actions/org.m5pro.1p-touchid.policy
UNIT=$H/.config/systemd/user/m5pro-1p-touchid-watch.service
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
say() { echo "== $*"; }
as_user() {
  runuser -u "$U" -- env HOME="$H" USER="$U" XDG_RUNTIME_DIR="/run/user/$UID_U" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_U/bus" "$@"
}
echo "desktop user: $U"

if (( UNINSTALL )); then
  say "uninstall"
  as_user systemctl --user disable --now m5pro-1p-touchid-watch.service 2>/dev/null || true
  rm -f "$UNIT"; as_user systemctl --user daemon-reload || true
  # Destroy every saved record (overwrite, then unlink). The sealed blobs open nowhere else anyway.
  for r in /var/lib/m5pro-1p-touchid/*.record; do
    [ -e "$r" ] || continue
    shred -u "$r" 2>/dev/null || { : > "$r"; rm -f "$r"; }
    echo "   destroyed $r"
  done
  rm -rf /var/lib/m5pro-1p-touchid /run/m5pro-1p-touchid
  rm -f /usr/local/bin/m5pro-1p-touchid "$POLICY"; rm -rf "$LIBEXEC" /usr/local/share/doc/m5pro-1p-touchid
  if [ -f "$MENU" ] && grep -q 'touchid-omarchy/1password-launch' "$MENU"; then
    cp -p "$MENU" "/root/omarchy-menu.jsonc.before-1p-touchid-uninstall-$STAMP"
    python3 - "$MENU" <<'EOF'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r'\n?,?\n  // 1Password Touch ID \(m5pro-linux touchid-omarchy/1password-launch\).*?"setup\.security\.1password\.forget": \{[^\n]*\}\n', '\n', t, flags=re.S)
open(p, 'w').write(t)
EOF
    chown "$U:$U" "$MENU"
  fi
  echo "   done (wtype stays installed)"
  exit 0
fi

say "1. wtype (types into the focused Wayland window)"
pacman -Q wtype >/dev/null 2>&1 || OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm wtype
pacman -Q wtype

say "2. seal helper (root, through pkexec only)"
make -s -C seal
install -Dm755 seal/m5pro-1p-seal "$LIBEXEC/m5pro-1p-seal"
make -s -C seal clean
"$LIBEXEC/m5pro-1p-seal" check && echo "   SEP sealing works (trusted key, applesep source)"
install -d -m755 /var/lib/m5pro-1p-touchid
chmod 755 /var/lib/m5pro-1p-touchid

say "3. polkit actions: org.m5pro.1p-touchid.{unlock,setup,forget} (auth_self every time)"
install -Dm644 org.m5pro.1p-touchid.policy "$POLICY"
pkaction --action-id org.m5pro.1p-touchid.unlock >/dev/null && echo "   $POLICY"

say "4. the tool, its watcher (user service) and docs"
install -Dm755 m5pro-1p-touchid /usr/local/bin/m5pro-1p-touchid
install -Dm644 README.md /usr/local/share/doc/m5pro-1p-touchid/README.md
install -Dm644 -o "$U" -g "$U" m5pro-1p-touchid-watch.service "$UNIT"
chown "$U:$U" "$H/.config/systemd/user" 2>/dev/null || true
as_user systemctl --user daemon-reload
as_user systemctl --user enable m5pro-1p-touchid-watch.service
as_user systemctl --user restart m5pro-1p-touchid-watch.service
echo "   watcher $(as_user systemctl --user is-active m5pro-1p-touchid-watch.service)"

say "5. menu rows: Setup > Security > 1Password Touch ID"
if [ ! -f "$MENU" ]; then echo "   $MENU missing: rows not added"
elif grep -q 'touchid-omarchy/1password-launch' "$MENU"; then echo "   rows already there"
else
  cp -p "$MENU" "/root/omarchy-menu.jsonc.before-1p-touchid-$STAMP"
  echo "   backup /root/omarchy-menu.jsonc.before-1p-touchid-$STAMP"
  python3 - "$MENU" menu-1password-rows.jsonc <<'EOF'
import re, sys
path, rows = sys.argv[1], open(sys.argv[2]).read().rstrip()
text = open(path).read()
end = text.rindex("}")
body = re.sub(r"//[^\n]*", "", text[:end]).rstrip()
sep = "" if body.endswith(("{", ",")) else ","
open(path, "w").write(text[:end].rstrip() + "\n" + sep + "\n" + rows + "\n" + text[end:])
EOF
  chown "$U:$U" "$MENU"; echo "   added"
fi

say "check"
as_user /usr/local/bin/m5pro-1p-touchid status || true
echo "   next, at the machine: Omarchy menu > Setup > Security > 1Password Touch ID > Set up"
