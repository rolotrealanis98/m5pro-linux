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

Default startup volume (added 2026-11-17 at the owner's request, after studying the write path; full study:
`/Volumes/m5pro/bench/requests/nvram-default-1.md`): `m5pro-startup-disk default-test|default macos|omarchy|NAME`, through
`contrib/pending/nvram/tools/nvram-default-boot.sh`. The earlier note here was wrong: with asahi-nvram's v3 writer a new
default is an in-place, bit-clear-only update of the active bank (old entry's state byte 0x7f -> 0x7c plus one appended
entry; no erase, no new generation), the same kind of write as the one-time target. The tool refuses anything else
(bank rotation, an asahi-nvram/XNU bank disagreement, a non-identical re-serialisation), needs AC and battery >= 50 %,
keeps root-only backups, and accepts only a read-back that is the model's exact bytes. The remaining risk is a torn
write in a window of a few page programs, during which no boot-volume is live; recovery is iBoot's Startup Options
("Always Use"), macOS Startup Disk, 1TR, DFU.

- `menu-rows-default.jsonc`: "Always start: macOS" / "Always start: Omarchy". Installed only with
  `bash install.sh /root/nvram-j716s [USER] --with-default`, after the attended first default writes passed.
- A failed default write leaves `/var/lib/nvram-t6050/write.blocked`; every write command refuses until it is removed by hand.
- Windows is not a startup volume: it is a one-time m1n1 choice from the Omarchy stub's ESP (`m5w-windows`, PMU scratch
  byte), so it is not offered as a default.
