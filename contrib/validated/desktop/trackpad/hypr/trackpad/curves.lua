-- Pointer and scroll curves for the J716s trackpad ("Apple MTP multi-touch"), as libinput "custom"
-- acceleration points for Hyprland's accel_profile / scroll_points.
--
-- Loaded by the preset files with dofile(). Run it on its own to print the curves:
--   lua ~/.config/hypr/trackpad/curves.lua [tracking]      (tracking defaults to 0.6875)
--
-- Units (libinput 1.32, filter-custom.c and evdev-mt-touchpad.c tp_filter_motion):
--   For touchpads the custom profile sees raw device units, NOT libinput's 1000 dpi normalised
--   units. Input speed = device units per ms (this pad: 98 units/mm, so 1 mm/ms = 98 u/ms).
--   Output speed = normalised units per ms, which Hyprland moves the cursor by in logical pixels.
--   With the panel at 3456x2234 and scale 2, one logical pixel is one macOS point (macOS also runs
--   this panel "looks like 1728x1117"), so macOS points and Hyprland logical pixels compare 1:1.

local M = {}

-- Measured on the J716s: ABS_MT_POSITION_X/Y resolution (units per mm), from libinput record.
M.RES = 98

-- Apple's trackpad pointer curves: AppleTopCaseHIDEventDriver.kext Info.plist, personality
-- "Trackpad HID Bridge - MT", key HIDAccelCurves (16.16 fixed point, converted to decimal).
-- Columns: index (= macOS Tracking speed setting), gain linear, gain parabolic, gain cubic,
-- gain quartic, tangent speed linear, tangent speed parabolic root.
M.APPLE_POINTER = {
  { 0.0,    1.00, 0.00, 0.00, 0, 7.4, 21 },
  { 0.125,  0.99, 0.50, 0.08, 0, 7.3, 20 },
  { 0.5,    0.98, 0.66, 0.10, 0, 7.2, 19 },
  { 0.6875, 0.96, 0.83, 0.12, 0, 7.1, 18 },
  { 0.875,  0.94, 1.00, 0.15, 0, 7.0, 17 },
  { 1.0,    0.92, 1.15, 0.18, 0, 7.0, 16 },
  { 1.5,    0.89, 1.30, 0.21, 0, 7.0, 15 },
  { 2.0,    0.86, 1.45, 0.24, 0, 7.0, 14 },
  { 2.5,    0.83, 1.66, 0.28, 0, 7.0, 13 },
  { 3.0,    1.00, 1.88, 0.36, 0, 7.0, 12 },
}

-- Same personality, key HIDScrollAccelCurves. Index = macOS scroll speed setting; the default
-- (HIDTrackpadScrollAcceleration 20480) is 0.3125.
M.APPLE_SCROLL = {
  { 0.0,    1.00, 0.0, 0, 0, 6.0, 12 },
  { 0.125,  0.95, 0.6, 0, 0, 6.2, 12 },
  { 0.5,    0.90, 0.9, 0, 0, 6.4, 12 },
  { 0.6875, 0.85, 1.2, 0, 0, 6.6, 12 },
  { 0.875,  0.80, 1.4, 0, 0, 6.8, 12 },
  { 1.0,    0.75, 1.6, 0, 0, 7.0, 12 },
  { 1.5,    0.70, 1.8, 0, 0, 7.2, 12 },
  { 2.0,    0.65, 2.0, 0, 0, 7.4, 12 },
  { 2.5,    0.60, 2.2, 0, 0, 7.6, 12 },
  { 3.0,    0.55, 2.4, 0, 0, 7.8, 12 },
}

M.MACOS_DEFAULT_TRACKING = 0.6875 -- HIDTrackpadAcceleration 45056 on a stock macOS install
M.MACOS_DEFAULT_SCROLL = 0.3125   -- HIDTrackpadScrollAcceleration 20480

