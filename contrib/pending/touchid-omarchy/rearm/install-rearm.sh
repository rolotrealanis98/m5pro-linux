#!/bin/bash
# Opt-in: Touch ID re-arm after a password (aurora-sep-userspace touchid-rearm at a227a350d7ba).
# NOT run by install.sh unless it is given --with-rearm. Run as root on the MacBook, owner present.
#
# Why: apple_sep locks Touch ID after five failed matches in a row and keeps that lock across
# restarts (/var/lib/aurora-sep-touchid-lockout.bin). Only SEP_BIO_REARM, called with a password
# that PAM just accepted, ends it, and nothing on this machine calls it until this is installed.
# Without it a lockout is permanent (deleting the lockout file is forbidden by the bench rules).
#
# What it changes: builds and installs pam_aurora_touchid.so and /usr/libexec/aurora-touchid-rearm,
# enables aurora-touchid-rearm.socket, and appends one line to /etc/pam.d/system-auth:
#     -auth optional pam_aurora_touchid.so
# (always PAM_IGNORE; never prompts; the leading '-' skips it if the module is missing).
# aurora-touchid-boot.service is installed but NOT enabled: Touch ID keeps working from the first
# login after boot, as it does today.
#
# Enclave effect: the first re-arm (the next sudo/lock-screen/polkit password after this) makes the
# driver create its Linux FileVault-style KEK/VEK pair in the host-state store and a fresh match
# credential. Upstream asks for a backup of all Linux SEP state first; step 1 takes it.
#
# Undo: sed -i '/pam_aurora_touchid.so/d' /etc/pam.d/system-auth (or restore the .before-touchid-rearm
# copy); systemctl disable --now aurora-touchid-rearm.socket; remove the installed files listed below.
set -euo pipefail
REV=a227a350d7ba
U=${1:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" { print $3; exit }')}
[ -n "$U" ] || { echo "pass the desktop user"; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
say() { echo "== $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

say "1. back up Linux SEP and fingerprint state (fprintd stopped, two identical copies)"
BK=/root/touchid-state-before-rearm-$STAMP
umask 077; mkdir -p "$BK"
systemctl stop fprintd.service
for i in 1 2; do
  tar --xattrs --acls -C /var/lib -cf "$BK/state-$i.tar" $(cd /var/lib && ls -d aurora-sep* apple-sep-* fprint 2>/dev/null)
done
systemctl start fprintd.service
cmp "$BK/state-1.tar" "$BK/state-2.tar" || { echo "   the two copies differ: stopping (nothing installed)"; exit 1; }
rm "$BK/state-2.tar"; sha256sum "$BK/state-1.tar" | tee "$BK/SHA256"
echo "   kept in $BK (root only). Restoring needs the previous kernel and all files together; see upstream README."

say "2. build touchid-rearm $REV as $U"
SRC=/home/$U/build/aurora-sep-userspace
if [ ! -d "$SRC/.git" ]; then
  runuser -u "$U" -- git clone -q https://github.com/aurora-silicon/aurora-sep-userspace.git "$SRC"
fi
runuser -u "$U" -- git -C "$SRC" fetch -q origin
runuser -u "$U" -- git -C "$SRC" checkout -q "$REV"
runuser -u "$U" -- make -C "$SRC/touchid-rearm" clean all

say "3. install (PAMDIR /usr/lib/security on Arch)"
make -C "$SRC/touchid-rearm" install PAMDIR=/usr/lib/security PAMCONFDIR=/etc/pam.d UNITDIR=/etc/systemd/system
echo "   /usr/libexec/aurora-touchid-rearm /usr/lib/security/pam_aurora_touchid.so /etc/pam.d/aurora-touchid-rearm"
echo "   /etc/systemd/system/aurora-touchid-rearm.socket aurora-touchid-rearm@.service aurora-touchid-boot.service (not enabled)"
echo "   /etc/aurora/touchid.conf /usr/share/doc/aurora-touchid-rearm/README.md"
systemctl daemon-reload
systemctl enable --now aurora-touchid-rearm.socket

say "4. system-auth: re-arm after an accepted password (backup .before-touchid-rearm)"
if grep -q pam_aurora_touchid.so /etc/pam.d/system-auth; then
  echo "   already there"
else
  cp -p /etc/pam.d/system-auth /root/system-auth.before-touchid-rearm
  # Arch's system-auth falls through on a pam_unix success: the module goes after the last auth line.
  last=$(grep -n '^[[:space:]]*-\?auth[[:space:]]' /etc/pam.d/system-auth | tail -1 | cut -d: -f1)
  sed -i "${last}a -auth      optional                    pam_aurora_touchid.so" /etc/pam.d/system-auth
  grep -n 'auth' /etc/pam.d/system-auth
fi

say "5. check"
/usr/libexec/aurora-touchid-rearm --status || true
cat <<'EOF'
   Owner test, at the machine:
     a) Open a terminal, run `sudo -k; sudo true`, press Esc/wait past the fingerprint prompt and type
        the password. journalctl -t aurora-touchid-rearm shows the re-arm; journalctl -k | grep -i re-arm.
     b) `sudo -k; sudo true` again and touch Touch ID: it must still match.
   If (b) fails, restore system-auth from /root/system-auth.before-touchid-rearm and report.
EOF
