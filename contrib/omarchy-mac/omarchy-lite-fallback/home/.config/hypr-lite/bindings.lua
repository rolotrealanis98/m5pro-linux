-- Omarchy keybinding scheme (v3.8.4 / quattro), adapted to repo-only tools:
--   walker -> fuzzel, omarchy-menu -> omarchy-lite-menu, omarchy-capture-* -> omarchy-lite-screenshot.
-- Every bind carries a description, so Super+K (omarchy-lite-keybindings) can list them.
local function bind(keys, desc, action, opts)
  opts = opts or {}
  opts.description = desc
  if type(action) == "string" then action = hl.dsp.exec_cmd(action) end
  hl.bind(keys, action, opts)
end

local terminal = "alacritty"
local browser  = "chromium"

-- ---------------------------------------------------------------- applications
bind("SUPER + RETURN",               "Terminal", terminal)
bind("SUPER + ALT + RETURN",         "Terminal (foot)", "foot")
bind("SUPER + SHIFT + RETURN",       "Browser", browser)
bind("SUPER + SHIFT + B",            "Browser", browser)
bind("SUPER + SHIFT + ALT + B",      "Browser (private)", browser .. " --incognito")
bind("SUPER + SHIFT + F",            "File manager", "nautilus --new-window")
bind("SUPER + SHIFT + N",            "Editor", terminal .. " -e nvim")
bind("SUPER + SHIFT + T",            "Activity", terminal .. " --class TUI.float -e btop")
bind("SUPER + CTRL + T",             "Activity", terminal .. " --class TUI.float -e btop")
bind("SUPER + CTRL + A",             "Audio controls", terminal .. " --class TUI.float -e wiremix")
bind("SUPER + CTRL + N",             "Network status", terminal .. " --class TUI.float -e sh -c 'networkctl status; read -n1 -p \"press a key\"'")
bind("SUPER + SHIFT + A",            "ChatGPT", "omarchy-lite-webapp https://chatgpt.com")
bind("SUPER + SHIFT + Y",            "YouTube", "omarchy-lite-webapp https://youtube.com/")
bind("SUPER + SHIFT + X",            "X", "omarchy-lite-webapp https://x.com/")
bind("SUPER + SHIFT + E",            "Email", "omarchy-lite-webapp https://app.hey.com")
bind("SUPER + SHIFT + C",            "Calendar", "omarchy-lite-webapp https://app.hey.com/calendar/weeks/")

-- ---------------------------------------------------------------- menus / utilities
bind("SUPER + SPACE",                "Launch apps", "pkill -x fuzzel || fuzzel")
bind("SUPER + ALT + SPACE",          "Omarchy menu", "omarchy-lite-menu")
bind("SUPER + ESCAPE",               "System menu", "omarchy-lite-menu system")
bind("SUPER + CTRL + C",             "Capture menu", "omarchy-lite-menu capture")
bind("SUPER + CTRL + O",             "Toggle menu", "omarchy-lite-menu toggle")
bind("SUPER + K",                    "Show key bindings", "omarchy-lite-keybindings")
bind("SUPER + SHIFT + SPACE",        "Toggle top bar", "pkill -SIGUSR1 -x waybar")
bind("SUPER + CTRL + E",             "Emoji picker", "omarchy-lite-menu emoji")
bind("SUPER + CTRL + V",             "Clipboard manager", "omarchy-lite-menu clipboard")
bind("SUPER + COMMA",                "Dismiss last notification", "makoctl dismiss")
bind("SUPER + SHIFT + COMMA",        "Dismiss all notifications", "makoctl dismiss --all")
bind("SUPER + CTRL + COMMA",         "Toggle silencing notifications", "omarchy-lite-toggle dnd")
bind("SUPER + ALT + COMMA",          "Invoke last notification", "makoctl invoke")
bind("SUPER + SHIFT + ALT + COMMA",  "Restore last notification", "makoctl restore")
bind("SUPER + CTRL + I",             "Toggle locking on idle", "omarchy-lite-toggle idle")
bind("SUPER + CTRL + L",             "Lock system", "loginctl lock-session")
bind("SUPER + CTRL + ALT + T",       "Show time", "notify-send -u low \"󰥔  $(date +'%A %H:%M  ·  %d %B %Y  ·  Week %V')\"")
bind("SUPER + CTRL + ALT + B",       "Show battery remaining", "omarchy-lite-battery")
bind("PRINT",                        "Screenshot (region)", "omarchy-lite-screenshot region")
bind("SHIFT + PRINT",                "Screenshot (window)", "omarchy-lite-screenshot window")
bind("CTRL + PRINT",                 "Screenshot (screen)", "omarchy-lite-screenshot output")
bind("SUPER + CTRL + ALT + C",       "Screenshot (region)", "omarchy-lite-screenshot region")   -- no Print key on the MacBook
bind("SUPER + CTRL + SHIFT + C",     "Screenshot (screen)", "omarchy-lite-screenshot output")
bind("SUPER + PRINT",                "Color picker", "pkill hyprpicker || hyprpicker -a")
bind("SUPER + CTRL + Z",             "Zoom in", function()
  local z = hl.get_config("cursor.zoom_factor") or 1
  hl.config({ cursor = { zoom_factor = z + 1 } })
end)
bind("SUPER + CTRL + ALT + Z",       "Reset zoom", function() hl.config({ cursor = { zoom_factor = 1 } }) end)

