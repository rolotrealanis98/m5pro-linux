#!/bin/bash
# omarchy-setup.sh - Omarchy-style Hyprland desktop for the M5 Pro MacBook bring-up (llvmpipe / simpledrm).
# Layered on top of ~/Work/agents/desktop/desktop-setup.sh (user rolo, getty@tty2 autologin, hypr-session).
# Run as root on the MacBook:   ssh root@mbp 'bash -s' < omarchy-setup.sh
#   Options (env):  SKIP_PACKAGES=1   only (re)write the config files
#                   NO_RESTART=1      do not restart the session at the end
# Repo-only: every package comes from the Arch Linux ARM repos ([extra]); every config file below is
# written from scratch, inspired by basecamp/omarchy (tag v3.8.4 waybar/mako/hyprlock, branch quattro
# Lua bindings). Nothing is downloaded from GitHub, no AUR, no installer scripts.
# Does NOT touch /boot, the kernel, networkd, tailscale, sshd, logind/sleep drop-ins, passwords, m5-selftest.
# No pacman -Syu: uses the sync DBs already on the machine (the desktop setup did the last full upgrade).
# Rollback: tar -C /home/rolo -xzf /root/omarchy-backup/rolo-config-<ts>.tgz ; systemctl restart getty@tty2
set -euo pipefail
U=rolo; H=/home/$U; UID_N=$(id -u $U)

PKGS=(
  # desktop pieces
  alacritty fuzzel mako libnotify nautilus gvfs chromium
  hyprlock hypridle swaybg hyprpicker hyprpolkitagent satty wl-clip-persist cliphist
  # fonts (Omarchy: CaskaydiaMono Nerd Font, JetBrainsMono Nerd Font in waybar, Noto, Font Awesome)
  ttf-cascadia-mono-nerd ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji noto-fonts-cjk otf-font-awesome woff2-font-awesome
  # theme / toolkit integration
  gnome-themes-extra adwaita-icon-theme papirus-icon-theme qt5-wayland qt6-wayland xdg-user-dirs xdg-desktop-portal-gtk
  # audio stack (no audio hardware yet)
  pipewire pipewire-pulse pipewire-alsa wireplumber pamixer wiremix playerctl
  # Omarchy's terminal toolbox
  btop fastfetch starship eza fzf zoxide bat fd ripgrep jq inotify-tools imv mpv evince neovim unicode-emoji
)

