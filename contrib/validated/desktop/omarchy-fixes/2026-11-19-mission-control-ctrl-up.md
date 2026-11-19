# Re-enable Mission Control, bind Ctrl+Up, and restore 3-finger-up swipe (2026-11-19)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/37     Kernel: 7.3.0-gc1e08542a544

## What broke
Mission Control (`rolo.mission-control`) was not opening on `Ctrl+Up` or on a three-finger swipe up on the trackpad.

## Cause
Proven on the live machine:
- `~/.config/omarchy/plugins/rolo.mission-control` was still installed and valid (`omarchy plugin validate` exited 0), but it was disabled (`enabled: false` in `omarchy-shell shell listPlugins`) because it had been dropped from `~/.config/omarchy/shell.json` `plugins[]` (as previously noted in `2026-11-16-image-picker-software.md`).
- `~/.config/hypr/bindings.lua` only bound `CTRL + EQUAL` to `rolo.mission-control`, not `CTRL + UP` (nothing was bound to `CTRL + UP`).
- `~/.config/hypr/m5pro-dcp.lua` (active DCP display profile) had reverted the three-finger-up gesture back to `special` / `scratchpad`, whereas `~/.config/hypr/m5pro.lua` already toggled `rolo.mission-control`.

## Fix
1. Backed up `~/.config/omarchy/shell.json` (`shell.json.pre-mission-control-re-enable`) and ran `omarchy plugin enable rolo.mission-control`.
2. Backed up `~/.config/hypr/bindings.lua` (`bindings.lua.pre-mission-control-ctrl-up`) and added `o.bind("CTRL + UP", "Mission Control", { panel = "rolo.mission-control" })` alongside `CTRL + EQUAL`.
3. With Rolando's explicit approval in chat (because `m5pro-dcp.lua` is on the brief's protected list), backed up `~/.config/hypr/m5pro-dcp.lua` (`m5pro-dcp.lua.pre-mission-control-swipe-up`) and updated the three-finger-up gesture line to run `omarchy-shell shell toggle rolo.mission-control` (scratchpad remains on `Super + S`).
4. Ran `hyprctl reload` and `hyprctl configerrors`.

## Files changed
`~/.config/omarchy/shell.json` (backup `shell.json.pre-mission-control-re-enable`):
```diff
--- ~/.config/omarchy/shell.json.pre-mission-control-re-enable
+++ ~/.config/omarchy/shell.json
@@ -129,6 +129,9 @@
     },
     {
       "id": "m5pro.touchid"
+    },
+    {
+      "id": "rolo.mission-control"
     }
   ],
   "version": 1
```

`~/.config/hypr/bindings.lua` (backup `bindings.lua.pre-mission-control-ctrl-up`):
```diff
--- ~/.config/hypr/bindings.lua.pre-mission-control-ctrl-up
+++ ~/.config/hypr/bindings.lua
@@ -27,7 +27,8 @@
 -- o.bind("SUPER + PERIOD", nil, { panel = "omarchy.emojis" })
 
 -- Mission Control (macOS-style overview), shell plugin rolo.mission-control in
--- ~/.config/omarchy/plugins/. Ctrl + = toggles it.
+-- ~/.config/omarchy/plugins/. Ctrl + Up (and Ctrl + =) toggle it.
+o.bind("CTRL + UP", "Mission Control", { panel = "rolo.mission-control" })
 o.bind("CTRL + EQUAL", "Mission Control", { panel = "rolo.mission-control" })
 
 -- Ctrl + Left / Right move between workspaces on this monitor (including empty
```

`~/.config/hypr/m5pro-dcp.lua` (backup `m5pro-dcp.lua.pre-mission-control-swipe-up`):
```diff
--- ~/.config/hypr/m5pro-dcp.lua.pre-mission-control-swipe-up
+++ ~/.config/hypr/m5pro-dcp.lua
@@ -127,7 +127,8 @@
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

## Verified
- `omarchy plugin validate ~/.config/omarchy/plugins/rolo.mission-control` exited 0.
- `omarchy-shell shell listPlugins` shows `rolo.mission-control` with `"enabled":true`.
- `hyprctl reload` returned `ok` and `hyprctl configerrors` returned empty after both the `bindings.lua` edit and the `m5pro-dcp.lua` edit.
- `hyprctl binds` lists `modmask: 4`, `key: UP` with description `Mission Control`.
- `journalctl --user -b -p warning --since "5 minutes ago"` had no entries.
- Not verified from this session: physical `Ctrl+Up` keypress and physical three-finger-up swipe (needs Rolando's hands).

## Rollback
```bash
omarchy plugin disable rolo.mission-control
cp -a ~/.config/hypr/bindings.lua.pre-mission-control-ctrl-up ~/.config/hypr/bindings.lua
cp -a ~/.config/hypr/m5pro-dcp.lua.pre-mission-control-swipe-up ~/.config/hypr/m5pro-dcp.lua
hyprctl reload
```
