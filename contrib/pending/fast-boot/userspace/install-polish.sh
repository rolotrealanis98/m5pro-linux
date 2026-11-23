#!/bin/bash
# install-polish.sh (round 2): stop the boot-time login prompt on tty1, so the panel shows no text between the kernel and Hyprland.
#   bash install-polish.sh            as root on the J716s
#   bash install-polish.sh --undo     put the symlink back
# getty@tty1 is started at every boot by getty.target (symlink /etc/systemd/system/getty.target.wants/getty@tty1.service) and
# draws "m5pro login:" on VT1, which is the VT showing while the autologin getty on tty2 starts. Without the symlink VT1 stays
# empty. The emergency login is kept: logind starts autovt@tty1 when you switch to VT1 (Ctrl+Alt+F1; NAutoVTs=6 covers 1-6), and
# tty2 keeps its autologin. To verify after the next boot: Ctrl+Alt+F1 shows a login prompt (if it does not, run --undo).
# Restarts nothing, writes nothing outside /etc/systemd/system/getty.target.wants and /var/lib/m5pro-fast-boot; no rm -rf.
set -euo pipefail
L=/etc/systemd/system/getty.target.wants/getty@tty1.service; BK=/var/lib/m5pro-fast-boot/tty1-link
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
case "${1:-}" in
  --undo) [ -r "$BK" ] || { echo "nothing to undo"; exit 1; }
          ln -sfn "$(cat "$BK")" "$L"; systemctl daemon-reload; mv -f "$BK" "$BK.undone"; echo "restored $L -> $(readlink "$L")" ;;
  "")     [ -L "$L" ] || { echo "$L is not a symlink here: nothing to do" >&2; exit 1; }
          install -d -m 0700 /var/lib/m5pro-fast-boot; readlink "$L" > "$BK"
          rm -f "$L"; systemctl daemon-reload; echo "removed $L (was -> $(cat "$BK")); applies at the next boot. Undo: bash $0 --undo" ;;
  *) echo "usage: $0 [--undo]" >&2; exit 2 ;;
esac
