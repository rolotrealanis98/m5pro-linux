# Omarchy menu "Reboot into macOS": say why it refuses (2026-11-16)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/47     Kernel: 7.3.0-g1052a5f7849e
## What broke
System menu > "Reboot into macOS" asked for the sudo password and then ended in a bare refusal, so it looked broken.
## Cause
Not a fault. `omarchy-startup-disk reboot-macos` runs `nvram-next-boot.sh to-macos`, which refuses until the first attended
NVRAM write (tracker issue #4) has been done; the 2026-11-08 fix doc already said so. Read-only checks today: `asahi-bless`
is not installed, and `spi-apple-qspi.ko` has no J716s board-row strings (inferred from `strings`, not tested).
Whether `/var/lib/nvram-t6050/probe.pass` exists is unknown (root-only). The wrapper only exited non-zero, so the message was
easy to miss.
## Fix
User level only; no NVRAM, boot, kernel or module access, no reboot.
1. Backed up `~/.local/bin/omarchy-startup-disk` to `.pre-readable-refusal`.
2. `preflight_macos`: `reboot-macos` stops before the password prompt while `asahi-bless` is not on PATH, and says why.
3. `run_next`: wraps every `sudo bash nvram-next-boot.sh <cmd>`. On a non-zero exit it prints what the stop means
   (REFUSED = a guard stopped it before any write; UNEXPECTED CHANGE or WARNING = do not reboot; neither = the password
   was not accepted) and the power-button route. It deliberately does not claim "nothing was changed", since a failed
   read-back after a write also exits 1. The success path is unchanged.
4. The menu file is unchanged.
## Files changed
- `~/.local/bin/omarchy-startup-disk`: copy in `omarchy-fixes/files/2026-11-16-startup-disk-readable-refusal/omarchy-startup-disk`.

```diff
--- ~/.local/bin/omarchy-startup-disk.pre-readable-refusal	2026-11-08 11:22:29.290763914 +0000
+++ ~/.local/bin/omarchy-startup-disk	2026-11-16 09:46:38.254035298 +0000
@@ -7,7 +7,9 @@
 # That script is the only thing that touches NVRAM: it writes alt-boot-volume (the one-shot "next boot only"
 # target) and nothing else, and it refuses unless the read-only probe passed, the NVRAM is unchanged since,
 # and the spi_apple_qspi module carries the J716s write row. Until the attended sitting in issue #4 has made
-# that true, every command here ends in a REFUSED line and changes nothing.
+# that true, the guarded script ends in a REFUSED line and changes nothing. This wrapper then says so in plain
+# words (run_next) instead of just closing, and reboot-macos stops before the password prompt while asahi-bless
+# is not installed (preflight_macos).
 #
 # No sudoers rule on purpose: root would be running a script from a user-writable checkout, so sudo asks for
 # the password each time, and nvram-next-boot.sh asks you to type WRITE before it programs anything.
@@ -30,21 +32,57 @@
   exec omarchy-launch-floating-terminal-with-presentation "$(printf '%q ' "$0" "$cmd")"
 }
 
+boot_by_hand() {
+  echo "To boot macOS today: restart, hold the power button until the startup options appear,"
+  echo "then pick Macintosh HD. Omarchy stays the default startup disk."
+}
+
+# Runs before any password prompt: reboot-macos cannot work without asahi-bless, so say so up front.
+preflight_macos() {
+  command -v asahi-bless >/dev/null 2>&1 && return 0
+  echo "Booting macOS from this menu is not enabled on this machine yet."
+  echo
+  echo "  - asahi-bless is not installed, and the next-boot write needs it."
+  echo "  - The first NVRAM write is planned as an attended test: tracker issue #4."
+  echo
+  echo "No password was asked and nothing was touched."
+  echo
+  boot_by_hand
+  exit 1
+}
+
+# Run the guarded NVRAM script as root. If it stops, say what the stop means instead of just ending.
+run_next() {
+  local rc=0
+  sudo bash "$NEXT" "$@" || rc=$?
+  if (( rc == 0 )); then return 0; fi
+  echo
+  echo "omarchy-startup-disk: the guarded script stopped (exit $rc). Read the lines above."
+  echo "  - A line starting REFUSED means a guard stopped it before anything was written; it names the guard."
+  echo "    Until the attended write test in tracker issue #4 is done, expect this."
+  echo "  - UNEXPECTED CHANGE or WARNING means do not reboot: check the NVRAM first (issue #4)."
+  echo "  - Neither of those: sudo did not accept the password. Try again."
+  echo
+  boot_by_hand
+  return "$rc"
+}
+
 case "$cmd" in
   status)
     need_terminal
-    sudo bash "$NEXT" status
+    run_next status
     ;;
   clear-next)
     need_terminal
-    sudo bash "$NEXT" clear-next
+    run_next clear-next
     ;;
   reboot-macos)
     need_terminal
+    preflight_macos
     echo "Reboot into macOS, one time. The default boot stays Omarchy."
     echo
     # Prompts you to type WRITE; a refusal or a failed read-back exits non-zero and we stop here.
-    sudo bash "$NEXT" to-macos
+    run_next to-macos
     echo
     echo "If iBoot consumes the one-shot, the restart after macOS comes back to Omarchy."
     echo "That return leg is not verified on this machine yet; if macOS comes up again,"
```
## Verified
- `bash -n` passes; `omarchy-startup-disk bogus` prints usage, exit 1.
- `reboot-macos` under a pty (`script -qec`): stops at the preflight with the explanation, exit 1, no sudo call.
- A scratch copy with `sudo` removed and a fake guarded script: a REFUSED stop prints the explanation and exits 1; a
  successful run prints nothing extra and exits 0.
- NOT verified: a real menu click (it would open a window on the desktop), the sudo path, and anything on the NVRAM side.
  No sudo was run and the NVRAM was not read or written. Seen by Rolando: not yet.
## Rollback
```bash
cp -a ~/.local/bin/omarchy-startup-disk.pre-readable-refusal ~/.local/bin/omarchy-startup-disk
```
