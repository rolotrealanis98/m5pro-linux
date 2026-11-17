-- M5 Pro: `m5pro-desktop lite` brings back the pre-Quattro omarchy-lite desktop
-- (Waybar/Mako) at the next Hyprland start; `m5pro-desktop omarchy` returns here.
do
  local flag = io.open(os.getenv("HOME") .. "/.config/m5pro-desktop-lite", "r")
  if flag then
    flag:close()
    dofile(os.getenv("HOME") .. "/.config/hypr-lite/hyprland.lua")
    return
  end
end

-- Learn how to configure Hyprland: https://wiki.hypr.land/Configuring/Start/

-- Omarchy's bootstrap keeps path setup out of this user config.
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")

-- Disable all Omarchy default bindings. Add your own in hypr/bindings.lua.
-- omarchy_default_bindings = false
--
-- Or disable only bindings for Omarchy's preinstalled apps/web apps while
-- keeping core window-manager bindings:
-- omarchy_preinstalled_bindings = false

-- Load Omarchy defaults.
require("default.hypr.omarchy")

-- Put your personal overrides in these files. They're loaded after Omarchy's
-- defaults so package updates can improve the defaults without rewriting your
-- ~/.config/hypr files.
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
require("hypr.looknfeel")
require("hypr.autostart")

-- Toggle config flags dynamically.
require("default.hypr.toggles")

-- Add any other personal Hyprland configuration below.
-- o.window("qemu", { workspace = "5" })

-- M5 Pro (J716s) machine specifics, then the trackpad preset (keep it last).
-- The launcher picks the profile: m5pro-dcp when the DCP (apple DRM card)
-- drives the panel and Hyprland renders on the GPU, m5pro otherwise
-- (simpledrm or software). M5PRO_PANEL_MODE pins the panel mode (the software
-- session on the DCP asks for 60 Hz).
do
  local profile = os.getenv("M5PRO_HYPR_PROFILE") == "m5pro-dcp" and "m5pro-dcp" or "m5pro"
  require("hypr." .. profile)
  local mode = os.getenv("M5PRO_PANEL_MODE")
  if mode and mode ~= "" then
    for _, out in ipairs({ "eDP-1", "eDP-2" }) do
      hl.monitor({ output = out, mode = mode, position = "0x0", scale = 2 })
    end
  end
end
dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/select.lua")
do
  local pt = os.getenv("HOME") .. "/.config/hypr/pointer-tuning.lua"
  local f = io.open(pt, "r")
  if f then
    f:close()
    dofile(pt)
  end
end
