# startup-disk

Scope: t6050 (J716s; the NVRAM tools are J716s-specific). Status: built 2026-11-17, installed when the Mac is back on Linux.

Frictionless "Reboot into macOS" and a Startup Disk menu for Omarchy, at the owner's request: no terminal, no sudo
password, no `WRITE` confirmation. Typing "reboot to macos" in the Omarchy menu finds the row.

- `m5pro-startup-disk` -> `/usr/local/sbin/` (root): reruns the read-only NVRAM probe (macOS and iBoot rewrite NVRAM on
  their boots, which made the old flow refuse after every round trip), then sets or clears the one-time `alt-boot-volume`
  through `nvram-next-boot.sh` with all its checks (read-back must show exactly one added/removed variable, in place,
  bit-clear only). Never writes the default `boot-volume`.
- `org.m5pro.startup-disk.policy` -> polkit: the active local session runs the helper without a prompt (SSH and
  inactive sessions still need admin).
- `omarchy-startup-disk` -> `~/.local/bin/`: menu front end with notifications.
- `menu-rows.jsonc`: replaces the old System rows (Reboot into macOS; Startup Disk: macOS at next restart, Omarchy
  (cancel one-time), Show).
- Tool copies in `/usr/local/lib/m5pro/nvram/` (root-owned; the old flow ran them from a user-writable checkout).

Install: `bash install.sh /root/nvram-j716s`. Undo: `bash install.sh --uninstall`.

Not done on purpose: changing the default startup volume. That writes `boot-volume`, which is not an in-place bit-clear
update (it needs an erase of an NVRAM sector), and the standing rule on this machine is never `--set-boot` without
`--next`. One-time targets cover quick switching; the permanent default stays a macOS Startup Disk / hold-power choice
until the owner decides otherwise.
