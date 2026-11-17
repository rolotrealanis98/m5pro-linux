-- M5 Pro (J716s) specifics, carried over from the pre-Quattro omarchy-lite config
-- (~/.config/hypr.pre-quattro/hyprland.lua). Loaded after Omarchy's defaults.
-- Scanout is simpledrm (CPU copy) and rendering is llvmpipe or zink, so the
-- expensive effects stay off; direct scanout and hardware cursors cannot work.
hl.config({
  decoration = { shadow = { enabled = false }, blur = { enabled = false } },
  animations = { enabled = false },
  render = { direct_scanout = false },
  cursor = { no_hardware_cursors = true },
  misc = { vrr = 0 },
  input = {
    kb_layout = "us",
    repeat_rate = 40, repeat_delay = 600,
    follow_mouse = 1, sensitivity = 0,
    touchpad = { natural_scroll = true, tap_to_click = true, clickfinger_behavior = true },
  },
})

-- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 3 up = Mission Control, 4 down = fullscreen.
-- (3 up was the scratchpad; that stays on Super + S. Mission Control is the shell plugin rolo.mission-control.)
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 3, direction = "up", action = function() hl.exec_cmd("omarchy-shell shell toggle rolo.mission-control") end })
hl.gesture({ fingers = 4, direction = "down", action = "fullscreen" })
