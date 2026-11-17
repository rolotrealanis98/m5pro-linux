# BlueBubbles desktop client on the J716s (2026-11-17)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/49     Kernel: 7.3.0-gcee93f953357

## What broke
Not a breakage, a setup request: run the BlueBubbles desktop client (iMessage through a BlueBubbles server running on
another Mac). There is no `bluebubbles` package in the Arch ARM repos, and AUR and Flatpak are not available here.

## Cause
- Upstream publishes a native Linux arm64 build: release `v2.1.6+desktop.96` of `BlueBubblesApp/bluebubbles-app`,
  asset `bluebubbles-linux-aarch64.tar.gz` (Flutter, GTK3 embedder).
- `ldd` on the binary showed two missing libraries, both pulled in by the tray plugin through
  `libayatana-appindicator3.so.1` (installed):
  ```
  libayatana-indicator3.so.7 => not found
  libayatana-ido3-0.4.so.0 => not found
  ```
  The plugins' `libflutter_linux_gtk.so => not found` and `libdartjni.so`'s `libjvm.so` are not real gaps (the first
  resolves through the binary's rpath, the second is not loaded on desktop).

## Fix
1. Packages: `sudo pacman -S --needed libayatana-indicator ayatana-ido` (run by Rolando). Transaction preview
   (`pacman -S --print`) listed only those two new packages, no upgrades.
2. App: tarball extracted to `~/.local/opt/bluebubbles/` (unchanged upstream files).
3. `~/.local/bin/bluebubbles`: wrapper, with an opt-in software-GL switch in case the GPU misbehaves.
4. `~/.local/share/applications/bluebubbles.desktop`: launcher entry.

## Files changed
New `~/.local/bin/bluebubbles`:
```bash
#!/bin/bash
# BlueBubbles desktop (aarch64 tarball in ~/.local/opt/bluebubbles).
# BLUEBUBBLES_SOFTWARE_GL=1 bluebubbles  -> render on llvmpipe instead of the GPU.
[ "${BLUEBUBBLES_SOFTWARE_GL:-0}" = 1 ] && export LIBGL_ALWAYS_SOFTWARE=1
cd ~/.local/opt/bluebubbles && exec ./bluebubbles "$@"
```
New `~/.local/share/applications/bluebubbles.desktop`:
```ini
[Desktop Entry]
Name=BlueBubbles
Comment=iMessage via your BlueBubbles server
Exec=~/.local/bin/bluebubbles %U
Icon=~/.local/opt/bluebubbles/data/flutter_assets/assets/icon/icon.png
Terminal=false
Type=Application
Categories=Network;Chat;InstantMessaging;
StartupWMClass=bluebubbles
```
(`~` stands for the absolute home path written in the real file.)

## Verified
- `ldd ~/.local/opt/bluebubbles/bluebubbles`: no missing libraries after the two packages.
- BlueBubbles running on the GPU (native GL session), window up; Rolando reports the GPU is fine.
- `dmesg | grep -E "GPU work of a client failed|recovery fault"`: no lines this boot.
- Not yet verified: the connection to the BlueBubbles server (Rolando starts the server on the Mac and connects himself).

## Rollback
```bash
rm -rf ~/.local/opt/bluebubbles ~/.local/bin/bluebubbles ~/.local/share/applications/bluebubbles.desktop
rm -rf ~/.local/share/bluebubbles ~/.local/share/app.bluebubbles.BlueBubbles   # app data, if present
sudo pacman -Rs libayatana-indicator ayatana-ido
```
