# Mission Control overview, Ctrl+= and Ctrl+arrow workspace keys (2026-11-08)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/37     Kernel: 7.3.0-g36845aa5f650

## What broke
Not a bug: a missing feature. Rolando wanted the macOS habits on the MacBook: a three-finger-up swipe and Ctrl+= that show an
overview of workspaces and windows (Mission Control), and Ctrl+Left / Ctrl+Right to move between workspaces (Spaces).
Hyprland has no overview of its own, and three-finger-up was the scratchpad gesture.

## Cause
Nothing was broken. Design choices, from the evidence on the machine:
- Hyprland 0.57.1 has no overview and `hyprpm` is not installed. A compositor plugin (hyprexpo, Hyprview) must be built against
  the exact Hyprland headers, and a plugin fault takes the whole session down, so it was not used.
- The Omarchy shell (Quickshell 0.3.2) loads user plugins from `~/.config/omarchy/plugins/` and has an `overlay` plugin kind
  (the emoji picker and clipboard manager use it). An overlay needs no compositor change and survives Hyprland updates.
- Quickshell can show live window thumbnails with `ScreencopyView` (Wayland screencopy: Hyprland renders each window into a
  buffer the shell imports on the GPU). Nothing in the repos or the tracker validates that path on the Aurora GPU (only
  `grim` output capture), and a GPU fault there would crash Hyprland and every open app (the known crash class). So it ships
  switched off (`liveThumbnails: false`); tiles show the app icon and window title.

## Fix
1. Wrote the overlay plugin `rolo.mission-control` (manifest + one QML file + English strings), validated with
   `omarchy plugin validate`, enabled with `omarchy plugin enable rolo.mission-control`. It shows the monitor's workspaces as a
   strip along the top (numbered like the bar, plus a "+" tile for the first free slot) and the previewed workspace's windows
   as tiles below. Click a window to focus it, click a workspace to go there, Esc or a click outside closes; arrows / Enter /
   Tab / digits work from the keyboard.
