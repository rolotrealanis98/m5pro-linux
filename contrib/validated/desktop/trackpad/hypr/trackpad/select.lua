-- Active trackpad preset for the J716s trackpad: "macos", "between" or "linux-default".
-- Enable once by adding this line to ~/.config/hypr/hyprland.lua (anywhere after the hl.config call):
--   dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/select.lua")
-- Switch with:  ~/.config/hypr/trackpad/switch-preset.sh <name>   (edits the line below, then hyprctl reload)
local PRESET = "macos"

dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/" .. PRESET .. ".lua")
