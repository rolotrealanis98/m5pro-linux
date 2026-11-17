-- Active trackpad preset for the J716s trackpad: "macos", "between", "linux-default" or "macos-exact".
-- Enable once by adding this line to ~/.config/hypr/hyprland.lua (anywhere after the hl.config call):
--   dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/select.lua")
-- and, for macos-exact, after the pointer-tuning.lua block:
--   if M5PRO_TRACKPAD_LATE then M5PRO_TRACKPAD_LATE() end
-- Switch with:  ~/.config/hypr/trackpad/switch-preset.sh <name>   (edits the line below, then hyprctl reload)
local PRESET = "macos"

M5PRO_TRACKPAD_LATE = nil -- only macos-exact sets it; a reload must not keep it from an earlier preset
M5PRO_MACOS_FEEL = nil
dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/" .. PRESET .. ".lua")
