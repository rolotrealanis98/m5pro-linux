#!/bin/bash
# desktop-setup.sh - Hyprland on llvmpipe/simpledrm for the M5 Pro MacBook (J716s) bring-up root.
# Run as root on the MacBook:  ssh root@mbp 'bash -s' < desktop-setup.sh
# Idempotent. Touches nothing in /boot, the kernel, networkd, tailscale, sshd, or logind/sleep drop-ins.
# Start/stop:  chvt 2 (Ctrl+Alt+F2) = desktop, chvt 1 (Ctrl+Alt+F1) = root console.
#   restart session: systemctl restart getty@tty2      stop: touch /tmp/nohypr; pkill -x start-hyprland; pkill -x Hyprland
# Nothing starts at boot: the session starts only when VT2 is opened (chvt 2 / Ctrl+Alt+F2),
# which makes logind spawn autovt@tty2 -> autologin rolo -> Hyprland.
set -euo pipefail

# 1. Packages (one full upgrade, then the desktop set)
pacman -Syu --noconfirm --needed \
  hyprland aquamarine xorg-xwayland foot kitty waybar grim slurp wl-clipboard \
  mesa mesa-utils libinput seatd noto-fonts ttf-dejavu polkit xdg-desktop-portal-hyprland \
  cage sway wayland-utils brightnessctl evtest htop \
  otf-font-awesome ttf-nerd-fonts-symbols

# 2. Desktop user: no password, no sudo. Groups for DRM/input access through logind's seat.
id rolo >/dev/null 2>&1 || useradd -m -s /bin/bash -G video,input,render,seat rolo
usermod -aG video,input,render,seat rolo

# 3. Autologin on tty2 only (drop-in applies to getty@tty2 and autovt@tty2; NOT enabled at boot)
for u in getty@tty2.service.d autovt@tty2.service.d; do
  mkdir -p /etc/systemd/system/$u
  cat > /etc/systemd/system/$u/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin rolo %I $TERM
EOF
done
systemctl daemon-reload

# 4. Session launcher: starts Hyprland only on tty2, never loops; touch /tmp/nohypr to suppress
install -d -o rolo -g rolo /home/rolo/.config/hypr /home/rolo/.local/bin /home/rolo/.cache
cat > /home/rolo/.local/bin/hypr-session <<'EOF'
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
log=$HOME/.cache/hyprland-tty2.log
[ -f "$log" ] && mv -f "$log" "$log.old"
exec start-hyprland > "$log" 2>&1
EOF
chmod +x /home/rolo/.local/bin/hypr-session
cat > /home/rolo/.bash_profile <<'EOF'
[[ -f ~/.bashrc ]] && . ~/.bashrc
# Start the desktop only on tty2 and only once per login (falls back to a shell on exit/crash)
if [[ "$(tty)" == /dev/tty2 && -z "$WAYLAND_DISPLAY" && ! -e /tmp/nohypr ]]; then
  ~/.local/bin/hypr-session
  echo "Hyprland exited (status $?). Log: ~/.cache/hyprland-tty2.log. Ctrl+Alt+F1 = root console."
fi
EOF

# 5. Hyprland 0.57 Lua config: software-rendering friendly (no blur/shadow/animations/vrr/logo)
cat > /home/rolo/.config/hypr/hyprland.lua <<'EOF'
-- M5 Pro (J716s) bring-up: Hyprland on llvmpipe over simpledrm (card0-eDP-1, 3456x2234)
hl.monitor({ output = "eDP-1", mode = "preferred", position = "0x0", scale = 2 })
hl.monitor({ output = "",      mode = "preferred", position = "auto", scale = "auto" })

local terminal = "foot"

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

hl.on("hyprland.start", function()
  hl.exec_cmd("waybar")
  hl.exec_cmd(terminal)
end)