# ---------------------------------------------------------------- 1. packages
if [[ -z "${SKIP_PACKAGES:-}" ]]; then
  if ! pacman -S --noconfirm --needed "${PKGS[@]}"; then
    # Kernel 7.3.0-g6d9f1ec652a6 #8 has CONFIG_SECURITY_LANDLOCK unset, so pacman 7.1's download sandbox
    # aborts ("Landlock is not supported by the kernel"). Fetch the exact files pacman wants from the
    # configured ALARM mirror as the unprivileged alpm user, then let pacman verify the signatures.
    stage=/var/tmp/omarchy-pkgs; rm -rf $stage; install -d -o alpm -g alpm $stage
    pacman -Sp --needed "${PKGS[@]}" > $stage/urls
    grep -v '^http://mirror.archlinuxarm.org/' $stage/urls && { echo "unexpected URL source"; exit 1; }
    ( cd $stage && { cat urls; sed 's/$/.sig/' urls; } | runuser -u alpm -- xargs -n1 -P5 curl -fsSLO --retry 3 )
    rm $stage/urls; chown root:root $stage/*; mv $stage/* /var/cache/pacman/pkg/; rmdir $stage
    pacman -S --noconfirm --needed "${PKGS[@]}"
  fi
fi

# ---------------------------------------------------------------- 2. backup
mkdir -p /root/omarchy-backup
( cd $H && tar -czf /root/omarchy-backup/rolo-config-$(date +%Y%m%d-%H%M%S).tgz $(ls -d .config .bash_profile .bashrc .local 2>/dev/null) )

install -d -o $U -g $U $H/.config/{hypr,waybar,mako,fuzzel,alacritty,foot,gtk-3.0,gtk-4.0,fontconfig,xdg-desktop-portal} \
  $H/.local/bin $H/.local/share/wallpapers $H/.icons/default $H/Pictures/Screenshots

# ---------------------------------------------------------------- 3. session launcher (adds PATH + toolkit env)
cat > $H/.local/bin/hypr-session <<'EOF'
#!/bin/bash
# Software-rendered Hyprland on simpledrm (no GPU driver, no render node)
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export LP_NUM_THREADS=${LP_NUM_THREADS:-16}
export WLR_RENDERER_ALLOW_SOFTWARE=1
export WLR_NO_HARDWARE_CURSORS=1
export AQ_DRM_DEVICES=/dev/dri/card0
export AQ_NO_MODIFIERS=1
export HYPRLAND_NO_RT=1
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_DESKTOP=Hyprland
export LANG=C.UTF-8
# Omarchy-style toolkit environment
export PATH=$HOME/.local/bin:$PATH
export XCURSOR_THEME=Adwaita XCURSOR_SIZE=24
export QT_QPA_PLATFORM="wayland;xcb" ELECTRON_OZONE_PLATFORM_HINT=wayland MOZ_ENABLE_WAYLAND=1
export TERMINAL=alacritty EDITOR=nvim BROWSER=chromium
log=$HOME/.cache/hyprland-tty2.log
[ -f "$log" ] && mv -f "$log" "$log.old"
exec start-hyprland > "$log" 2>&1
EOF
chmod +x $H/.local/bin/hypr-session

# ---------------------------------------------------------------- 4. Hyprland (Lua, 0.57)
cat > $H/.config/hypr/hyprland.lua <<'EOF'
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

dofile(HOME .. "/.config/hypr/bindings.lua")
EOF

cat > $H/.config/hypr/bindings.lua <<'EOF'
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
EOF

# ---------------------------------------------------------------- 5. idle + lock (lock only: sleep is blocked by logind/sleep drop-ins)
cat > $H/.config/hypr/hypridle.conf <<'EOF'
# Lock only. No dpms (simpledrm), no suspend (blocked by the bring-up's sleep drop-ins).
general {
    lock_cmd = pidof hyprlock || hyprlock
    ignore_dbus_inhibit = false
}

# Lock after 10 minutes idle (Omarchy: screensaver 2.5 min + lock).
listener {
    timeout = 600
    on-timeout = loginctl lock-session
}
EOF
cat > $H/.config/hypr/hyprlock.conf <<'EOF'
# Omarchy hyprlock look (Tokyo Night), blur off for llvmpipe.
general {
    ignore_empty_input = true
    hide_cursor = true
}
animations {
    enabled = false
}
background {
    monitor =
    color = rgba(1a1b26ff)
    path = ~/.local/share/wallpapers/omarchy-lite.png
    blur_passes = 0
}
input-field {
    monitor =
    size = 650, 100
    position = 0, 0
    halign = center
    valign = center
    inner_color = rgba(1a1b26cc)
    outer_color = rgba(7aa2f7ff)
    outline_thickness = 4
    font_family = CaskaydiaMono Nerd Font
    font_color = rgba(c0caf5ff)
    placeholder_text = Enter Password
    check_color = rgba(9ece6aff)
    fail_text = <i>$FAIL ($ATTEMPTS)</i>
    rounding = 0
    shadow_passes = 0
    fade_on_empty = false
}
auth {
    fingerprint:enabled = false
}
EOF

# ---------------------------------------------------------------- 6. waybar (Omarchy v3.8.4 layout + window title + memory)
cat > $H/.config/waybar/config.jsonc <<'EOF'
{
  "reload_style_on_change": true,
  "layer": "top",
  "position": "top",
  "spacing": 0,
  "height": 26,
  "modules-left": ["custom/omarchy", "hyprland/workspaces", "hyprland/window"],
  "modules-center": ["clock", "custom/idle-indicator", "custom/dnd-indicator"],
  "modules-right": ["group/tray-expander", "bluetooth", "network", "pulseaudio", "cpu", "memory", "battery"],
  "hyprland/workspaces": {
    "on-click": "activate",
    "format": "{icon}",
    "format-icons": { "default": "", "1": "1", "2": "2", "3": "3", "4": "4", "5": "5",
                      "6": "6", "7": "7", "8": "8", "9": "9", "10": "0", "active": "󱓻" },
    "persistent-workspaces": { "1": [], "2": [], "3": [], "4": [], "5": [] }
  },
  "hyprland/window": { "format": "{title}", "max-length": 60, "separate-outputs": true },
  "custom/omarchy": {
    "format": "\uf303",
    "on-click": "omarchy-lite-menu",
    "on-click-right": "alacritty",
    "tooltip-format": "Menu\n\nSuper + Alt + Space"
  },
  "clock": {
    "format": "{:L%A %H:%M}",
    "format-alt": "{:L%d %B W%V %Y}",
    "tooltip": false
  },
  "network": {
    "format-icons": ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"],
    "format": "{icon}",
    "format-wifi": "{icon}",
    "format-ethernet": "󰀂",
    "format-disconnected": "󰤮",
    "tooltip-format-wifi": "{essid} ({frequency} GHz)",
    "tooltip-format-ethernet": "{ifname} {ipaddr}/{cidr}",
    "tooltip-format-disconnected": "Disconnected",
    "interval": 10,
    "on-click": "alacritty --class TUI.float -e sh -c 'networkctl status; read -n1'"
  },
  "pulseaudio": {
    "format": "{icon}",
    "format-muted": "󰝟",
    "format-icons": { "headphone": "󰋋", "headset": "󰋎", "default": ["󰕿", "󰖀", "󰕾"] },
    "tooltip-format": "Playing at {volume}%",
    "scroll-step": 5,
    "on-click": "alacritty --class TUI.float -e wiremix",
    "on-click-right": "pamixer -t"
  },
  "cpu": {
    "interval": 5,
    "format": "󰍛 {usage}%",
    "on-click": "alacritty --class TUI.float -e btop"
  },
  "memory": {
    "interval": 10,
    "format": "󰘚 {percentage}%",
    "tooltip-format": "{used:0.1f} / {total:0.1f} GiB",
    "on-click": "alacritty --class TUI.float -e btop"
  },
  "battery": {
    "format": "{capacity}% {icon}",
    "format-discharging": "{icon}",
    "format-charging": "{icon}",
    "format-plugged": "󰚥",
    "format-icons": {
      "charging": ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"],
      "default": ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    },
    "format-full": "󰂅",
    "tooltip-format-discharging": "{power:>1.0f}W↓ {capacity}%",
    "tooltip-format-charging": "{power:>1.0f}W↑ {capacity}%",
    "interval": 5,
    "states": { "warning": 20, "critical": 10 }
  },
  "bluetooth": {
    "format": "󰂯",
    "format-off": "󰂲",
    "format-disabled": "󰂲",
    "format-connected": "󰂱",
    "format-no-controller": "",
    "tooltip-format": "Devices connected: {num_connections}"
  },
  "group/tray-expander": {
    "orientation": "inherit",
    "drawer": { "transition-duration": 0, "children-class": "tray-group-item" },
    "modules": ["custom/expand-icon", "tray"]
  },
  "custom/expand-icon": { "format": "󰅁", "tooltip": false },
  "custom/idle-indicator": {
    "exec": "omarchy-lite-indicator idle",
    "return-type": "json",
    "interval": "once",
    "signal": 9,
    "on-click": "omarchy-lite-toggle idle"
  },
  "custom/dnd-indicator": {
    "exec": "omarchy-lite-indicator dnd",
    "return-type": "json",
    "interval": "once",
    "signal": 10,
    "on-click": "omarchy-lite-toggle dnd"
  },
  "tray": { "icon-size": 12, "spacing": 17 }
}
EOF
cat > $H/.config/waybar/style.css <<'EOF'
/* Omarchy v3.8.4 waybar style with the Tokyo Night palette inlined */
@define-color foreground #a9b1d6;
@define-color background #1a1b26;
@define-color accent #7aa2f7;
@define-color muted #565f89;

