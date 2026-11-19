# Ctrl+Left / Ctrl+Right workspace switching across empty workspaces (2026-11-19)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/37     Kernel: 7.3.0-gc1e08542a544

## What broke
Pressing `Ctrl+Left` / `Ctrl+Right` did not switch workspaces when only workspace `1` was active.

## Cause
`~/.config/hypr/bindings.lua` bound `CTRL + RIGHT` and `CTRL + LEFT` to `hl.dsp.focus({ workspace = "m+1" })` and `hl.dsp.focus({ workspace = "m-1" })`. In Hyprland, `m+1` / `m-1` only cycles through existing (occupied) workspaces on the current monitor, so with a single workspace open (`hyprctl workspaces` showed only workspace `1` on `eDP-2`) there was no second workspace to switch to.

## Fix
1. Updated `~/.config/hypr/bindings.lua` to use `r+1` and `r-1` instead of `m+1` and `m-1`, which navigates sequentially across workspaces on the current monitor including empty ones.
2. Reloaded Hyprland with `hyprctl reload` (`ok`) and checked `hyprctl configerrors` (empty).

## Files changed
`~/.config/hypr/bindings.lua`:
```diff
--- a/.config/hypr/bindings.lua
+++ b/.config/hypr/bindings.lua
@@ -30,7 +30,7 @@
 -- ~/.config/omarchy/plugins/. Ctrl + = toggles it.
 o.bind("CTRL + EQUAL", "Mission Control", { panel = "rolo.mission-control" })
 
--- Ctrl + Left / Right move between workspaces, like macOS Spaces. Same
--- dispatch as Super + Tab / Super + Shift + Tab (workspaces of this monitor).
-o.bind("CTRL + RIGHT", "Next workspace", hl.dsp.focus({ workspace = "m+1" }))
-o.bind("CTRL + LEFT", "Previous workspace", hl.dsp.focus({ workspace = "m-1" }))
+-- Ctrl + Left / Right move between workspaces on this monitor (including empty
+-- ones, like macOS Spaces). Use m+1 / m-1 to cycle only existing workspaces.
+o.bind("CTRL + RIGHT", "Next workspace", hl.dsp.focus({ workspace = "r+1" }))
+o.bind("CTRL + LEFT", "Previous workspace", hl.dsp.focus({ workspace = "r-1" }))
```

## Verified
- `hyprctl reload` returned `ok` and `hyprctl configerrors` returned empty.
- Rolando confirmed `Ctrl+Left` / `Ctrl+Right` works.

## Rollback
Restore `m+1` / `m-1` in `~/.config/hypr/bindings.lua` and run `hyprctl reload`.
