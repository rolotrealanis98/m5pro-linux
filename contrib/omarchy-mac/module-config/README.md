# module-config

Blacklists `apple_isp` (no ISP driver in use) and loads `thunderbolt_net` for host-to-host links. The `apple_sep` options belong to the Touch ID work and are tracked in `contrib/pending/touchid-omarchy/`.

- Scope: `t6050`. Status: installed. Upstream: none for `thunderbolt_net`; `apple_isp` blacklist: alarm-aurora `aurora-system-fixes` later.
- Install: `sudo contrib/omarchy-mac/install-item.sh module-config`. Then: reboot, or `modprobe thunderbolt_net`.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove module-config` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