* {
  background-color: @background;
  color: @foreground;
  border: none;
  border-radius: 0;
  min-height: 0;
  font-family: 'JetBrainsMono Nerd Font';
  font-size: 12px;
}
.modules-left { margin-left: 8px; }
.modules-right { margin-right: 8px; }
#workspaces button { all: initial; padding: 0 6px; margin: 0 1.5px; min-width: 9px; }
#workspaces button.empty { opacity: 0.5; }
#workspaces button.active { color: @accent; }
#window { margin-left: 12px; color: @muted; }
#cpu, #memory, #battery, #pulseaudio, #custom-omarchy { min-width: 12px; margin: 0 7.5px; }
#custom-omarchy { color: @accent; font-size: 14px; }
#tray { margin-right: 16px; }
#bluetooth { margin-right: 17px; }
#network { margin-right: 13px; }
#custom-expand-icon { margin-right: 18px; }
tooltip { padding: 2px; }
#clock { margin-left: 8.75px; }
.hidden { opacity: 0; }
#custom-idle-indicator, #custom-dnd-indicator { min-width: 12px; margin-left: 5px; margin-right: 0; font-size: 10px; padding-bottom: 1px; }
#custom-idle-indicator.active, #custom-dnd-indicator.active { color: #a55555; }
#battery.warning { color: #e0af68; }
#battery.critical { color: #f7768e; }
EOF

