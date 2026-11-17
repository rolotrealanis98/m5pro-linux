#!/bin/bash
# Touch ID in Omarchy on the J716s: boot bring-up, the libfprint guard, PAM, polkit, the Touch ID panel
# and its menu row. Idempotent; prints each step. Run as root on the MacBook from a copy of this folder:
#   bash install.sh [--user NAME] [--with-rearm] [--uninstall]
#     --user NAME   desktop user (default: the user of the seat0 session; /home's first directory is
#                   the image's leftover alarm account on this MacBook, so it is never guessed from there)
#     --with-rearm  also run rearm/install-rearm.sh (opt-in; read it first)
#     --uninstall   remove what this script adds on top of a working Touch ID (panel, menu rows, guard,
#                   polkit rule). Leaves the driver bring-up, libfprint, fprintd, PAM and fingerprints.
# Never touches /boot, kernel modules, apple_sep state in /var/lib, or enrolled fingerprints.
set -euo pipefail
cd "$(dirname "$0")"
U=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" { print $3; exit }')
REARM=0 UNINSTALL=0
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --with-rearm) REARM=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -n "$U" ] && id "$U" >/dev/null 2>&1 || { echo "no desktop user found: pass --user NAME"; exit 1; }
echo "desktop user: $U"
UID_U=$(id -u "$U"); H=$(getent passwd "$U" | cut -d: -f6)
STAMP=$(date +%Y%m%d-%H%M%S)
say() { echo "== $*"; }
as_user() {
  runuser -u "$U" -- env HOME="$H" USER="$U" XDG_RUNTIME_DIR="/run/user/$UID_U" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_U/bus" OMARCHY_PATH=/usr/share/omarchy \
    PATH="/usr/share/omarchy/bin:/usr/local/bin:/usr/bin" "$@"
}
backup() { [ -e "$1" ] && cp -p "$1" "/root/$(basename "$1").before-touchid-omarchy-$STAMP" && echo "   backup /root/$(basename "$1").before-touchid-omarchy-$STAMP"; return 0; }
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
PLUGIN=$H/.config/omarchy/plugins/m5pro.touchid

if (( UNINSTALL )); then
  say "uninstall: panel, menu rows, guard, polkit rule"
  as_user omarchy-shell -q shell setPluginEnabled m5pro.touchid false || true
  rm -rf "$PLUGIN"; as_user omarchy-shell -q shell rescanPlugins || true
  if [ -f "$MENU" ] && grep -q 'm5pro-linux touchid-omarchy' "$MENU"; then
    backup "$MENU"
    python3 - "$MENU" <<'EOF'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r'\n?,?\n  // Touch ID \(m5pro-linux touchid-omarchy\).*?"remove\.security\.fingerprint": \{"when":"false"\}\n', '\n', t, flags=re.S)
open(p, 'w').write(t)
EOF
    chown "$U:$U" "$MENU"
  fi
  rm -f /usr/local/bin/m5pro-touchid /etc/polkit-1/rules.d/40-m5pro-admin-self.rules
  rm -f /etc/pacman.d/hooks/50-m5pro-touchid-guard.hook /usr/local/lib/m5pro/touchid-pacman-guard
  grep -q 'm5pro-touchid-guard' /etc/pacman.conf && { backup /etc/pacman.conf; sed -i '/# m5pro-touchid-guard/d' /etc/pacman.conf; }
  echo "   done. libfprint-git (aurora build) stays installed: Omarchy's setup no longer swaps it while"
  echo "   usbutils is installed, but nothing refuses a swap now."
  exit 0
fi

say "1. Touch ID bring-up at boot (apple_sep does not autoload on the J716s)"
for f in $(cd system && find etc usr -type f | sort); do
  mode=644; case $f in usr/local/lib/*) mode=755 ;; esac
  if cmp -s "system/$f" "/$f"; then echo "   /$f (unchanged)"; else backup "/$f"; install -Dm$mode "system/$f" "/$f"; echo "   /$f"; fi
done
systemctl daemon-reload
systemctl is-enabled -q m5pro-touchid.service || systemctl enable m5pro-touchid.service
echo "   m5pro-touchid.service $(systemctl is-enabled m5pro-touchid.service), $(systemctl is-active m5pro-touchid.service)"

say "2. libfprint: the Aurora build, named libfprint-git (epoch 2), so Omarchy's setup keeps it"
have=$(pacman -Q libfprint-git 2>/dev/null || true)
if [[ $have == *aurora* ]]; then
  echo "   $have"
else
  pkg=$(ls /home/"$U"/build/libfprint-aurora/libfprint-git-2:*aurora*.pkg.tar.* 2>/dev/null | tail -1 || true)
  if [ -z "$pkg" ]; then
    echo "   no built package: build it first as $U (cd libfprint-aurora && makepkg -f), then rerun"; exit 1
  fi
  touch /run/m5pro-touchid-allow-libfprint
  OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -U --noconfirm --ask 4 "$pkg"
  rm -f /run/m5pro-touchid-allow-libfprint
  systemctl try-restart fprintd.service
  echo "   $(pacman -Q libfprint-git)"
fi
# Omarchy's setup installs packages when any of libfprint-git, fprintd, usbutils is missing.
pacman -Q usbutils >/dev/null 2>&1 || OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed --noconfirm usbutils
if omarchy-pkg-missing libfprint-git fprintd usbutils; then echo "   WARNING: omarchy-pkg-missing still reports a package missing"; else echo "   omarchy-pkg-missing: all present (its package step is skipped)"; fi

say "3. pacman guard: refuse swapping libfprint-git or removing it/fprintd"
install -Dm755 guard/touchid-pacman-guard /usr/local/lib/m5pro/touchid-pacman-guard
install -Dm644 guard/50-m5pro-touchid-guard.hook /etc/pacman.d/hooks/50-m5pro-touchid-guard.hook
if grep -q 'm5pro-touchid-guard' /etc/pacman.conf; then echo "   IgnorePkg line present"; else
  backup /etc/pacman.conf
  if grep -q '^IgnorePkg' /etc/pacman.conf; then
    sed -i '0,/^IgnorePkg/{/^IgnorePkg.*/a IgnorePkg   = libfprint-git # m5pro-touchid-guard (the Touch ID libfprint; see /etc/pacman.d/hooks/50-m5pro-touchid-guard.hook)
}' /etc/pacman.conf
  else
    sed -i '/^\[options\]/a IgnorePkg   = libfprint-git # m5pro-touchid-guard (the Touch ID libfprint; see /etc/pacman.d/hooks/50-m5pro-touchid-guard.hook)' /etc/pacman.conf
  fi
  echo "   IgnorePkg = libfprint-git added"
