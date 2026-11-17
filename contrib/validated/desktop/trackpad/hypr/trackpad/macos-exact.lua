-- Preset "macos-exact": the owner's own macOS 27.3 settings on this MacBook (read 2026-11-17),
-- turned into libinput curves with Apple's own tables and maths. Trackpad, Logitech mouse and
-- wheel, the "looks like" size (Hyprland scale), cursor size and gestures.
-- Mapping and derivations: contrib/omarchy-mac/macos-feel/README.md in the m5pro-linux repo.
--
-- Unlike the other presets this one must win over ~/.config/hypr/pointer-tuning.lua (the rolo.pointer
-- panel), which hyprland.lua loads after select.lua. So it registers M5PRO_TRACKPAD_LATE, and
-- hyprland.lua calls it after pointer-tuning.lua. select.lua clears it for every other preset.
local C = dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/curves.lua")

-- Knobs ------------------------------------------------------------------------------------------
-- "Looks like" size. macOS runs the panel at LOOKS_LIKE_W points wide (2246x1452, set with
-- BetterDisplay). SCALE is Hyprland's scale for the panel: 2 = 1728x1117 logical (today);
-- 3456 / LOOKS_LIKE_W = the same size as macOS. Fractional values are snapped to 1/120 (the
-- Wayland fractional-scale unit): 185/120 = 1.5417 -> 2242x1449, 192/120 = 1.6 -> 2160x1396,
-- 210/120 = 1.75 -> 1975x1277, 225/120 = 1.875 -> 1843x1191. 3456x2234 has no clean fractional
-- scale (gcd 2), so any of them needs debug:disable_scale_checks, which this file sets.
-- Pointer speed, scroll distance, cursor size and text size all follow SCALE (k below), so the
-- physical result on the glass is the same at any SCALE.
local SCALE = 2
local LOOKS_LIKE_W = 2246
-- macOS values (System Settings), not to be "tuned": change them only if macOS changes.
local TRACKPAD_TRACKING = 0.875     -- com.apple.trackpad.scaling (HIDTrackpadAcceleration 57344)
local TRACKPAD_SCROLL = 0.4412      -- com.apple.trackpad.scrolling (HIDTrackpadScrollAcceleration 28914)
local MOUSE_TRACKING = 2.0          -- com.apple.mouse.scaling (HIDMouseAcceleration 131072)
local MOUSE_WHEEL = 0.75            -- com.apple.scrollwheel.scaling (HIDMouseScrollAcceleration 49152)
local MOUSE_REPORT_HZ = 1000        -- G502 X PLUS onboard profile (G HUB reportRate)
local NATURAL = true                -- com.apple.swipescrolldirection = 1 (trackpad AND mouse on macOS)
-- Calibration (the parts macOS does not define in px; README "Side-by-side check" sets them):
-- trackpad scroll distance at rest, as a multiple of libinput's default (10.5 px per mm); 0.68 is
-- what the owner tuned by feel with the rolo.pointer panel.
local TRACKPAD_SCROLL_FACTOR = 0.68
-- a slow wheel notch, in Linux notches. macOS: a lone notch is one point delta = 4 CSS px in Chrome
-- (curves.lua macos_wheel_points), i.e. 4 * 3456/LOOKS_LIKE_W physical-equivalent Linux px; Chrome
-- on Linux scrolls 120 / SCALE px per notch. Leave nil for that; a number overrides it.
local WHEEL_BASE = nil
-- whole-curve multipliers if the side-by-side check shows a constant error.
local TRACKPAD_GAIN = 1.0
local MOUSE_GAIN = 1.0
-- Mouse devices (hyprctl devices). The receiver's second interface only carries the tilt wheel.
local MICE = { "logitech-usb-receiver", "logitech-usb-receiver-keyboard-1" }
----------------------------------------------------------------------------------------------------

local function snap(s) return s == 2 and 2 or math.floor(s * 120 + 0.5) / 120 end
local scale = snap(SCALE)
local k = C.display_k(scale, LOOKS_LIKE_W)
local wheel_base = WHEEL_BASE or (4 * k * scale / 120)

