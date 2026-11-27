# hyprland-m5pro-profile

Hyprland config for the M5 Pro: profile pick between `m5pro` and `m5pro-dcp`, panel mode, software-effects-off defaults, the 3456x2234 panel at scale 2, Mission Control and workspace binds, the generated pointer tuning, `m5pro-desktop omarchy|lite|status`. Quickshell's software backend (`environment.d/90-m5pro-quickshell.conf`) was removed on 2026-11-27: the shell draws on the GPU (`contrib/validated/desktop/omarchy-fixes/2026-11-27-gpu-shell.md`). `m5pro-dcp.lua` and the trackpad presets are tracked elsewhere (`contrib/pending/gpu/userspace/mesa-aurora/session-dcp/`, `contrib/validated/desktop/trackpad/`).

- Scope: `j716s`. Status: installed. Upstream: Omarchy itself for generic binds and gestures; the rest personal.
- Install: `sudo contrib/omarchy-mac/install-item.sh --user NAME hyprland-m5pro-profile`. Replaces the user's `~/.config/hypr/*.lua` (backed up): read the diff first. Log out and back in.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove hyprland-m5pro-profile` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
