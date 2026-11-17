# app-render-fixes

Scope: generic (Omarchy on Apple Silicon with the native Gallium GL session). Status: installed 2026-11-17.

- `obsidian.desktop` -> `~/.local/share/applications/`: Obsidian (bundled Electron, Chrome 150) rendered wrongly on native
  GL (mesa-aurora db928e79933d); it runs on zink per app (`MESA_LOADER_DRIVER_OVERRIDE=zink`) while the session stays native.
  Undo: `rm ~/.local/share/applications/obsidian.desktop`.
- `50-libreoffice-wayland.conf` -> `~/.config/environment.d/`: LibreOffice on Hyprland otherwise uses its X11 backend, which
  is blurry/tiny with Omarchy's `xwayland.force_zero_scaling`; `SAL_USE_VCLPLUGIN=gtk3` runs it natively on Wayland at the
  output scale. Undo: delete the file and `systemctl --user unset-environment SAL_USE_VCLPLUGIN`.

## Obsidian on native GL: what goes wrong (2026-11-17)
- Symptom: a large pure-black rectangle in the window, typically after a resize. It stays black until that area repaints.
  It appeared in 2 of 10 on-screen launches on native GL and 0 of 2 on zink.
- The driver logs no drops or refusals, and there are no GPU faults. The content is correct when read back through DevTools
  (20 of 20 captures). The hole appears only in what the compositor shows: either an early presentation fence or a
  partial-damage frame that loads stale contents. Write-up: `BUG-aurora-mesa-electron-native-gl.md` (draft, not filed).
- Native-GL candidate: `obsidian --ui-disable-partial-swap`. Every frame then redraws the whole buffer, and it was clean in
  1 of 1 run, which is too few to replace zink. The installed launcher stays on zink.
- `obsidian-native-gl/`: repro tools. `run-ws5.sh` launches one throwaway window on workspace 5 silently and captures that
  toplevel only (`grim -T`). `cdpshot.py` is a stdlib DevTools screenshot. `blkpng.py`/`blk.py` measure pure-black area.
  `glcaps.py` is a headless GL limits query. Hidden-workspace windows do not repaint, so the presentation bug itself needs
  an on-screen run with the owner's OK. That run is `attended-visible.sh` (on the Mac: `sudo bash
  /home/rolo/gpu-ab/obs/attended-visible.sh [N]`): N launches each of default, `ASAHI_MESA_DEBUG=sync`, `nocompress`,
  `noshadow`, `--ui-disable-partial-swap`, plus N/2 zink controls, interleaved; windows open on workspace 5 and the owner
  switches there himself (the script pauses while workspace 5 is not visible, never switches). ~15 s per launch, ~14 min at
  N=10. Clean `sync` = early fence; clean `nocompress`/`noshadow`/partial-swap-off = stale contents on partial redraw.
- `~/.config/obsidian/user-flags.conf` (`-disable-gpu`, `--enable-wayland-ime`) has no effect. This Obsidian package
  (`/usr/bin/obsidian` → `/opt/obsidian/obsidian`, bundled Electron) has no wrapper that reads it.

Upstream: the LibreOffice env is an Omarchy default candidate (envs.lua).
