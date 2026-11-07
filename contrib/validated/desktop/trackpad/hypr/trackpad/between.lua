-- Trackpad preset "between": halfway between macOS and libinput's default.
-- Pointer speed at every finger speed is the geometric mean of the two (curves.lua between_out):
-- livelier than macOS when moving slowly, no libinput plateau, smooth growth for long flicks.
-- Loaded from select.lua. Every field is set, so switching presets never leaves a value behind.
local C = dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/curves.lua")

-- Knobs (see macos.lua for what each one does) ---------------------------------------------------
local TRACKING = 0.6875
local GAIN = 1.0
local SCROLL_ACCEL = 0.5
local SCROLL_FACTOR = 1.0
local TAP_TO_CLICK = true
local THREE_FINGER_DRAG = false
----------------------------------------------------------------------------------------------------

hl.device({
  name = "apple-mtp-multi-touch",
  accel_profile = C.motion_profile({ shape = "between", tracking = TRACKING, gain = GAIN }),
  scroll_points = C.scroll_points({ accel = SCROLL_ACCEL }),
  sensitivity = 0,
  scroll_factor = SCROLL_FACTOR,
  natural_scroll = true,
  scroll_method = "2fg",
  clickfinger_behavior = true,
  tap_to_click = TAP_TO_CLICK,
  tap_button_map = "lrm",
  tap_and_drag = true,
  drag_lock = 1,
  drag_3fg = THREE_FINGER_DRAG and 1 or 0,
  disable_while_typing = true,
  middle_button_emulation = false,
  left_handed = false,
})