# ---------------------------------------------------------------- 7. mako, fuzzel, terminals
cat > $H/.config/mako/config <<'EOF'
# Omarchy default/mako/core.ini + Tokyo Night colors
anchor=top-right
group-by=app-name,summary,body
default-timeout=5000
width=420
outer-margin=20
padding=10,15
border-size=2
max-icon-size=32
font=sans-serif 14px
text-color=#a9b1d6
border-color=#7aa2f7
background-color=#1a1b26

[mode=do-not-disturb]
invisible=true

[mode=do-not-disturb app-name=notify-send]
invisible=false

[urgency=critical]
default-timeout=0
layer=overlay
border-color=#f7768e

[summary~="Screenshot copied & saved"]
max-icon-size=80
format=<b>%s</b>\n%b
EOF
cat > $H/.config/fuzzel/fuzzel.ini <<'EOF'
# Launcher standing in for Omarchy's walker (walker/elephant are not in the ALARM repos)
[main]
font=CaskaydiaMono Nerd Font:size=12
prompt="❯ "
icon-theme=Papirus-Dark
terminal=alacritty -e
layer=overlay
width=40
lines=10
horizontal-pad=20
vertical-pad=14
inner-pad=8
line-height=22
anchor=center
exit-on-keyboard-focus-loss=yes

[colors]
background=1a1b26ff
text=a9b1d6ff
prompt=7aa2f7ff
placeholder=565f89ff
input=c0caf5ff
match=7aa2f7ff
selection=292e42ff
selection-text=c0caf5ff
selection-match=7dcfffff
border=7aa2f7ff

[border]
width=2
radius=0
EOF
cat > $H/.config/alacritty/alacritty.toml <<'EOF'
# Omarchy alacritty.toml + Tokyo Night theme
[env]
TERM = "xterm-256color"

[font]
normal = { family = "CaskaydiaMono Nerd Font", style = "Regular" }
bold = { family = "CaskaydiaMono Nerd Font", style = "Bold" }
italic = { family = "CaskaydiaMono Nerd Font", style = "Italic" }
size = 10

[window]
padding.x = 14
padding.y = 14
decorations = "None"