-- Linear blend between the two table rows around idx, as IOHIDParametricAcceleration does.
local function interp(tbl, idx)
  local cur = 1
  for i = 1, #tbl do
    if idx >= tbl[i][1] then cur = i end
  end
  local a = tbl[cur]
  if a[1] < idx and cur < #tbl then
    local b = tbl[cur + 1]
    local t = (idx - a[1]) / (b[1] - a[1])
    local r = {}
    for k = 1, 7 do r[k] = a[k] + t * (b[k] - a[k]) end
    return r
  end
  return a
end

-- Apple's three-segment parametric curve (IOHIDFamily IOHIDAccelerationAlgorithm.cpp), written
-- exactly as Apple computes it, including the (gain * x)^n form of the higher terms:
--   x <= tangent linear:            f1 = gl*x + (gp*x)^2 + (gc*x)^3 + (gq*x)^4
--   up to tangent parabolic root:   the tangent line to f1
--   beyond:                         sqrt(m1*x + b1), tangent to that line
local function apple_fn(c)
  local gl, gp, gc, gq, tl, tr = c[2], c[3], c[4], c[5], c[6], c[7]
  local function f1(x) return gl * x + (gp * x) ^ 2 + (gc * x) ^ 3 + (gq * x) ^ 4 end
  local t0, t1 = math.huge, math.huge
  local m0, b0, m1, b1 = 0, 0, 0, 0
  if tl ~= 0 then
    local y0 = f1(tl)
    m0 = gl + 2 * tl * gp ^ 2 + 3 * tl ^ 2 * gc ^ 3 + 4 * tl ^ 3 * gq ^ 4
    b0 = y0 - m0 * tl
    t0 = tl
    if tr ~= 0 then
      local y1 = m0 * tr + b0
      m1 = 2 * y1 * m0
      b1 = y1 ^ 2 - m1 * tr
      t1 = tr
    end
  end
  return function(x)
    if x <= t0 then return f1(x) end
    if x <= t1 then return m0 * x + b0 end
    return math.sqrt(m1 * x + b1)
  end
end

