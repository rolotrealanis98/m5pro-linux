# app-render-fixes

Scope: generic (Omarchy on Apple Silicon with the native Gallium GL session). Status: installed 2026-11-17.

- `obsidian.desktop` -> `~/.local/share/applications/`: Obsidian (bundled Electron, Chrome 150) rendered wrongly on native
  GL (mesa-aurora db928e79933d); it runs on zink per app (`MESA_LOADER_DRIVER_OVERRIDE=zink`) while the session stays native.
  Undo: `rm ~/.local/share/applications/obsidian.desktop`.
- `50-libreoffice-wayland.conf` -> `~/.config/environment.d/`: LibreOffice on Hyprland otherwise uses its X11 backend, which
  is blurry/tiny with Omarchy's `xwayland.force_zero_scaling`; `SAL_USE_VCLPLUGIN=gtk3` runs it natively on Wayland at the
  output scale. Undo: delete the file and `systemctl --user unset-environment SAL_USE_VCLPLUGIN`.

Upstream: report the Obsidian/Electron native-GL rendering bug to aurora-silicon/mesa once characterised; the LibreOffice env
is an Omarchy default candidate (envs.lua).
