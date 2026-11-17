-- Keep only your personal keybinding overrides here. Add new bindings with
-- o.bind or replace defaults with o.rebind.

-- See current bindings and descriptions:
--   omarchy menu keybindings --print

-- To disable every Omarchy default binding, set this in
-- ~/.config/hypr/hyprland.lua before require("default.hypr.omarchy"), then add
-- only the bindings you want below:
--   omarchy_default_bindings = false

-- To disable all preinstalled app/webapp bindings, set:
--   omarchy_preinstalled_bindings = false

-- Add a new binding.
-- o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")

-- Change an existing binding. o.rebind takes the same arguments as o.bind.
-- This example replaces the default file manager with Flea.
-- o.rebind("SUPER + SHIFT + F", "File manager", { launch = "flea" })

-- Disable a default binding without replacing it.
-- hl.unbind("SUPER + SHIFT + B")

-- Logitech MX Keys examples:
-- o.bind("SUPER + H", nil, "voxtype record toggle")
-- o.bind("SUPER + PERIOD", nil, { panel = "omarchy.emojis" })

-- Mission Control (macOS-style overview), shell plugin rolo.mission-control in
-- ~/.config/omarchy/plugins/. Ctrl + = toggles it.
o.bind("CTRL + EQUAL", "Mission Control", { panel = "rolo.mission-control" })

-- Ctrl + Left / Right move between workspaces, like macOS Spaces. Same
-- dispatch as Super + Tab / Super + Shift + Tab (workspaces of this monitor).
o.bind("CTRL + RIGHT", "Next workspace", hl.dsp.focus({ workspace = "m+1" }))
o.bind("CTRL + LEFT", "Previous workspace", hl.dsp.focus({ workspace = "m-1" }))

-- Three-finger swipe down closes Mission Control. It only hides the overlay (a
-- no-op when it is closed); three-finger up, in the m5pro profiles, opens it.
hl.gesture({ fingers = 3, direction = "down", action = function() hl.exec_cmd("omarchy-shell shell hide rolo.mission-control") end })

-- KM Link
o.bind("SUPER + CTRL + ALT + M", "KM Link: control Mac", "systemctl --user kill -s USR1 kmlink-controller.service")
o.bind("SUPER + CTRL + ALT + L", "KM Link: lock to this computer", "systemctl --user kill -s USR2 kmlink-controller.service")