[keyboard]
bindings = [
  { key = "Insert", mods = "Shift", action = "Paste" },
  { key = "Insert", mods = "Control", action = "Copy" },
]

[colors.primary]
background = "#1a1b26"
foreground = "#a9b1d6"

[colors.selection]
background = "#7aa2f7"

[colors.normal]
black = "#32344a"
red = "#f7768e"
green = "#9ece6a"
yellow = "#e0af68"
blue = "#7aa2f7"
magenta = "#ad8ee6"
cyan = "#449dab"
white = "#787c99"

[colors.bright]
black = "#444b6a"
red = "#ff7a93"
green = "#b9f27c"
yellow = "#ff9e64"
blue = "#7da6ff"
magenta = "#bb9af7"
cyan = "#0db9d7"
white = "#acb0d0"
EOF
cat > $H/.config/foot/foot.ini <<'EOF'
# Fallback terminal (Super+Alt+Return), Tokyo Night
font=CaskaydiaMono Nerd Font:size=10
pad=14x14
[colors]
background=1a1b26
foreground=a9b1d6
regular0=32344a
regular1=f7768e
regular2=9ece6a
regular3=e0af68
regular4=7aa2f7
regular5=ad8ee6
regular6=449dab
regular7=787c99
bright0=444b6a
bright1=ff7a93
bright2=b9f27c
bright3=ff9e64
bright4=7da6ff
bright5=bb9af7
bright6=0db9d7
bright7=acb0d0
EOF

# ---------------------------------------------------------------- 8. theme: GTK dark, icons, cursor, fonts, portals, default apps
for v in 3.0 4.0; do
cat > $H/.config/gtk-$v/settings.ini <<'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-font-name=Liberation Sans 11
gtk-application-prefer-dark-theme=1
EOF
done
cat > $H/.icons/default/index.theme <<'EOF'
[Icon Theme]
Inherits=Adwaita
EOF
cat > $H/.config/fontconfig/fonts.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- Omarchy fontconfig: Liberation for sans/serif, CaskaydiaMono Nerd Font for monospace, Noto as fallback -->
<fontconfig>
  <alias><family>sans-serif</family><prefer><family>Liberation Sans</family><family>Noto Sans</family><family>Noto Color Emoji</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Liberation Serif</family><family>Noto Serif</family><family>Noto Color Emoji</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>CaskaydiaMono Nerd Font</family><family>Noto Sans Mono</family><family>Noto Color Emoji</family></prefer></alias>
  <alias><family>system-ui</family><prefer><family>Liberation Sans</family></prefer></alias>
</fontconfig>
EOF
cat > $H/.config/xdg-desktop-portal/hyprland-portals.conf <<'EOF'
[preferred]
default=hyprland;gtk
org.freedesktop.impl.portal.FileChooser=gtk
EOF
cat > $H/.config/mimeapps.list <<'EOF'
[Default Applications]
text/html=chromium.desktop
x-scheme-handler/http=chromium.desktop
x-scheme-handler/https=chromium.desktop
x-scheme-handler/about=chromium.desktop
inode/directory=org.gnome.Nautilus.desktop
application/pdf=org.gnome.Evince.desktop
image/png=imv.desktop
image/jpeg=imv.desktop
image/gif=imv.desktop
image/webp=imv.desktop
video/mp4=mpv.desktop
video/webm=mpv.desktop
video/x-matroska=mpv.desktop
audio/mpeg=mpv.desktop
text/plain=nvim.desktop
EOF
cat > $H/.config/chromium-flags.conf <<'EOF'
--ozone-platform=wayland
--no-first-run
--disable-smooth-scrolling
--enable-features=TouchpadOverscrollHistoryNavigation
EOF

# ---------------------------------------------------------------- 9. shell (Omarchy bash defaults, trimmed)
cat > $H/.config/starship.toml <<'EOF'
add_newline = true
command_timeout = 200
format = "[$directory$git_branch$git_status]($style)$character"

[character]
error_symbol = "[✗](bold cyan)"
success_symbol = "[❯](bold cyan)"

