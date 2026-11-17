-- Omarchy-style Hyprland for the M5 Pro (J716s) bring-up: llvmpipe over simpledrm, so every effect is off
-- (Omarchy's own default/hypr/software-rendering.lua does the same: no animations, blur or shadows).
-- Layout: hyprland.lua (look, input, rules, autostart) + bindings.lua (Omarchy keybinding scheme).
local HOME = os.getenv("HOME")
local wallpaper = HOME .. "/.local/share/wallpapers/omarchy-lite.png"

-- Panel: 3456x2234, scale 2. The connector is eDP-1 on older kernels, Unknown-1 on kernel #8.
hl.monitor({ output = "eDP-1",     mode = "preferred", position = "0x0",  scale = 2 })
hl.monitor({ output = "Unknown-1", mode = "preferred", position = "0x0",  scale = 2 })
hl.monitor({ output = "",          mode = "preferred", position = "auto", scale = 2 })

hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

hl.on("hyprland.start", function()
  hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE PATH XCURSOR_THEME XCURSOR_SIZE")
  hl.exec_cmd("swaybg -m fill -c '#1a1b26' -i " .. wallpaper)
  hl.exec_cmd("waybar")
  hl.exec_cmd("mako")
  hl.exec_cmd("hypridle")
  hl.exec_cmd("/usr/lib/hyprpolkitagent/hyprpolkitagent")
  hl.exec_cmd("wl-clip-persist --clipboard regular")
  hl.exec_cmd("wl-paste --watch cliphist store")
  hl.exec_cmd("omarchy-lite-theme-apply")
end)

-- Tokyo Night (Omarchy's default theme)
local active_border   = "rgb(7aa2f7)"
local inactive_border = "rgba(414868aa)"

hl.config({
  general = {
    gaps_in = 5, gaps_out = 10, border_size = 2,
    col = { active_border = active_border, inactive_border = inactive_border },
    resize_on_border = true, extend_border_grab_area = 8, hover_icon_on_border = true,
    allow_tearing = false, layout = "dwindle",
  },
  decoration = {
    rounding = 0,
    shadow = { enabled = false },
    blur = { enabled = false },
  },
  animations = { enabled = false },
  group = {
    col = { border_active = active_border, border_inactive = inactive_border },
    groupbar = { font_size = 12, height = 22, gradients = false, text_color = "rgb(c0caf5)",
                 col = { active = "rgb(292e42)", inactive = "rgb(1a1b26)" } },
  },
  dwindle = { preserve_split = true, force_split = 2 },
  master = { new_status = "master" },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
    background_color = "rgb(1a1b26)",
    vrr = 0,
    focus_on_activate = true,
    allow_session_lock_restore = true,
    key_press_enables_dpms = true,
    mouse_move_enables_dpms = true,
  },
  ecosystem = { no_update_news = true, no_donation_nag = true },
  render = { direct_scanout = false },
  cursor = { no_hardware_cursors = true },
  input = {
    kb_layout = "us",
    repeat_rate = 40, repeat_delay = 600,      -- Omarchy defaults
    follow_mouse = 1, sensitivity = 0,
    touchpad = { natural_scroll = true, tap_to_click = true, clickfinger_behavior = true },
  },
})
dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/select.lua")

-- Window rules (Omarchy default/hypr/windows.lua + apps/system.lua, trimmed)
hl.window_rule({ name = "suppress-maximize", match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({
  name = "fix-xwayland-drags",
  match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
  no_focus = true,
})
hl.window_rule({
  name = "floating-tools",
  match = { class = "^(TUI\\.float|org\\.gnome\\.Evince|imv|mpv|com\\.gabm\\.satty|xdg-desktop-portal-gtk|hyprland-share-picker|org\\.gnome\\.NautilusPreviewer)$" },
  float = true, center = true, size = { 875, 600 },
})
hl.window_rule({
  name = "floating-file-dialogs",
  match = { title = "^(Open.*Files?|Open [Ff]older.*|Save.*Files?|Save.*As|Save|All Files|.*wants to (open|save).*|[Cc]hoose.*)$" },
  float = true, center = true, size = { 875, 600 },
})

-- Gestures (Apple MTP trackpad): 3-finger swipe = workspaces, 3 up = scratchpad, 4 down = fullscreen
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 3, direction = "up", action = "special", workspace_name = "scratchpad" })
hl.gesture({ fingers = 4, direction = "down", action = "fullscreen" })

dofile(HOME .. "/.config/hypr-lite/bindings.lua")
