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
  local fn = function(s)
    if s <= 0 then return 0 end
    local x = mm_per_ms_to_apple_x(s / M.RES)
    local ratio = (f(x) / x) / c[2]
    return s * base * (1 + accel * (ratio - 1)) * factor
  end
  local step, pts = sample(fn)
  return string.format("%.5f %s", step, table.concat(pts, " "))
end

-- Stand-alone: print the curves as finger speed -> logical px per mm of finger travel.
if hl == nil and type(arg) == "table" and type(arg[0]) == "string" and arg[0]:match("curves%.lua$") then
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