[directory]
truncation_length = 2
truncation_symbol = "…/"
style = "bold cyan"

[git_branch]
format = "[$branch]($style) "
style = "italic cyan"

[git_status]
format = "[$all_status]($style)"
style = "cyan"
EOF
sed -i '/# >>> omarchy-lite >>>/,/# <<< omarchy-lite <<</d' $H/.bashrc
cat >> $H/.bashrc <<'EOF'
# >>> omarchy-lite >>>
export PATH=$HOME/.local/bin:$PATH EDITOR=nvim
alias ls='eza -lh --group-directories-first --icons=auto'
alias lsa='ls -a'
alias lt='eza --tree --level=2 --long --icons --git'
alias ff="fzf --preview 'bat --style=numbers --color=always {}'"
alias n='nvim'
[[ -f /usr/share/fzf/key-bindings.bash ]] && . /usr/share/fzf/key-bindings.bash
[[ -f /usr/share/fzf/completion.bash ]] && . /usr/share/fzf/completion.bash
command -v zoxide >/dev/null && eval "$(zoxide init bash)"
command -v starship >/dev/null && eval "$(starship init bash)"
# <<< omarchy-lite <<<
EOF

# ---------------------------------------------------------------- 10. helper scripts (~/.local/bin/omarchy-lite-*)
cat > $H/.local/bin/omarchy-lite-menu <<'EOF'
#!/bin/bash
# Stand-in for omarchy-menu, built on fuzzel --dmenu.
menu() { fuzzel --dmenu --prompt "$1 › " --width "${3:-32}" --lines "$2"; }
term() { alacritty --class TUI.float -e "$@"; }
go() {
  case "$1" in
    *Apps) fuzzel ;;
    *Keybindings) omarchy-lite-keybindings ;;
    *Capture) go "$(printf '%s\n' "󰹑  Screenshot region" "󰹑  Screenshot window" "󰹑  Screenshot screen" "󰈊  Color picker" | menu Capture 4)" ;;
    *"Screenshot region") omarchy-lite-screenshot region ;;
    *"Screenshot window") omarchy-lite-screenshot window ;;
    *"Screenshot screen") omarchy-lite-screenshot output ;;
    *"Color picker") hyprpicker -a ;;
    *Clipboard) cliphist list | menu Clipboard 12 70 | cliphist decode | wl-copy ;;
    *Emoji) grep -v '^#' /usr/share/unicode/emoji/emoji-test.txt 2>/dev/null | grep 'fully-qualified' | sed 's/.*# //' | menu Emoji 12 50 | cut -d' ' -f1 | tr -d '\n' | wl-copy ;;
    *Toggle) go "$(printf '%s\n' "󰒲  Idle lock" "󰂛  Notification silencing" "󰍜  Top bar" | menu Toggle 3)" ;;
    *"Idle lock") omarchy-lite-toggle idle ;;
    *"Notification silencing") omarchy-lite-toggle dnd ;;
    *"Top bar") pkill -SIGUSR1 -x waybar ;;
    *Activity) term btop ;;
    *Audio) term wiremix ;;
    *Network) term sh -c 'networkctl status; read -n1' ;;
    *About) term sh -c 'fastfetch; read -n1' ;;
    *Setup) go "$(printf '%s\n' "󰈙  Hyprland config" "󰈙  Key bindings config" "󰈙  Waybar config" "󰑓  Restart waybar" | menu Setup 4)" ;;
    *"Hyprland config") alacritty -e nvim ~/.config/hypr/hyprland.lua ;;
    *"Key bindings config") alacritty -e nvim ~/.config/hypr/bindings.lua ;;
    *"Waybar config") alacritty -e nvim ~/.config/waybar/config.jsonc ;;
    *"Restart waybar") pkill -x waybar; setsid -f waybar >/dev/null 2>&1 ;;
    *System) go "$(printf '%s\n' "󰌾  Lock" "󰍃  Log out (exit Hyprland)" | menu System 2)" ;;
    *Lock) loginctl lock-session ;;
    *"Log out"*) hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || hyprctl dispatch exit ;;
  esac
}
case "${1:-root}" in
  system)    go System ;;
  capture)   go Capture ;;
  toggle)    go Toggle ;;
  clipboard) go Clipboard ;;
  emoji)     go Emoji ;;
  *) go "$(printf '%s\n' "󰀻  Apps" "󰌌  Keybindings" "󰄀  Capture" "󰅌  Clipboard" "󰔎  Toggle" "󰄨  Activity" "󰕾  Audio" "󰀂  Network" "󰒓  Setup" "󰋼  About" "󰐥  System" | menu Go 11)" ;;