fi

say "4. PAM: Omarchy's fingerprint stacks (lid gate, pam_fprintd, password fallback)"
gate="auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"
for pam in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
  if [ ! -f "$pam" ]; then
    [ "$pam" = /etc/pam.d/polkit-1 ] || { echo "   $pam missing: left alone"; continue; }
    printf '%s\n' "$gate" "auth      sufficient pam_fprintd.so" "auth      include system-auth" "" \
      "account   include system-auth" "password  include system-auth" "session   include system-auth" > "$pam"
    echo "   $pam created"; continue
  fi
  if grep -q pam_fprintd.so "$pam" && grep -q omarchy-hw-laptop-closed "$pam"; then echo "   $pam ok"; continue; fi
  backup "$pam"
  grep -q pam_fprintd.so "$pam" || sed -i '1i auth      sufficient pam_fprintd.so' "$pam"
  grep -q omarchy-hw-laptop-closed "$pam" || sed -i "/pam_fprintd\.so/i $gate" "$pam"
  echo "   $pam updated"
done
grep -qE '^(auth|-auth).*(system-auth|pam_unix)' /etc/pam.d/polkit-1 || echo "   WARNING: /etc/pam.d/polkit-1 has no password fallback"
if [ -f /etc/pam.d/omarchy-lock-fingerprint ]; then echo "   lock screen: omarchy-lock-fingerprint ok"; else
  as_user omarchy-apply-lock && echo "   lock screen: omarchy-apply-lock ran"
fi

say "5. polkit: admin prompts ask the person at the keyboard (not the first wheel member)"
install -Dm644 polkit/40-m5pro-admin-self.rules /etc/polkit-1/rules.d/40-m5pro-admin-self.rules
echo "   /etc/polkit-1/rules.d/40-m5pro-admin-self.rules (polkitd reloads rules by itself)"

say "6. Touch ID panel: helper, shell plugin, menu row"
install -Dm755 bin/m5pro-touchid /usr/local/bin/m5pro-touchid
install -d -o "$U" -g "$U" "$PLUGIN"
install -m644 -o "$U" -g "$U" plugin/m5pro.touchid/manifest.json plugin/m5pro.touchid/TouchId.qml "$PLUGIN/"
as_user omarchy-plugin-validate "$PLUGIN" && echo "   $PLUGIN valid"
if as_user omarchy-shell shell ping >/dev/null 2>&1; then
  as_user omarchy-shell shell rescanPlugins >/dev/null
  for i in $(seq 1 40); do as_user omarchy-plugin-list --json 2>/dev/null | grep -q '"m5pro.touchid"' && break; sleep 0.05; done
  as_user omarchy-plugin-enable m5pro.touchid || true
else
  echo "   the shell is not running: run 'omarchy plugin enable m5pro.touchid' after logging in"
fi
if [ ! -f "$MENU" ]; then echo "   $MENU missing: menu row not added"
elif grep -q 'm5pro-linux touchid-omarchy' "$MENU"; then echo "   menu row already there"
else
  backup "$MENU"
  python3 - "$MENU" menu/menu-touchid-rows.jsonc <<'EOF'
import re, sys
path, rows = sys.argv[1], open(sys.argv[2]).read().rstrip()
text = open(path).read()
end = text.rindex("}")
body = re.sub(r"//[^\n]*", "", text[:end]).rstrip()
sep = "" if body.endswith(("{", ",")) else ","
open(path, "w").write(text[:end].rstrip() + "\n" + sep + "\n" + rows + "\n" + text[end:])
EOF
  chown "$U:$U" "$MENU"; echo "   Setup > Security > Touch ID added (Quickshell reloads the file by itself)"
fi

if (( REARM )); then say "7. touchid-rearm (opt-in)"; bash rearm/install-rearm.sh "$U"; fi

say "check"
as_user /usr/local/bin/m5pro-touchid status 2>/dev/null | python3 -c 'import json,sys; d=json.loads(sys.stdin.readline()); print("   reader:", d.get("reader"), d.get("reason",""), "| fingers:", [f["id"] for f in d.get("fingers",[])], "| guard:", d.get("guard"), "| rearm:", d.get("rearm"))' || true
echo "   (run over SSH, fprintd answers 'Not Authorized' for the user: the panel runs inside the desktop session)"
