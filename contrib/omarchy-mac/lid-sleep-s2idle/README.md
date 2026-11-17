# lid-sleep-s2idle

Lid close suspends to idle (s2idle); hibernate, hybrid sleep and suspend-then-hibernate stay off.

- Scope: `t6050`. Status: installed. Upstream: none (alarm-aurora `aurora-system-fixes` for the T6050 enablement).
- Install: `sudo contrib/omarchy-mac/install-item.sh lid-sleep-s2idle`. Then: `systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target systemd-hibernate.service systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service` and log out (or reboot). Needs the kernel's s2idle path (proven on the daily kernel).
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove lid-sleep-s2idle` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
