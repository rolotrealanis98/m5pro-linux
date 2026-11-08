-- M5 Pro (J716s) session profile for the DCP display path: the apple DRM card
-- (DCP firmware) scans out, Hyprland renders on the GPU (aurora, renderD128).
-- Loaded instead of m5pro.lua when hypr-gpu-session found a connected apple
-- card and exported M5PRO_HYPR_PROFILE=m5pro-dcp (see hyprland.lua). Loaded
-- after Omarchy's defaults and toggles, before the trackpad preset.
--
-- Why each setting (Hyprland 0.57.1 / aquamarine 0.16.0):
-- * Scanout buffers are LINEAR dumb buffers on the apple card that the GPU
--   renders into directly (no copy): the DCP reads them by IOVA. m5pro.lua's
--   "everything off" was for simpledrm, where every frame was a CPU copy.
-- * apple-drm has no cursor plane (its overlay planes are not exposed as
--   cursors), so aquamarine has no hardware cursor to offer: the cursor is
--   drawn into the frame (software cursor), as on every Asahi desktop.

local home = os.getenv("HOME")
local function toggle_on(name)  -- Omarchy toggles (Appearance menu), honoured
  local f = io.open(home .. "/.local/state/omarchy/toggles/hypr/" .. name .. ".lua", "r")
  if f then f:close() return true end
  return false
end

-- VRR is offered by the panel only with the opt-in appledrm.fw27_panel_vrr=1;
-- the launcher reads vrr_capable and exports M5PRO_PANEL_VRR.
local panel_vrr = os.getenv("M5PRO_PANEL_VRR") == "1"

-- The internal panel: eDP-1 or eDP-2 depending on the DCP instance numbering.
-- Hyprland 0.57 monitor rules match the exact output name (or desc:), no
-- globs, so both names get the rule. 3456x2234@120 is the preferred native
-- timing; Hyprland picks the closest listed mode and falls back to the next
-- best if the 120 Hz commit fails. 8-bit keeps the swapchain XRGB8888 and
-- keeps render:use_fp16 (auto) off the FP16 work buffer (2x the bandwidth).
for _, out in ipairs({ "eDP-1", "eDP-2" }) do
  hl.monitor({ output = out, mode = "3456x2234@120", position = "0x0", scale = 2, bitdepth = 8 })
end

hl.config({
  render = {
    -- 1 = "enable": a fullscreen client whose buffer is exactly 3456x2234 and
    -- LINEAR (Hyprland's dmabuf feedback asks for the plane's formats) goes to
    -- the DCP without compositing. Anything else (scaled, tiled, visible
    -- software cursor, screencast) composites as usual; aquamarine refuses a
    -- buffer the plane cannot take, so a failed attempt costs one test commit.
    direct_scanout = 1,
    -- Off: plain double-buffered pacing to the page flip. Turn on only if the
    -- verification shows frames regularly over 8.3 ms (it renders ahead with a
    -- third buffer instead of dropping to 60).
    new_render_scheduling = false,
  },

  cursor = {
    no_hardware_cursors = 1,      -- no cursor plane on apple-drm: skip the attempt
    min_refresh_rate = 24,        -- the panel's VRR floor (24-120 Hz)
    no_break_fs_vrr = 2,          -- auto: cursor motion does not force 120 Hz under fullscreen VRR games
    inactive_timeout = 3,         -- hide an idle software cursor so fullscreen can scan out directly
  },

  misc = {
    -- 1 = always on when the panel offers it. Every VRR_ENABLED change is a
    -- ~200 ms dark re-select of the timing in the DCP, so 2/3 (fullscreen
    -- only) would blank the panel on each fullscreen toggle.
    vrr = panel_vrr and 1 or 0,
  },

  debug = {
    vfr = true,                   -- 0.57 name of "misc:vfr": frames only on damage
    damage_tracking = 2,          -- full damage tracking (default, stated)
    disable_logs = false,         -- hypr-dcp-verify reads the backend lines
  },
})

-- Animations and blur back on, sized for a 3456x2234 panel at 120 Hz.
-- Hyprland animations are time based: 120 Hz only samples them twice as often,
-- so Omarchy's curves and speeds stay. Workspace slides stay off (Omarchy's
-- choice): every frame of a slide recomposites and re-blurs the whole panel.
if not toggle_on("no-animations") then
  hl.config({ animations = { enabled = true } })

  -- Blur only touches see-through surfaces (Omarchy's terminals at 0.985/0.96,
  -- shell layers). Dual-kawase cost is set by passes, each at a quarter of the
  -- previous size: 2 passes of size 5 is about 1.3 full-panel texture reads.
  -- new_optimizations caches the blurred wallpaper and only redoes it when
  -- what is behind changes; xray off keeps floating windows correct; no blur
  -- behind popups, special workspaces or input methods (extra full passes).
  -- The Glassy toggles set their own blur: leave theirs alone.
  if not (toggle_on("window-glassy") or toggle_on("bar-glassy")) then
    hl.config({
      decoration = {
        blur = {
          enabled = true,
          size = 5,
          passes = 2,
          new_optimizations = true,
          ignore_opacity = true,
          xray = false,
          popups = false,
          special = false,
          input_methods = false,
        },
      },
    })
  end
end

-- Input and gestures, as in m5pro.lua.
hl.config({
  input = {
    kb_layout = "us",
    repeat_rate = 40, repeat_delay = 600,
    follow_mouse = 1, sensitivity = 0,
    touchpad = { natural_scroll = true, tap_to_click = true, clickfinger_behavior = true },
  },
})

-- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 3 up = scratchpad, 4 down = fullscreen.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 3, direction = "up", action = "special", workspace_name = "scratchpad" })
hl.gesture({ fingers = 4, direction = "down", action = "fullscreen" })