-- macOS speed units: IOHIDPointerAccelerator takes the per-report delta (reports normalised to the
-- trackpad's HIDPointerReportRate of 120 Hz) and IOHIDParametricAcceleration divides it by
-- resolution/67, so x = inches moved per 1/120 s * 67. The result is scaled by 96/67, so the
-- index-0 curve (f(x) = x) is exactly 96 points per inch of finger travel.
local function mm_per_ms_to_apple_x(u)
  return u * (1000 / 120) / 25.4 * 67
end

local function apple_x_to_px_per_ms(fx)
  return fx * (96 / 67) * (120 / 1000)
end

-- macOS pointer: output speed (px/ms) for an input speed in device units/ms.
function M.macos_out(s_in, tracking, gain)
  local f = apple_fn(interp(M.APPLE_POINTER, tracking or M.MACOS_DEFAULT_TRACKING))
  local x = mm_per_ms_to_apple_x(s_in / M.RES)
  return apple_x_to_px_per_ms(f(x)) * (gain or 1)
end

-- libinput's default touchpad profile (adaptive, speed 0), filter-touchpad.c
-- touchpad_accel_profile_linear, without its Simpson smoothing. Output in px/ms.
function M.libinput_out(s_in, speed)
  speed = speed or 0
  local dpi = M.RES * 25.4
  local v = s_in / M.RES * 1000 -- mm/s
  local fac
  if v < 7 then
    fac = math.min(0.9, 0.1 * v + 0.3)
  elseif v < 130 then
    fac = 0.9
  else
    local vv = math.min(v, 520)
    fac = 0.0025 * (vv / 130) * (vv - 130) + 0.9
  end
  local sf = (speed + 1) ^ 2.38 * 0.95 + 0.05
  return s_in * fac * sf * 0.2968 * 1000 / dpi
end

-- Halfway (geometric mean) between macOS and libinput at every speed: libinput's livelier slow
-- speeds, macOS's smooth growth with no plateau.
function M.between_out(s_in, tracking, gain)
  return math.sqrt(M.macos_out(s_in, tracking, 1) * M.libinput_out(s_in, 0)) * (gain or 1)
end

local NPOINTS = 64        -- libinput maximum (LIBINPUT_ACCEL_NPOINTS_MAX)
local MAX_MM_PER_S = 1000 -- curve span; libinput extrapolates the last two points beyond it

local function sample(fn)
  local step = (MAX_MM_PER_S / 1000) * M.RES / (NPOINTS - 1)
  local pts = {}
  for i = 0, NPOINTS - 1 do
    local y = fn(i * step)
    if y < 0 then y = 0 end
    if y > 10000 then y = 10000 end -- LIBINPUT_ACCEL_POINT_MAX_VALUE
    pts[#pts + 1] = string.format("%.4f", y)
  end
  return step, pts
end

-- accel_profile string for hl.device: "custom <step> <p0> <p1> ...".
-- opts.shape: "macos" or "between"; opts.tracking: macOS tracking speed; opts.gain: multiplier.
function M.motion_profile(opts)
  opts = opts or {}
  local fn
  if opts.shape == "between" then
    fn = function(s) return M.between_out(s, opts.tracking, opts.gain) end
  else
    fn = function(s) return M.macos_out(s, opts.tracking, opts.gain) end
  end
  local step, pts = sample(fn)
  return string.format("custom %.5f %s", step, table.concat(pts, " "))
end

-- Scroll. The custom profile has no scroll curve unless one is given, and its fallback is 1:1 in
-- device units: 98 scroll units per mm, 9.3 times libinput's default (10.5 per mm). So a custom
-- motion profile always needs scroll_points.
-- Base slope = libinput's default touchpad scroll speed (touchpad_constant_filter: 0.9 * 0.2968,
-- normalised to 1000 dpi). Shape = Apple's scroll curve at the macOS default scroll speed, as
-- f(x)/x normalised to 1 at rest, with x in the same units as the pointer. macOS scrolls through
-- its gesture engine (with momentum), so this is the shape of Apple's curve, not a replica of
-- macOS scrolling. opts.accel: 0 = constant speed, 1 = full Apple shape. opts.factor: multiplier.
function M.scroll_points(opts)
  opts = opts or {}
  local accel = opts.accel or 1
  local factor = opts.factor or 1
  local c = interp(M.APPLE_SCROLL, opts.index or M.MACOS_DEFAULT_SCROLL)
  local f = apple_fn(c)
  local base = 0.9 * 0.2968 * 1000 / (M.RES * 25.4)
  -- opts.mac_velocity: use IOHIDScrollAccelerator's own speed estimate (see M.scroll_velocity_coeff)
  -- instead of the pointer's, i.e. x is 1.38 times larger and the curve bends at a lower speed.
  local coeff = opts.mac_velocity and M.scroll_velocity_coeff(1000 / 120) or 1
  local fn = function(s)
    if s <= 0 then return 0 end
    local x = mm_per_ms_to_apple_x(s / M.RES) * coeff
    local ratio = (f(x) / x) / c[2]
    return s * base * (1 + accel * (ratio - 1)) * factor
  end
  local step, pts = sample(fn)
  return string.format("%.5f %s", step, table.concat(pts, " "))
end

-- IOHIDScrollAccelerator (IOHIDFamily IOHIDAcceleration.cpp): velocity = (A t^2 - B t + C) * mean
-- delta, t = mean ms between scroll events (clamped 1..150), constants 16.16 fixed point 0x2, 0x3bb,
-- 0x18041. At the trackpad's 120 Hz (t = 8.33 ms) the factor is 1.38. At t >= 150 ms it is ~0: a
-- lone, slow wheel notch is barely accelerated at all.
function M.scroll_velocity_coeff(t_ms)
  local t = math.min(math.max(t_ms, 1), 150)
  return (2 / 65536) * t * t - (0x3bb / 65536) * t + 0x18041 / 65536
end

----------------------------------------------------------------------------------------------------
-- Display: macOS "looks like" size vs the Hyprland scale.
-- macOS moves the pointer and scrolls in points of the current "looks like" mode; Hyprland in logical
-- pixels. k = logical px per macOS point, so a curve in macOS points times k gives the same physical
-- (mm on the glass) result. Measured 2026-11-17 from macOS (system_profiler): built-in panel 3456x2234,
-- "looks like" 2246x1452 (set with BetterDisplay; macOS default would be 1728x1117).
M.PANEL_W = 3456
M.MACOS_LOOKS_LIKE_W = 2246
function M.display_k(scale, looks_like_w)
  return (M.PANEL_W / (scale or 2)) / (looks_like_w or M.MACOS_LOOKS_LIKE_W)
end

----------------------------------------------------------------------------------------------------
-- Mouse (Logitech G502 X PLUS on its LIGHTSPEED receiver 046d:c547).
-- On macOS the receiver's mouse interface matches AppleUserHIDEventDriver, which carries no
-- HIDAccelCurves and no HIDPointerReportRate (ioreg, 2026-11-17). IOHIDPointerScrollFilter then uses
-- the table algorithm with IOHIDFamily's built-in defaultAccelTable (IOHIDPointerScrollFilter.cpp),
-- at HIDMouseAcceleration = com.apple.mouse.scaling (2.0 here; HIDPointerAcceleration 0.6875 is only
-- the fallback key and is not used once HIDMouseAcceleration is set), resolution 400 dpi (the
-- default, the receiver reports no physical units) and FRAME_RATE 67. With no report rate the
-- speed is |delta| in counts per HID report, not per unit of time, so DPI does not appear anywhere:
-- macOS maps counts per report to points per report.
-- The wheel goes the same way: no HIDScrollAccelCurves -> defaultAccelTable at
-- HIDMouseScrollAcceleration = com.apple.scrollwheel.scaling (0.75), HIDScrollResolution 9, rate 67.

-- defaultAccelTable, decoded (16.16): { acceleration, { {x, y}, ... } }
M.APPLE_MOUSE_TABLE = {
  { 0.0, { { 1.0, 1.0 } } },
  { 1.0, { { 0.4423065185546875, 0.375 }, { 4.3076934814453125, 16.5 }, { 12.0, 95.0 },
           { 22.923080444335938, 139.0 }, { 29.23077392578125, 148.5 }, { 34.46153259277344, 150.0 },
           { 36.384613037109375, 150.0 }, { 38.0, 150.0 }, { 40.0, 150.0 } } },
}
M.MACOS_MOUSE_SCALING = 2.0       -- com.apple.mouse.scaling (HIDMouseAcceleration 131072)
M.MACOS_WHEEL_SCALING = 0.75      -- com.apple.scrollwheel.scaling (HIDMouseScrollAcceleration 49152)
M.MOUSE_REPORT_HZ = 1000          -- G HUB profile reportRate (onboard), 1000 Hz
local CURSOR_SCALE = 96 / 67      -- kCursorScale

-- IOHIDTableAcceleration::CreateWithTable + multiplier, ported line by line.
local function table_interp_point(p, p0, p1, ratio)
  local m = (p1[2] - p0[2]) / (p1[1] - p0[1])
  local b = p1[2] - m * p1[1]
  local y = p[1] * m + b
  return math.min(p[2], y) + math.abs(p[2] - y) * ratio
end

local function table_interp_fn(lo, hi, ratio, set)
  local h = 1
  local ph0, ph1 = { 0, 0 }, hi[1]
  for _, p in ipairs(lo) do
    while p[1] > ph1[1] do
      if h < #hi then ph0 = ph1; h = h + 1; ph1 = hi[h] else break end
    end
    if set[p[1]] == nil then set[p[1]] = table_interp_point(p, ph0, ph1, ratio) end -- std::set: first insert wins
  end
end

function M.mac_table(acc, res, rate)
  local tbl = M.APPLE_MOUSE_TABLE
  local lo, hi = tbl[1], tbl[1]
  for i = 1, #tbl do
    lo = hi; hi = tbl[i]
    if acc <= hi[1] then
      if acc == hi[1] then lo = hi end
      break
    end
  end
  local set = {}
  if hi == lo or acc > hi[1] then
    local s = (acc + 1) / (hi[1] + 1)
    for _, p in ipairs(hi[2]) do set[p[1]] = p[2] * s end
  else
    local ratio = (acc - lo[1]) / (hi[1] - lo[1])
    table_interp_fn(lo[2], hi[2], ratio, set)
    table_interp_fn(hi[2], lo[2], ratio, set)
  end
  local xs = {}
  for x in pairs(set) do xs[#xs + 1] = x end
  table.sort(xs)
  local segs, p1 = {}, { 0, 0 }
  for _, x in ipairs(xs) do
    local p0 = p1
    p1 = { x * res / rate, set[x] * CURSOR_SCALE }
    local m = (p1[2] - p0[2]) / (p1[1] - p0[1])
    segs[#segs + 1] = { m, p1[2] - m * p1[1], p1[1] }
  end
  return function(v)
    local cur = segs[1]
    for _, s in ipairs(segs) do
      cur = s
      if not (v > s[3]) then break end
    end
    return cur[1] * v + cur[2]
  end
end

-- macOS mouse pointer: points per report for counts per report.
function M.macos_mouse_out(counts, scaling)
  return M.mac_table(scaling or M.MACOS_MOUSE_SCALING, 400, 67)(counts)
end

-- libinput's custom profile for a mouse sees raw counts per ms (filter-custom.c: no DPI
-- normalisation, speed = |delta| / time since the previous event) and outputs logical px per ms.
-- At R reports/s, counts per report = v * 1000 / R and px per ms = out_per_report * R / 1000.
-- opts.scaling (macOS tracking speed), opts.hz (report rate), opts.k (display factor), opts.gain.
function M.mouse_profile(opts)
  opts = opts or {}
  local T = M.mac_table(opts.scaling or M.MACOS_MOUSE_SCALING, 400, 67)
  local hz = opts.hz or M.MOUSE_REPORT_HZ
  local k = (opts.k or 1) * (opts.gain or 1)
  local step, pts = 1.0, {}
  for i = 0, 63 do
    local c = i * step * 1000 / hz
    local y = T(c) * hz / 1000 * k
    pts[#pts + 1] = string.format("%.4f", math.min(math.max(y, 0), 10000))
  end
  return string.format("custom %.5f %s", step, table.concat(pts, " "))
end

-- macOS wheel: CGEvent "point delta" per notch when notches arrive every dt ms (steady spin).
-- IOHIDScrollAccelerator averages up to 9 events inside 500 ms (stopping at a gap over 150 ms) and,
-- for the table algorithm, multiplies the speed by sqrt(count); the accelerated value is the point
-- delta (the event system scales it by 0.1 into the FixedPt/NSEvent deltaY). A notch is never less
-- than 1 point delta (0.1 deltaY): Chromium's mac event builder documents exactly this ("for each
-- mouse notch +1/-1 ... larger values on longer scrolls"; FixedPt "+0.1/-0.1"), and Chrome on macOS
-- scrolls deltaY * 40 = 4 CSS px per point delta (kScrollbarPixelsPerCocoaTick).
-- So a lone notch moves 4 px in Chrome and a fast spin ~170 times that.
function M.macos_wheel_points(dt, scaling)
  local T = M.mac_table(scaling or M.MACOS_WHEEL_SCALING, 9, 67)
  local count = dt > 150 and 1 or math.min(9, math.floor(500 / dt) + 1)
  local v = math.max(M.scroll_velocity_coeff(dt), 1 / 65536)
  if count > 2 then v = v * math.sqrt(count * 16) / 4 end
  return math.max(1, T(v))
end

-- scroll_points for the mouse wheel. libinput 1.32 runs wheel events through the custom profile's
-- scroll curve (evdev-fallback.c, FILTER_SCROLL_TYPE_WHEEL) in v120 units: one notch = 120, speed =
-- 120 / ms since the previous notch. Output = v * base * gain(speed), gain = macOS point delta per
-- notch (1 for a slow notch). opts.base: Linux notches for one macOS point delta (the preset
-- derives it from Chrome on both systems).
-- libinput treats the first notch after a 1 s pause as 7 ms after the previous one (120/7 = 17.1
-- v120/ms, filter-custom.c FIRST_MOTION_TIME_INTERVAL), so the curve drops back to the slow gain
-- around 17 v120/ms; otherwise every first notch would be a full-speed jump. macOS treats that
-- notch as slow, which is what the dip reproduces.
-- Only wl_pointer v8+ clients (value120: Chromium/Electron, GTK4, Qt, kitty, foot) see the size;
-- older ones (GTK3, alacritty) get one axis_discrete step per notch whatever the curve says.
function M.wheel_points(opts)
  opts = opts or {}
  local base = opts.base or (1 / 3)
  local accel = opts.accel or 1
  local step, pts = 0.5, {}
  for i = 0, 63 do
    local v = i * step
    local gain = 1
    if v > 0 and not (v >= 15.5 and v <= 19.0) then
      local dt = 120 / v
      gain = M.macos_wheel_points(dt, opts.scaling)
    end
    gain = 1 + accel * (gain - 1)
    pts[#pts + 1] = string.format("%.4f", math.min(v * base * gain, 10000))
  end
  return string.format("%.5f %s", step, table.concat(pts, " "))
end

-- Stand-alone: print the curves as finger speed -> logical px per mm of finger travel.
--   lua curves.lua [tracking]          trackpad
--   lua curves.lua mouse [dpi] [k]     mouse: macOS vs the libinput curve, px per mm of mouse travel
--   lua curves.lua wheel               wheel: macOS lines per notch vs notch rate
if hl == nil and type(arg) == "table" and type(arg[0]) == "string" and arg[0]:match("curves%.lua$")
    and (arg[1] == "mouse" or arg[1] == "wheel") then
  if arg[1] == "mouse" then
    local dpi, k = tonumber(arg[2]) or 2450, tonumber(arg[3]) or 1
    print(string.format("mouse: %d dpi, %d Hz, scaling %.2f, k %.4f", dpi, M.MOUSE_REPORT_HZ, M.MACOS_MOUSE_SCALING, k))
    print(" mm/s  counts/ms  macOS pt/ms  linux px/ms  (px per mm of mouse travel)")
    local prof = M.mouse_profile({ k = k })
    local step, ys = prof:match("custom (%S+) (.*)")
    step = tonumber(step)
    local p = {}
    for y in ys:gmatch("%S+") do p[#p + 1] = tonumber(y) end
    for _, mm in ipairs({ 5, 10, 20, 50, 100, 200, 300, 500 }) do
      local v = mm * dpi / 25.4 / 1000
      local i = math.min(math.floor(v / step), #p - 2)
      local lin = (p[i + 1] * (step * (i + 1) - v) + p[i + 2] * (v - step * i)) / step
      local mac = M.macos_mouse_out(v * 1000 / M.MOUSE_REPORT_HZ) * M.MOUSE_REPORT_HZ / 1000
      print(string.format("%5d %9.2f %12.2f %12.2f   mac %.1f  linux %.1f", mm, v, mac, lin,
        mac / (mm / 1000), lin / (mm / 1000)))
    end
  else
    print(" notches/s  macOS point delta/notch  Chrome-mac px/notch")
    for _, dt in ipairs({ 1000, 200, 150, 125, 100, 80, 60, 40, 25, 15, 10 }) do
      local p = M.macos_wheel_points(dt)
      print(string.format("%10.1f %22.2f %20.1f", 1000 / dt, p, 4 * p))
    end
  end
elseif hl == nil and type(arg) == "table" and type(arg[0]) == "string" and arg[0]:match("curves%.lua$") then
  local tracking = tonumber(arg[1]) or M.MACOS_DEFAULT_TRACKING
  print(string.format("tracking %.4f, %d units/mm", tracking, M.RES))
  print(" mm/s   macOS   between   libinput   (logical px per mm of finger travel)")
  for _, v in ipairs({ 2, 5, 10, 20, 30, 50, 75, 100, 150, 200, 300, 500, 800, 1000 }) do
    local s = v * M.RES / 1000
    local d = v / 1000
    print(string.format("%5d %7.2f %9.2f %10.2f", v, M.macos_out(s, tracking) / d,
      M.between_out(s, tracking) / d, M.libinput_out(s) / d))
  end
end

return M
