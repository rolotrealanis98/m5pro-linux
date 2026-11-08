# Omarchy menu: "Reboot into macOS" and a Startup Disk submenu (2026-11-08)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/4     Kernel: 7.3.0-g36845aa5f650

## What broke
Nothing broke. Rolando asked for the Mac Studio's "reboot into macOS" and "Startup Disk" rows in the Omarchy
(Quickshell) System menu, without the Studio's boot-timing tunings.

## Cause
A port, not a copy. The Studio's `27-startup-disk.sh` assumes four things that are false on this machine:
- `asahi-bless` from the Asahi repo. It is not packaged here (`pacman -Si asahi-bless`: not found); issue #4 plans a
  pinned cargo build of `asahi-nvram`.
- `/dev/mtd/by-name/nvram`. Here the NVRAM is `/dev/mtd2` (root only, no by-name links).
- A passwordless sudoers rule. Nothing is passwordless here, and a rule would let root run a script out of a
  user-writable checkout.
- `omarchy-system-reboot`. It does not exist in Omarchy 4.5; the helper is `omarchy-system reboot`.
Also: no NVRAM write has ever been done on this machine (`nvram.write` is `untested`, issue #4) and the driver
refuses writes until the module with the J716s board row (m5pro-linux `contrib/pending/nvram`, patch 0002) is loaded.
The prepared, guarded path is `nvram-next-boot.sh`, which writes only `alt-boot-volume` (next boot only).

## Fix
User level only. Nothing under `/boot`, no kernel, module, firmware or NVRAM was touched, and nothing was rebooted.
1. Backed up `~/.config/omarchy/extensions/omarchy-menu.jsonc` to `.pre-startup-disk`.
2. Added `~/.local/bin/omarchy-startup-disk` (`status | reboot-macos | clear-next`). It only calls
   `sudo bash nvram-next-boot.sh <cmd>`, so the script's own guards decide (read-only probe passed, NVRAM unchanged since,
   driver armed, only `alt-boot-volume` written, read-back compared) and it asks for `WRITE`. `reboot-macos` then asks
   before running `omarchy-system reboot`. A menu click has no terminal, so the wrapper re-runs itself in
   `omarchy-launch-floating-terminal-with-presentation` where sudo can prompt.
3. Added four rows to the user menu extension: System > Reboot into macOS, and System > Startup Disk > Show boot target /
   Cancel pending macOS boot. Quickshell watches that file, so no shell restart is needed.
Deliberately not done: a row that sets the default startup disk (`boot-volume`). That write is not covered by the
prepared path, and the plan keeps the stub (Omarchy) as the default and macOS as the one-time exception
(`docs/plan/FRICTION.md`, P9).

## Files changed
- `~/.local/bin/omarchy-startup-disk` -> new; copy in `omarchy-fixes/files/2026-11-08-startup-disk-menu/omarchy-startup-disk`.
- `~/.config/omarchy/extensions/omarchy-menu.jsonc` ->

```diff
--- ~/.config/omarchy/extensions/omarchy-menu.jsonc.pre-startup-disk	2026-11-05 03:09:34.000000000 +0000
+++ ~/.config/omarchy/extensions/omarchy-menu.jsonc	2026-11-08 11:23:08.718695933 +0000
@@ -27,4 +27,11 @@
   // Example: replace the default About action by reusing the same id. Existing
   // fields are kept unless overridden.
   // "about": {"icon":"","label":"About","action":"omarchy-launch-or-focus-tui \"zsh -c 'fastfetch; read -k 1'\""},
+
+  // Boot macOS once, from System. omarchy-startup-disk wraps nvram-next-boot.sh (m5pro-linux, tracker issue #4):
+  // it asks for the sudo password and for WRITE, and refuses until the NVRAM write path has been proven attended.
+  "system.reboot-macos": {"icon":"󰜉","label":"Reboot into macOS","description":"One time only, the default boot stays Omarchy","aliases":["macos","boot-macos"],"action":"omarchy-startup-disk reboot-macos"},
+  "system.startup-disk": {"icon":"󰋊","label":"Startup Disk","aliases":["startup-disk","boot-disk"],"description":"Pending one-time boot target"},
+  "system.startup-disk.status": {"icon":"󰋽","label":"Show boot target","description":"What the next boot will use","action":"omarchy-startup-disk status"},
+  "system.startup-disk.clear-next": {"icon":"󰜺","label":"Cancel pending macOS boot","description":"Remove the one-time target","action":"omarchy-startup-disk clear-next"}
 }
```

## Verified
- The menu file parses as JSONC; four ids, and all four icons are valid Nerd Font code points
  (U+F0709, U+F02CA, U+F02FD, U+F073A). One icon was first written as an empty string and fixed with a \u escape.
- `bash -n` passes on the wrapper; `omarchy-startup-disk bogus` prints its usage line and exits 1 with no sudo and no NVRAM access.
- `Menu.qml` loads the user file through a `FileView` with `watchChanges: true`.
- NOT verified: that the rows render in the menu (nobody opened it); a click (needs the sudo password, and
  `nvram-next-boot.sh` refuses without its `probe.pass` marker, so today it ends in a REFUSED line); the NVRAM write
  itself and the return from macOS to Linux (one-shot consumption by iBoot is unverified on M5). Those are issue #4.

## Rollback
```bash
cp -a ~/.config/omarchy/extensions/omarchy-menu.jsonc.pre-startup-disk ~/.config/omarchy/extensions/omarchy-menu.jsonc
rm ~/.local/bin/omarchy-startup-disk
```
