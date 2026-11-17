# m5w-windows

Reboot into Windows once (marker in the PMU scratch byte, read by the alt-slot daily `boot.bin`), with a polkit action and an Omarchy menu plugin, plus a udev rule that hides the Windows partition from udisks. Made by the Windows agent; the script checks the `boot.bin` hash and the partition `nvme0n1p7` it was written for.

- Scope: `j716s`. Status: installed. Upstream: none/personal.
- Install: `sudo contrib/omarchy-mac/install-item.sh --user NAME m5w-windows`. Then: `udevadm control --reload`; add `m5w.reboot-windows` to `plugins` in `~/.config/omarchy/shell.json`.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove m5w-windows` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