esac
EOF
cat > $H/.local/bin/omarchy-lite-keybindings <<'EOF'
#!/bin/bash
# Super+K: every described Hyprland bind, searchable (stand-in for omarchy-menu-keybindings)
hyprctl binds -j | jq -r '
  def m($b; $n): if ((.modmask / $b | floor) % 2) == 1 then $n + " + " else "" end;
  def k: if (.key | startswith("code:")) or .key == "" then
           ({"10":"1","11":"2","12":"3","13":"4","14":"5","15":"6","16":"7","17":"8","18":"9","19":"0","20":"-","21":"="}[(.keycode|tostring)] // .key)
         else .key end;
  .[] | select((.description // "") != "")
      | "\(m(64;"SUPER"))\(m(4;"CTRL"))\(m(1;"SHIFT"))\(m(8;"ALT"))\(k)\t\(.description)"' |
  awk -F'\t' '{ printf "%-34s %s\n", $1, $2 }' |
  fuzzel --dmenu --prompt "Keys › " --width 80 --lines 25 >/dev/null
EOF
cat > $H/.local/bin/omarchy-lite-screenshot <<'EOF'
#!/bin/bash
# omarchy-lite-screenshot [region|window|output]: grim (+slurp) -> ~/Pictures/Screenshots + clipboard.
# Click the notification to annotate it in satty.
mode=${1:-region}
dir=$HOME/Pictures/Screenshots; mkdir -p "$dir"
f="$dir/screenshot-$(date +%Y-%m-%d_%H-%M-%S).png"
case $mode in
  region) g=$(slurp -d -b 1a1b2680 -c 7aa2f7ff -w 2) || exit 1; grim -g "$g" "$f" ;;
  window) g=$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"'); grim -g "$g" "$f" ;;
  *)      grim "$f" ;;
esac || exit 1
wl-copy < "$f"
( a=$(notify-send -i "$f" -A default=Edit "Screenshot copied & saved" "${f/#$HOME/\~}  ·  click to edit")
  [ "$a" = default ] && satty --filename "$f" --output-filename "${f%.png}-edit.png" ) >/dev/null 2>&1 &
EOF
cat > $H/.local/bin/omarchy-lite-toggle <<'EOF'
#!/bin/bash
case "$1" in
  idle)
    if pgrep -x hypridle >/dev/null; then pkill -x hypridle; notify-send -u low "󰒲  Idle lock disabled"
    else setsid -f hypridle >/dev/null 2>&1; notify-send -u low "󰒳  Idle lock enabled"; fi
    pkill -RTMIN+9 -x waybar ;;
  dnd)
    if makoctl mode | grep -qx do-not-disturb; then makoctl mode -r do-not-disturb >/dev/null; notify-send -u low "󰂚  Notifications on"
    else notify-send -u low "󰂛  Notifications silenced"; sleep 1; makoctl mode -a do-not-disturb >/dev/null; fi
    pkill -RTMIN+10 -x waybar ;;
