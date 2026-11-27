# quickshell (local aarch64 rebuild)

Omarchy's recipe from `omacom/omarchy-pkgs` `pkgbuilds/quickshell/` (pkgrel 14), unmodified, kept here because Omarchy's
aarch64 repository lagged at pkgrel 1 (built against Qt 6.12.0). Rebuild whenever Qt moves and Omarchy has no new aarch64
build (`quickshell --private-check-compat` exits 1 and prints a COMPATIBILITY WARNING):

```bash
sudo pacman -S --needed cli11 vulkan-headers wayland-protocols   # makedepends
makepkg -f                                                       # in a copy of this directory
sudo pacman -U quickshell-*-aarch64.pkg.tar.*                    # Rolando's call (brief rule 8)
```

Then relaunch the shell and Mission Control (`systemctl --user restart mission-control.service`). Write-up:
`contrib/validated/desktop/omarchy-fixes/2026-11-27-quickshell-qt-rebuild.md`.
