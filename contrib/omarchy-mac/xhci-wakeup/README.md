# xhci-wakeup

Enable wakeup on xhci platform devices until the device tree does it.

- Scope: `t6050`. Status: installed. Upstream: aurora-silicon/linux (device tree wakeup-source), alarm-aurora `aurora-system-fixes` meanwhile.
- Install: `sudo contrib/omarchy-mac/install-item.sh xhci-wakeup`. Then: `udevadm control --reload && udevadm trigger -s platform`.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove xhci-wakeup` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