-- ---------------------------------------------------------------- universal clipboard (Omarchy clipboard.lua)
local terminals = { Alacritty = true, alacritty = true, foot = true, kitty = true, ["TUI.float"] = true }
local function send_once(mods, key)
  return function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
    hl.timer(function()
      hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
    end, { timeout = 50, type = "oneshot" })
  end
end
local function universal(dm, dk, tm, tk)
  return function()
    local w = hl.get_active_window()
    if w and terminals[w.class] then send_once(tm, tk)() else send_once(dm, dk)() end
  end
end
bind("SUPER + C", "Universal copy",  universal("CTRL", "C", "CTRL SHIFT", "C"))
bind("SUPER + V", "Universal paste", universal("CTRL", "V", "CTRL SHIFT", "V"))
bind("SUPER + X", "Universal cut",   send_once("CTRL", "X"))
bind("SUPER + A", "Select all",      send_once("CTRL", "A"))

-- ---------------------------------------------------------------- tiling (Omarchy tiling.lua)
bind("SUPER + W",             "Close window", hl.dsp.window.close())
bind("SUPER + Q",             "Close window", hl.dsp.window.close())
bind("SUPER + J",             "Toggle window split", hl.dsp.layout("togglesplit"))
bind("SUPER + P",             "Pseudo window", hl.dsp.window.pseudo())
bind("SUPER + T",             "Toggle window floating/tiling", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + F",             "Full screen", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("SUPER + ALT + F",       "Full width", hl.dsp.window.fullscreen({ mode = "maximized" }))
bind("SUPER + O",             "Pin window (float & pin)", function()
  local w = hl.get_active_window()
  if w and not w.floating then hl.dispatch(hl.dsp.window.float({ action = "toggle" })) end
  hl.dispatch(hl.dsp.window.pin())
end)

for _, d in ipairs({ { "LEFT", "l", "left" }, { "RIGHT", "r", "right" }, { "UP", "u", "above" }, { "DOWN", "d", "below" } }) do
  bind("SUPER + " .. d[1],         "Focus on " .. d[3] .. " window", hl.dsp.focus({ direction = d[2] }))
  bind("SUPER + SHIFT + " .. d[1], "Swap window " .. d[3], hl.dsp.window.swap({ direction = d[2] }))
  bind("SUPER + ALT + " .. d[1],   "Move window to group " .. d[3], hl.dsp.window.move({ into_group = d[2] }))
end

-- Workspaces 1-10 on the number row by keycode (layout independent, like Omarchy: code:10 = 1 ... code:19 = 0)
for i = 1, 10 do
  local key = "code:" .. tostring(i + 9)
  bind("SUPER + " .. key,               "Switch to workspace " .. i, hl.dsp.focus({ workspace = i }))
  bind("SUPER + SHIFT + " .. key,       "Move window to workspace " .. i, hl.dsp.window.move({ workspace = i }))
  bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to workspace " .. i, hl.dsp.window.move({ workspace = i, follow = false }))
end

bind("SUPER + S",             "Toggle scratchpad", hl.dsp.workspace.toggle_special("scratchpad"))
bind("SUPER + ALT + S",       "Move window to scratchpad", hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }))
bind("SUPER + TAB",           "Next workspace", hl.dsp.focus({ workspace = "e+1" }))
bind("SUPER + SHIFT + TAB",   "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))
bind("SUPER + CTRL + TAB",    "Former workspace", hl.dsp.focus({ workspace = "previous" }))
bind("ALT + TAB",             "Focus on next window", hl.dsp.window.cycle_next())
bind("ALT + SHIFT + TAB",     "Focus on previous window", hl.dsp.window.cycle_next({ next = false }))

-- Resize with Super + minus / equal (code:20 / code:21)
bind("SUPER + code:20",         "Expand window left", hl.dsp.window.resize({ x = -100, y = 0, relative = true }), { repeating = true })
bind("SUPER + code:21",         "Shrink window left", hl.dsp.window.resize({ x = 100, y = 0, relative = true }), { repeating = true })
bind("SUPER + SHIFT + code:20", "Shrink window up", hl.dsp.window.resize({ x = 0, y = -100, relative = true }), { repeating = true })
bind("SUPER + SHIFT + code:21", "Expand window down", hl.dsp.window.resize({ x = 0, y = 100, relative = true }), { repeating = true })

bind("SUPER + mouse_down",    "Scroll active workspace forward", hl.dsp.focus({ workspace = "e+1" }))
bind("SUPER + mouse_up",      "Scroll active workspace backward", hl.dsp.focus({ workspace = "e-1" }))
bind("SUPER + mouse:272",     "Move window", hl.dsp.window.drag(), { mouse = true })
bind("SUPER + mouse:273",     "Resize window", hl.dsp.window.resize(), { mouse = true })

-- Groups
bind("SUPER + G",             "Toggle window grouping", hl.dsp.group.toggle())
bind("SUPER + ALT + G",       "Move active window out of group", hl.dsp.window.move({ out_of_group = true }))
bind("SUPER + ALT + TAB",     "Next window in group", hl.dsp.group.next())
bind("SUPER + ALT + SHIFT + TAB", "Previous window in group", hl.dsp.group.prev())

-- ---------------------------------------------------------------- media / hardware keys
bind("XF86AudioRaiseVolume", "Volume up", "pamixer -i 5", { locked = true, repeating = true })
bind("XF86AudioLowerVolume", "Volume down", "pamixer -d 5", { locked = true, repeating = true })
bind("XF86AudioMute",        "Mute", "pamixer -t", { locked = true })
bind("XF86AudioPlay",        "Play/pause", "playerctl play-pause", { locked = true })
bind("XF86AudioPause",       "Play/pause", "playerctl play-pause", { locked = true })
bind("XF86AudioNext",        "Next track", "playerctl next", { locked = true })
bind("XF86AudioPrev",        "Previous track", "playerctl previous", { locked = true })
-- Keyboard backlight (kbd_backlight LED through logind; display brightness has no driver yet)
local kb = "brightnessctl -d kbd_backlight set "
bind("XF86KbdBrightnessUp",          "Keyboard brightness up", kb .. "10%+", { locked = true, repeating = true })
bind("XF86KbdBrightnessDown",        "Keyboard brightness down", kb .. "10%-", { locked = true, repeating = true })
bind("CTRL + XF86MonBrightnessUp",   "Keyboard brightness up", kb .. "10%+", { locked = true, repeating = true })
bind("CTRL + XF86MonBrightnessDown", "Keyboard brightness down", kb .. "10%-", { locked = true, repeating = true })
bind("CTRL + F2",                    "Keyboard brightness up", kb .. "10%+", { locked = true, repeating = true })
bind("CTRL + F1",                    "Keyboard brightness down", kb .. "10%-", { locked = true, repeating = true })
bind("XF86KbdLightOnOff",            "Keyboard backlight toggle",
  "sh -c 'if [ $(brightnessctl -d kbd_backlight get) -gt 0 ]; then brightnessctl -d kbd_backlight set 0; else brightnessctl -d kbd_backlight set 50%; fi'", { locked = true })
