-- Trackpad preset "macos": the J716s trackpad set up to behave like it does under macOS.
-- Loaded from select.lua. Every field is set, so switching presets never leaves a value behind.
local C = dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/curves.lua")

-- Knobs ------------------------------------------------------------------------------------------
-- macOS System Settings > Trackpad > Tracking speed. Slider ticks: 0, 0.125, 0.5, 0.6875 (macOS
-- default), 0.875, 1, 1.5, 2, 2.5, 3. Same tables and maths as macOS (see curves.lua).
local TRACKING = 0.6875
-- Multiplies the whole pointer curve. 1.0 = the macOS numbers. Use it if every speed feels off by
-- the same amount (it absorbs any difference in report rate or resolution from the macOS model).
local GAIN = 1.0
-- Scroll: 0 = constant speed (libinput's default speed), 1 = Apple's scroll-curve shape (faster
-- the faster you flick). SCROLL_FACTOR scales everything on top.
local SCROLL_ACCEL = 1.0
local SCROLL_FACTOR = 1.0
-- macOS ships with tap to click off; this config has had it on, so it stays on.
local TAP_TO_CLICK = true
-- macOS Accessibility "three finger drag". Off by default here because three-finger swipes are
-- bound to workspaces in hyprland.lua; with it on, libinput keeps 3 fingers for dragging and
-- Hyprland's 3-finger gestures stop firing (move them to 4 fingers, as macOS does).
local THREE_FINGER_DRAG = false
----------------------------------------------------------------------------------------------------

hl.device({
  name = "apple-mtp-multi-touch",
  -- Apple's trackpad curve, sampled into 64 libinput points (0-1000 mm/s).
  accel_profile = C.motion_profile({ shape = "macos", tracking = TRACKING, gain = GAIN }),
  -- Required with a custom profile: without it scrolling runs 9.3x too fast (curves.lua).
  scroll_points = C.scroll_points({ accel = SCROLL_ACCEL }),
  sensitivity = 0,                 -- libinput ignores speed with the custom profile
  scroll_factor = SCROLL_FACTOR,
  natural_scroll = true,           -- macOS default ("Natural scrolling")
  scroll_method = "2fg",
  clickfinger_behavior = true,     -- click with 2 fingers anywhere = right click, 3 = middle
  tap_to_click = TAP_TO_CLICK,
  tap_button_map = "lrm",          -- 1-finger tap left, 2 right, 3 middle
  tap_and_drag = true,             -- double-tap-and-hold drags
  drag_lock = 1,                   -- lifting during a drag ends it after a short timeout (macOS "Dragging")
  drag_3fg = THREE_FINGER_DRAG and 1 or 0,
  disable_while_typing = true,
  middle_button_emulation = false,
  left_handed = false,
})
