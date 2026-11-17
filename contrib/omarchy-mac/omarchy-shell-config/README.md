# omarchy-shell-config

Omarchy shell settings (bar layout, idle lock at 300 s with the screensaver off, plugin list), font size, the menu extension (macOS boot, Windows boot, battery charge limit) and the About text. The bar layout and clock cities are the owner's taste: change them before reuse.

- Scope: `j716s`. Status: installed. Upstream: none/personal; menu rows to Omarchy itself.
- Install: `sudo contrib/omarchy-mac/install-item.sh --user NAME omarchy-shell-config`. Overwrites `shell.json`: merge by hand on a machine with its own settings.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove omarchy-shell-config` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