2. `~/.config/hypr/bindings.lua`: `Ctrl+=` toggles the plugin, `Ctrl+Right` / `Ctrl+Left` run the same dispatch as
   Super+Tab / Super+Shift+Tab (`hl.dsp.focus({ workspace = "m+1" })` / `"m-1"`, the monitor's occupied workspaces).
3. `~/.config/hypr/m5pro-dcp.lua` and `m5pro.lua`: the three-finger-up gesture now runs
   `omarchy-shell shell toggle rolo.mission-control`. Both files are on the brief's protected list (rule 2); Rolando approved
   changing these two gesture lines explicitly in chat. Only the comment and that one line changed. The scratchpad is still on
   Super+S. The trackpad preset and `hyprland.lua` were not touched.
4. `hyprctl reload`; `hyprctl configerrors` is empty.

## Files changed
Backups next to each edited file: `<file>.pre-mission-control`.

`~/.config/hypr/bindings.lua`:
```diff
--- ~/.config/hypr/bindings.lua.pre-mission-control	2026-11-05 03:09:34.000000000 +0000
+++ ~/.config/hypr/bindings.lua	2026-11-08 11:21:17.224057026 +0000
@@ -25,3 +25,12 @@
 -- Logitech MX Keys examples:
 -- o.bind("SUPER + H", nil, "voxtype record toggle")
 -- o.bind("SUPER + PERIOD", nil, { panel = "omarchy.emojis" })
+
+-- Mission Control (macOS-style overview), shell plugin rolo.mission-control in
+-- ~/.config/omarchy/plugins/. Ctrl + = toggles it.
+o.bind("CTRL + EQUAL", "Mission Control", { panel = "rolo.mission-control" })
+
+-- Ctrl + Left / Right move between workspaces, like macOS Spaces. Same
+-- dispatch as Super + Tab / Super + Shift + Tab (workspaces of this monitor).
+o.bind("CTRL + RIGHT", "Next workspace", hl.dsp.focus({ workspace = "m+1" }))
+o.bind("CTRL + LEFT", "Previous workspace", hl.dsp.focus({ workspace = "m-1" }))
```

`~/.config/hypr/m5pro-dcp.lua`:
```diff
--- ~/.config/hypr/m5pro-dcp.lua.pre-mission-control	2026-11-08 02:45:11.997014817 +0000
+++ ~/.config/hypr/m5pro-dcp.lua	2026-11-08 11:32:29.901849081 +0000
@@ -111,7 +111,8 @@
   },
 })
 
--- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 3 up = scratchpad, 4 down = fullscreen.
+-- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 3 up = Mission Control, 4 down = fullscreen.
+-- (3 up was the scratchpad; that stays on Super + S. Mission Control is the shell plugin rolo.mission-control.)
 hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
-hl.gesture({ fingers = 3, direction = "up", action = "special", workspace_name = "scratchpad" })
+hl.gesture({ fingers = 3, direction = "up", action = function() hl.exec_cmd("omarchy-shell shell toggle rolo.mission-control") end })
 hl.gesture({ fingers = 4, direction = "down", action = "fullscreen" })
```

`~/.config/hypr/m5pro.lua`:
```diff
--- ~/.config/hypr/m5pro.lua.pre-mission-control	2026-11-07 20:52:50.428598133 +0000
+++ ~/.config/hypr/m5pro.lua	2026-11-08 11:32:30.157850305 +0000
@@ -16,7 +16,8 @@
   },
 })
 
--- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 3 up = scratchpad, 4 down = fullscreen.
+-- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 3 up = Mission Control, 4 down = fullscreen.
+-- (3 up was the scratchpad; that stays on Super + S. Mission Control is the shell plugin rolo.mission-control.)
 hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
-hl.gesture({ fingers = 3, direction = "up", action = "special", workspace_name = "scratchpad" })
+hl.gesture({ fingers = 3, direction = "up", action = function() hl.exec_cmd("omarchy-shell shell toggle rolo.mission-control") end })
 hl.gesture({ fingers = 4, direction = "down", action = "fullscreen" })
```

New plugin, copied under `omarchy-fixes/files/2026-11-08-mission-control/` (install to
`~/.config/omarchy/plugins/rolo.mission-control/`): `manifest.json`, `MissionControl.qml`, `i18n/en.json`.

## Verified
Seen on the machine, from the agent session:
- `omarchy plugin validate` passes; `omarchy plugin list` shows the plugin enabled.
- `hyprctl reload` + `hyprctl configerrors`: empty, after the bindings edit and again after the gesture edit.
- `hyprctl -j binds` lists the three new binds (CTRL+EQUAL exec, CTRL+RIGHT and CTRL+LEFT focus).
- `omarchy-shell shell toggle rolo.mission-control` maps a fullscreen layer `omarchy-mission-control` (1728x1117) and removes it
  on the second call. A `grim` screenshot of the open overlay showed the workspace strip (card labelled 1, "+ New workspace")
  and one tile per window with app icon and title, over the dimmed desktop.
- `hl.dsp.focus({ workspace = "m-1" })` from empty workspace 2 lands on workspace 1. With one occupied workspace, `m+1` / `m-1`
  stay put, exactly like the existing Super+Tab.
- `hyprctl eval 'hl.exec_cmd("true")'` is accepted, so the gesture's Lua function is valid.

**Not verified** (needs Rolando's hands):
- A physical Ctrl+=, Ctrl+Left and Ctrl+Right. `wtype`-injected keys do not trigger any Hyprland bind on this machine, not even
  the stock Super+S, so chords cannot be tested from a script; the binds were checked by registration and by running their dispatch.
- The physical three-finger-up swipe. Hyprland's Lua function-action gestures were not exercised by a real swipe.
- Keyboard and mouse handling inside the open overlay (Esc, arrows, Enter, clicks): written, not exercised.
- Live thumbnails: off, never run. The `grim` screenshot had the tiles on the icon fallback by design.

Side notes seen along the way: Ctrl+Left / Right and Ctrl+= are now taken from every app (word-jump in terminals and editors,
browser zoom-in). Active workspace was 11 before the first `hyprctl reload` and 1 after it (windows all present); cause not
investigated, it looks like Omarchy's per-monitor workspace reconcile.

## Rollback
```bash
cd ~/.config/hypr
cp -a bindings.lua.pre-mission-control bindings.lua
cp -a m5pro-dcp.lua.pre-mission-control m5pro-dcp.lua
cp -a m5pro.lua.pre-mission-control m5pro.lua
hyprctl reload
omarchy plugin disable rolo.mission-control
rm -r ~/.config/omarchy/plugins/rolo.mission-control      # optional
```
To turn live thumbnails on later, with the machine's owner at the keyboard and work saved, set `liveThumbnails: true` at the
top of `MissionControl.qml`; if the GPU faults, `dmesg` shows `GPU work of a client failed` naming the shell.
