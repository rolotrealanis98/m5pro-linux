# dmesg-unrestricted

Lets the desktop user read the kernel log (`kernel.dmesg_restrict=0`). Weakens a hardening default: skip it on a shared machine.

- Scope: `generic`. Status: installed. Upstream: none/personal.
- Install: `sudo contrib/omarchy-mac/install-item.sh dmesg-unrestricted`. Then: `sysctl --system`.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove dmesg-unrestricted` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