esac
EOF
cat > $H/.local/bin/omarchy-lite-indicator <<'EOF'
#!/bin/bash
# waybar indicators: show a red icon only when idle lock is off / notifications are silenced
case "$1" in
  idle) pgrep -x hypridle >/dev/null && echo '{"text":""}' || echo '{"text":"󰒲","class":"active","tooltip":"Idle lock disabled"}' ;;
  dnd)  makoctl mode 2>/dev/null | grep -qx do-not-disturb && echo '{"text":"󰂛","class":"active","tooltip":"Notifications silenced"}' || echo '{"text":""}' ;;
esac
EOF
cat > $H/.local/bin/omarchy-lite-webapp <<'EOF'
#!/bin/bash
exec chromium --app="$1" "${@:2}"
EOF
cat > $H/.local/bin/omarchy-lite-battery <<'EOF'
#!/bin/bash
b=$(ls -d /sys/class/power_supply/*/ 2>/dev/null | while read d; do [ "$(cat $d/type)" = Battery ] && echo $d; done | head -1)
if [ -n "$b" ]; then notify-send -u low "󰁹  Battery $(cat $b/capacity)% ($(cat $b/status))"
else notify-send -u low "󰂑  No battery driver yet"; fi
EOF
cat > $H/.local/bin/omarchy-lite-theme-apply <<'EOF'
#!/bin/bash
# GTK4/libadwaita read the dark preference from gsettings (dconf), not settings.ini
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Dark'
gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'
gsettings set org.gnome.desktop.interface cursor-size 24
gsettings set org.gnome.desktop.interface font-name 'Liberation Sans 11'
gsettings set org.gnome.desktop.interface monospace-font-name 'CaskaydiaMono Nerd Font 10'
EOF
chmod +x $H/.local/bin/omarchy-lite-*

# ---------------------------------------------------------------- 11. wallpaper (generated here: Tokyo Night gradient, no download)
python3 - $H/.local/share/wallpapers/omarchy-lite.png <<'EOF'
import sys, zlib, struct
W, H = 3456, 2234
stops = [(0.0, (0x1a, 0x1b, 0x26)), (0.55, (0x1f, 0x23, 0x35)), (0.70, (0x29, 0x2e, 0x42)), (0.72, (0x3d, 0x59, 0xa1)),
         (0.735, (0x29, 0x2e, 0x42)), (1.0, (0x13, 0x14, 0x1c))]
def color(t):
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t0 <= t <= t1:
            f = (t - t0) / (t1 - t0) if t1 > t0 else 0
            return bytes(round(a + (b - a) * f) for a, b in zip(c0, c1))
    return bytes(stops[-1][1])
raw = b"".join(b"\x00" + color(y / (H - 1)) * W for y in range(H))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
EOF

chown -R $U:$U $H

# ---------------------------------------------------------------- 12. user services: pipewire/wireplumber, xdg dirs, theme
runuser -u $U -- xdg-user-dirs-update || true
if systemctl is-active --quiet user@$UID_N.service; then
  systemctl --user -M $U@ enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
  runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$UID_N DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_N/bus $H/.local/bin/omarchy-lite-theme-apply || true
else
  # user manager not running yet: create the enablement symlinks directly
  install -d -o $U -g $U $H/.config/systemd/user/{sockets.target.wants,pipewire.service.wants}
  ln -sf /usr/lib/systemd/user/pipewire.socket       $H/.config/systemd/user/sockets.target.wants/
  ln -sf /usr/lib/systemd/user/pipewire-pulse.socket $H/.config/systemd/user/sockets.target.wants/
  ln -sf /usr/lib/systemd/user/wireplumber.service   $H/.config/systemd/user/pipewire.service.wants/
  ln -sf /usr/lib/systemd/user/wireplumber.service   $H/.config/systemd/user/pipewire-session-manager.service
  chown -R $U:$U $H/.config/systemd
fi

# ---------------------------------------------------------------- 13. restart the session (VT2)
if [[ -z "${NO_RESTART:-}" ]]; then
  rm -f /tmp/nohypr
  systemctl restart getty@tty2
fi
echo "omarchy-setup done. Super+Space apps, Super+Alt+Space menu, Super+K keys. Backup in /root/omarchy-backup/."
