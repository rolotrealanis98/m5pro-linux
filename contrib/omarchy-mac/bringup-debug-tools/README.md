# bringup-debug-tools

Leak and memory probes and `hyprctl-rolo`, a helper that runs a command inside the desktop user's Hyprland session from root over SSH (the user is now `DESKTOP_USER` or the first normal account, not hard-coded).

- Scope: `j716s`. Status: installed. Upstream: none.
- Install: `sudo contrib/omarchy-mac/install-item.sh bringup-debug-tools`. 
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove bringup-debug-tools` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
