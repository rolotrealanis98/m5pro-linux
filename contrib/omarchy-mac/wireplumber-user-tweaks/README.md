# wireplumber-user-tweaks

Two WirePlumber fragments: auto-connect A2DP profiles on Bluetooth devices, and never suspend one USB speaker's sink (its firmware stops answering after idle until replugged).

- Scope: `generic`. Status: installed. Upstream: A2DP file: omacom/omarchy-mac-pkgs `share/wireplumber`; the USB-speaker file is personal.
- Install: `sudo contrib/omarchy-mac/install-item.sh --user NAME wireplumber-user-tweaks`. Then: `systemctl --user restart wireplumber`.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove wireplumber-user-tweaks` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
