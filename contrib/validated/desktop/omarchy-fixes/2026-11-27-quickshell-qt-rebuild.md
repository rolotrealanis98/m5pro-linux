# Quickshell rebuilt against Qt 6.12.1 (2026-11-27)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/36     Kernel: 7.3.0-g0f96ca644485

## What broke
Every Omarchy shell start logged:
`WARN: Quickshell was built against Qt 6.12.0 but the system has updated to Qt 6.12.1 without rebuilding the package. This is likely to cause crashes, so the quickshell package must be rebuilt.`

## Cause
Omarchy's aarch64 repository still serves `quickshell 0.3.2.r7.g2b4501a-1` (built 2026-10-17 against Qt 6.12.0), while
`omacom/omarchy-pkgs` is at pkgrel 14 for x86_64. Qt moved to 6.12.1 from Arch Linux ARM `extra`. Quickshell uses
private Qt Quick API, which is not guaranteed stable across Qt patch releases, so the warning is a real risk.

## Fix
1. `sudo pacman -S --needed cli11` (header-only makedepend; nothing else changed).
2. `pkgbuilds/quickshell/` from `omacom/omarchy-pkgs` (PKGBUILD pkgrel 14, `load_qtquick_611.patch`,
   `quickshell-layershell-cursor.patch`, `quickshell-check.hook`; the three sha256 sums match the PKGBUILD), built
   with `makepkg -f` on the J716s in about one minute.
3. Installed by Rolando: `sudo pacman -U quickshell-0.3.2.r7.g2b4501a-14-aarch64.pkg.tar.xz` (an approved exception to the
   no-`pacman -U` rule; it replaces only `quickshell`).
4. Shell relaunched from Hyprland on the GPU (`env -u QT_QUICK_BACKEND omarchy-launch-shell`, see
   [2026-11-27-gpu-shell.md](2026-11-27-gpu-shell.md)).

## Files changed
Package `quickshell` 0.3.2.r7.g2b4501a-1 (Omarchy aarch64 repo) -> 0.3.2.r7.g2b4501a-14 (local build, unmodified Omarchy recipe).

## Verified
- `/usr/bin/quickshell --private-check-compat` exits 0 (the old binary printed the warning and exited 1).
- The relaunched shell logs no compatibility warning, has no `QT_QUICK_BACKEND` in its environment and maps `libgallium`
  (GPU); no "GPU work of a client failed" in `dmesg`.
- Mission Control's own `qs` process still runs the old binary until it restarts.

## Rollback
```bash
sudo pacman -U /var/cache/pacman/pkg/quickshell-0.3.2.r7.g2b4501a-1-aarch64.pkg.tar.zst
omarchy restart shell
```
A newer aarch64 build from Omarchy's repository replaces the local one at the next update.
