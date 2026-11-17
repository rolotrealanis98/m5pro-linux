# bluetooth-obex

`bluez-obex` (obexd, `obexctl`) so a paired phone can send and receive files over Bluetooth OBEX. It pulls in `libical`. Nothing else changed: no config, no service enabled, `bluetoothd` not restarted. The user service `obex.service` is D-Bus activated on first use.

- Scope: `generic`. Status: installed. Upstream: none (Omarchy's Bluetooth panel has no file-transfer entry; `bluez-obex` is a plain Arch package).
- Install: `OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed bluez-obex` (no -Syu).
- Undo: `OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -R bluez-obex libical` (drop `libical` only if nothing else needs it; pacman says).
- Installed 2026-11-17 for the attended test in `/Volumes/m5pro/bench/requests/bluetooth-1.md`.
