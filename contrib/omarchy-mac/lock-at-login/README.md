# lock-at-login

Scope: generic (any Omarchy install with autologin). Status: installed 2026-11-17 (owner's request).

The J716s logs in automatically on tty2, so the lock screen is the gate at boot and after a log out, like macOS's login
window. `m5pro-lock-at-login` (-> `~/.local/bin/`) is started from `~/.config/hypr/autostart.lua`
(`o.launch_on_start("m5pro-lock-at-login")`): it waits for the Omarchy shell, runs `omarchy-system-lock`, and after the
owner unlocks it asks the 1Password Touch ID helper to unlock 1Password (its launch prompt can't show over the lock).

Lock before sleep is Omarchy's own `omarchy-sleep-lock.service` (enabled; a logind delay inhibitor locks before suspend).

Undo: remove the line from `~/.config/hypr/autostart.lua` (backup `autostart.lua.before-lock-at-login`).