hl.config({
  general = {
    gaps_in = 4, gaps_out = 8, border_size = 2,
    col = { active_border = "rgba(33ccffee)", inactive_border = "rgba(595959aa)" },
    layout = "dwindle", allow_tearing = false,
  },
  decoration = {
    rounding = 0,
    shadow = { enabled = false },
    blur = { enabled = false },
  },
  animations = { enabled = false },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
    background_color = "rgb(1e1e2e)",
    vrr = 0,
  },
  ecosystem = { no_update_news = true, no_donation_nag = true },
  render = { direct_scanout = false },
  cursor = { no_hardware_cursors = true },
  input = {
    kb_layout = "us",
    follow_mouse = 1,
    sensitivity = 0,
    touchpad = { natural_scroll = true, tap_to_click = true, clickfinger_behavior = true },
  },
  dwindle = { preserve_split = true },
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

local mod = "SUPER"   -- the Command key on the Apple keyboard
hl.bind(mod .. " + RETURN", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + Q", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + C", hl.dsp.window.close())
hl.bind(mod .. " + W", hl.dsp.window.close())
hl.bind(mod .. " + SHIFT + M", hl.dsp.exit())
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "down" }))
for i = 1, 10 do
  local key = i % 10
  hl.bind(mod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
  hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
-- Screenshot to ~/Pictures
hl.bind("Print", hl.dsp.exec_cmd("mkdir -p ~/Pictures && grim ~/Pictures/shot-$(date +%s).png"))
-- Keyboard backlight (kbd_backlight LED via logind) and Ctrl+F1/F2 like edimoldovan's setup
hl.bind("XF86KbdBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -d kbd_backlight set 10%+"), { locked = true, repeating = true })
hl.bind("XF86KbdBrightnessDown", hl.dsp.exec_cmd("brightnessctl -d kbd_backlight set 10%-"), { locked = true, repeating = true })
hl.bind("XF86KbdLightOnOff", hl.dsp.exec_cmd("sh -c 'if [ $(brightnessctl -d kbd_backlight get) -gt 0 ]; then brightnessctl -d kbd_backlight set 0; else brightnessctl -d kbd_backlight set 50%; fi'"), { locked = true })
hl.bind("CTRL + XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl -d kbd_backlight set 10%+"), { locked = true, repeating = true })
hl.bind("CTRL + XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -d kbd_backlight set 10%-"), { locked = true, repeating = true })
hl.bind("CTRL + F2", hl.dsp.exec_cmd("brightnessctl -d kbd_backlight set 10%+"), { locked = true, repeating = true })
hl.bind("CTRL + F1", hl.dsp.exec_cmd("brightnessctl -d kbd_backlight set 10%-"), { locked = true, repeating = true })
EOF
# 6. Waybar: stock config with the sway modules swapped for Hyprland ones
install -d -o rolo -g rolo /home/rolo/.config/waybar
sed -e 's#"sway/workspaces",#"hyprland/workspaces",#' -e '/"sway\/mode",/d' -e '/"sway\/scratchpad",/d' \
    -e 's#"sway/window"#"hyprland/window"#' -e 's#"sway/language",#"hyprland/language",#' \
    /etc/xdg/waybar/config.jsonc > /home/rolo/.config/waybar/config.jsonc

# 7. Root helper: run a command inside rolo's Hyprland session from SSH (hyprctl, grim, brightnessctl test...)
#    e.g. hyprctl-rolo hyprctl monitors ; hyprctl-rolo grim /tmp/shot.png
cat > /usr/local/bin/hyprctl-rolo <<'EOF2'
#!/bin/sh
S=$(ls -t /run/user/1001/hypr/ 2>/dev/null | head -1)
exec runuser -u rolo -- env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=$S "$@"
EOF2
chmod +x /usr/local/bin/hyprctl-rolo

# 8. Debug/evidence tools
pacman -S --noconfirm --needed libinput-tools

chown -R rolo:rolo /home/rolo
echo "desktop-setup done: chvt 2 (or Ctrl+Alt+F2) starts the session; chvt 1 returns to the root console"
