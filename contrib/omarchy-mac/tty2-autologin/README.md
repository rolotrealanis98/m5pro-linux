# tty2-autologin

Autologin of the desktop user on tty2 and a VT switch before Hyprland starts (aquamarine waits 5 s for the session). `@USER@` is replaced by the `--user` name.

- Scope: `j716s`. Status: installed. Upstream: none/personal.
- Install: `sudo contrib/omarchy-mac/install-item.sh --user NAME tty2-autologin`. Then: `systemctl daemon-reload`; takes effect at the next boot. Omarchy's own login path is the supported one; use this only for the bring-up console launch.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove tty2-autologin` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
