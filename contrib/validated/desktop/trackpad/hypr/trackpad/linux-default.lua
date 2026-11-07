-- Trackpad preset "linux-default": libinput's own touchpad behaviour, i.e. what this machine did
-- before the presets (adaptive acceleration at speed 0, plus the touchpad choices that were already
-- in hyprland.lua: natural scrolling, tap to click, clickfinger). Use it as the reference/fallback.
-- Loaded from select.lua. Every field is set, so switching presets never leaves a value behind.

local SENSITIVITY = 0.0 -- libinput speed, -1..1 (adaptive profile only)

hl.device({
  name = "apple-mtp-multi-touch",
  accel_profile = "adaptive",
  sensitivity = SENSITIVITY,
  scroll_factor = 1.0,
  natural_scroll = true,
  scroll_method = "2fg",
  clickfinger_behavior = true,
  tap_to_click = true,
  tap_button_map = "lrm",
  tap_and_drag = true,
  drag_lock = 0,
  drag_3fg = 0,
  disable_while_typing = true,
  middle_button_emulation = false,
  left_handed = false,
})