-- Same scroll distance in every toolkit. Reference: Chromium/Chrome/Electron (no rule), which
-- scroll 12 / SCALE px per touchpad axis unit and 120 / SCALE px per wheel notch. Hyprland's
-- scroll_touchpad / scroll_mouse window rules replace the device factor (1.0 here) per window, so
-- each value is reference / toolkit. Toolkit numbers are from their source (README, "Scrolling in
-- every app"); GTK uses pow(page, 2/3) per step, taken at a 1000 px page. Wheel rules only for
-- wl_pointer v8 clients: GTK3 and alacritty get whole axis_discrete steps, which a factor below 1
-- would round to nothing.
local ref_tp, ref_wheel = 12 / scale, 120 / scale
local GTK4 = "(org\\.gnome\\.(Nautilus|Papers|TextEditor|Calculator|Loupe|Snapshot|Settings|Characters|clocks|Weather)|com\\.github\\.PintaProject\\.Pinta)"
local GTK3 = "(org\\.gnome\\.(Evince|DiskUtility)|evince|gnome-disks)"
local SCROLL_RULES = {
  -- { class, initial_title (TUIs launched from the terminal) or nil, touchpad px/unit, wheel px/notch or nil }
  { GTK4, nil, 2.5, 1000 ^ (2 / 3) },
  { GTK3, nil, 1000 ^ (2 / 3) / 10, nil },
  { "(Alacritty)", "(Alacritty)", 3, nil },           -- [scrolling] multiplier 3 (default), axis_discrete wheel
  { "(kitty)", "(kitty)", 1, nil },                   -- touch_scroll_multiplier 1, wheel 5 lines ~ 65 px ~ reference
  { "foot", "foot", 7 / scale, 7 * 13 },              -- [scrollback] multiplier=7.0, 13 px lines
}

-- Cursor: macOS arrow is 17 pt tall at size 1 (NSCursor.arrow, opaque pixels), times
-- mouseDriverCursorSize 1.26; Adwaita's arrow is 0.85 of its nominal size.
local CURSOR_SIZE = math.floor(17 * 1.26 * k / 0.85 + 0.5)
M5PRO_MACOS_FEEL = { scale = scale, k = k, cursor_size = CURSOR_SIZE }

local function apply()
  if scale ~= 2 then
    hl.config({ debug = { disable_scale_checks = true } })
    for _, out in ipairs({ "eDP-1", "eDP-2", "Unknown-1" }) do
      hl.monitor({ output = out, mode = "3456x2234@120", position = "0x0", scale = scale, bitdepth = 8 })
    end
  end

  hl.device({
    name = "apple-mtp-multi-touch",
    accel_profile = C.motion_profile({ shape = "macos", tracking = TRACKPAD_TRACKING, gain = k * TRACKPAD_GAIN }),
    scroll_points = C.scroll_points({ index = TRACKPAD_SCROLL, accel = 1, mac_velocity = true,
                                      factor = TRACKPAD_SCROLL_FACTOR }),
    sensitivity = 0,
    scroll_factor = 1.0,
    natural_scroll = NATURAL,
    scroll_method = "2fg",
    clickfinger_behavior = true,   -- TrackpadRightClick = 1 (two fingers), corner click off
    tap_to_click = false,          -- Clicking = 0
    tap_button_map = "lrm",
    tap_and_drag = false,          -- Dragging = 0, DragLock = 0
    drag_lock = 0,
    drag_3fg = 0,                  -- TrackpadThreeFingerDrag = 0
    disable_while_typing = true,
    middle_button_emulation = false,
    left_handed = false,
  })

  for _, name in ipairs(MICE) do
    hl.device({
      name = name,
      accel_profile = C.mouse_profile({ scaling = MOUSE_TRACKING, hz = MOUSE_REPORT_HZ, k = k, gain = MOUSE_GAIN }),
      scroll_points = C.wheel_points({ scaling = MOUSE_WHEEL, base = wheel_base }),
      sensitivity = 0,
      scroll_factor = 1.0,
      natural_scroll = NATURAL,
      left_handed = false,
      middle_button_emulation = false,
    })
  end

  -- macOS: four-finger swipes switch Spaces too (TrackpadFourFingerHorizSwipeGesture = 2), and
  -- four-finger pinch opens Apps (TrackpadFourFingerPinchGesture = 2). Three-finger swipes are
  -- already bound in the profile.
  hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })
  hl.gesture({ fingers = 4, direction = "pinchin", action = function() hl.exec_cmd("omarchy-shell omarchy.dock apps") end })

  -- Per-toolkit scroll normalisation (Omarchy's o.window helper; it also sets the terminal rules
  -- this replaces, defined earlier in default/hypr/input.lua).
  if type(o) == "table" and o.window then
    for _, r in ipairs(SCROLL_RULES) do
      local function rules() -- o.window adds .match to the table it gets: a fresh one per call
        return { scroll_touchpad = ref_tp / r[3], scroll_mouse = r[4] and ref_wheel / r[4] or nil }
      end
      o.window(r[1], rules())
      if r[2] then o.window({ class = "(org\\.omarchy\\..*|TUI\\..*)", initial_title = r[2] }, rules()) end
    end
  end

  -- After pointer-tuning.lua's own "hyprctl setcursor Adwaita 18" (both are async; the delay keeps
  -- the order). Same theme as the panel and gsettings.
  hl.exec_cmd("sh -c 'sleep 1; hyprctl setcursor Adwaita " .. CURSOR_SIZE .. "'")
end

M5PRO_TRACKPAD_LATE = apply
