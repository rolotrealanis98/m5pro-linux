# Omarchy-style userspace on the M5 Pro MacBook (Hyprland on llvmpipe) - report, 2026-11-07

## Result
The tty2 Hyprland session is now an Omarchy-style daily driver (Tokyo Night look, Omarchy keybinding scheme and
workspace model, Omarchy waybar layout, launcher, notifications, lock, theme). Everything comes from Arch Linux ARM
`[extra]` packages plus config files I wrote; reproducible with `omarchy-setup.sh` (925 lines, all files as heredocs).
No reboot, nothing in /boot, kernel, networkd, tailscale, sshd, logind/sleep drop-ins, passwords or m5-selftest touched;
no `pacman -Syu`. sshd/tailscaled/networkd stayed active throughout.

Verified after a final `systemctl restart getty@tty2`: session comes back cleanly, `hyprctl configerrors` empty,
autostart up (swaybg, waybar, mako, hypridle, hyprpolkitagent, wl-clip-persist, cliphist), `hyprctl devices` lists
apple-mtp-multi-touch (trackpad), apple-mtp-keyboard, Logitech receiver, Apple SMC lid switch (`hyprctl-devices.txt`).
Screenshots (grim, 3456x2234): `screenshots/00-before.png` ... `07-after-restart.png`.

## What is Omarchy-like now
| Omarchy piece | Here | Notes |
|---|---|---|
| Hyprland look | Tokyo Night colors, gaps 5/10, border 2 (solid #7aa2f7), rounding 0, **animations/blur/shadows off** (Omarchy's own `software-rendering.lua` rule) | `~/.config/hypr/hyprland.lua` |
| Keybindings | Omarchy v3.8.4/quattro scheme in `~/.config/hypr/bindings.lua`, 129 described binds: Super+Return terminal, Super+Shift+Return/B browser, Super+Shift+F files, Super+Shift+N nvim, Super+Shift+T btop, Super+Space launcher, Super+Alt+Space menu, Super+Esc system menu, Super+K keybinding list, Super+W/Q close, J split, P pseudo, T float, F fullscreen, Alt+F maximize, O pin, arrows focus, Shift+arrows swap, S scratchpad, Tab/Shift+Tab/Ctrl+Tab workspaces, Alt+Tab windows, minus/equal resize, G groups, Super+C/V/X/A universal clipboard, Super+Ctrl+V clipboard history, Super+Ctrl+E emoji, Super+, notifications, Super+Ctrl+I idle toggle, Super+Ctrl+L lock, Print/Shift+Print/Ctrl+Print + Super+Ctrl+Alt+C (no Print key on the Mac) screenshots, Super+Print color picker, Super+Ctrl+Z zoom, webapps (Super+Shift+A/Y/X/E/C), media + keyboard-backlight keys kept | |
| Workspace model | 1-10 on the number row by keycode (code:10-19, layout independent), Shift = move, Shift+Alt = move silently, waybar shows 1-5 persistent, scratchpad special workspace | |
| Gestures | 3-finger horizontal = workspaces, 3-finger up = scratchpad, 4-finger down = fullscreen | |
| Waybar | Omarchy v3.8.4 layout: logo + workspaces (+ window title) left; clock + idle/DND indicators center; tray drawer, bluetooth, network, audio, **CPU %**, **memory %**, battery right. Battery module is configured (hidden until a power_supply battery exists) | `~/.config/waybar/` |
| Launcher | **fuzzel** (walker not packaged), Tokyo Night, Papirus icons | `~/.config/fuzzel/fuzzel.ini` |
| Omarchy menu | `omarchy-lite-menu` (fuzzel dmenu): Apps, Keybindings, Capture, Clipboard, Toggle, Activity, Audio, Network, Setup, About, System | `~/.local/bin/omarchy-lite-*` |
| Notifications | mako with Omarchy core.ini + Tokyo Night, DND mode + waybar indicator | |
| Terminal | **alacritty** 0.17 (ghostty not packaged), CaskaydiaMono Nerd Font, Omarchy Tokyo Night palette; foot kept as fallback (Super+Alt+Return) | starts fine on llvmpipe |
| Files | nautilus 51 (GTK4, dark via gsettings) | |
| Browser | chromium 156, Wayland; `chromium-flags.conf`: `--ozone-platform=wayland --no-first-run --disable-smooth-scrolling` | CPU below |
| Screenshots | grim/slurp/wl-clipboard -> `~/Pictures/Screenshots` + clipboard; click the notification to annotate in satty; hyprpicker | |
| Lock / idle | hyprlock (Omarchy look, blur 0), hypridle: lock after 10 min, **no dpms, no suspend** | see lock caveat |
| Theme | Adwaita-dark GTK3 + libadwaita prefer-dark, Papirus-Dark icons, Adwaita cursor 24, fontconfig Liberation Sans / CaskaydiaMono Nerd Font / Noto (+emoji, CJK), wallpaper = my own generated Tokyo Night gradient PNG via swaybg | |
| Shell | Omarchy bash bits: starship prompt, zoxide, eza aliases, fzf key bindings, bat, nvim as EDITOR | |
| Audio | pipewire + pipewire-pulse + wireplumber enabled as rolo's user units (active; dummy output only, no audio hardware) | |

## CPU cost (top, 18 cores)
- Idle, one terminal: before 99.6 % idle (Hyprland 3.6 %); after **99.5 % idle (Hyprland 5.2 %, waybar 0.1 %)** - the extra daemons cost nothing measurable (`top-idle-before.txt`, `top-idle-after.txt`).
- Two alacritty + nautilus open: Hyprland ~11 % (cursor blink repaints).
- hyprlock shown: Hyprland ~22 %.
- Chromium 156 (software compositing, maximized): static page idle: Hyprland 4-5 %, chromium ~15 %.
  A page with any animation (Wikipedia's animated 25-years logo): **Hyprland ~430 % continuously**.
  Scrolling 4 pages/s: **Hyprland ~770 % with smooth scrolling, ~200 % with `--disable-smooth-scrolling`** (now the default).
  Usable for reading/docs; video and animated sites burn 4-9 cores, because every damaged frame is a full-frame
  llvmpipe repaint on simpledrm (see desktop/REPORT.md).

## Could not be done within the repo-only limit (and why)
- **walker/elephant** (Omarchy launcher), **ghostty**, **swww**, **yaru-icon-theme**, **bibata cursor**, omarchy font/logo,
  **localsend**, Omarchy's own `omarchy-*` scripts and quattro's QML "omarchy-shell": not in the ALARM repos (or are
  Omarchy code). Replaced with fuzzel, alacritty, swaybg, Papirus, Adwaita cursor, Arch logo glyph, and small scripts I wrote.
- Omarchy's current branch (`quattro`) replaced waybar with a QML shell; I followed the last waybar layout (tag v3.8.4) and quattro's Lua bindings.
- Omarchy wallpapers/themes switcher: not copied (their images are repo content from GitHub); a generated gradient instead.
- Display brightness keys, battery readout, Wi-Fi/Bluetooth panels: no drivers yet (no backlight device, no battery power_supply, USB Ethernet only).
- uwsm/SDDM session management: kept the existing getty@tty2 autologin path to avoid changing how the session starts.

## Problems found (one line each)
- **Kernel #8 renames the panel connector eDP-1 -> `Unknown-1`**: the old config ran at scale 1 after the reboot; new config has rules for both plus a catch-all scale 2.
- **Kernel #8 has `CONFIG_SECURITY_LANDLOCK` unset**, so pacman 7.1's download sandbox fails ("Landlock is not supported by the kernel"); `pacman -S` cannot download. Worked around without touching pacman.conf: `pacman -Sp` URLs (mirror.archlinuxarm.org only), fetched with curl **as the unprivileged alpm user** into the cache, then `pacman -S` verified signatures and installed (`checking package integrity` passed). The setup script does this automatically on failure. Kernel fix: enable CONFIG_SECURITY_LANDLOCK.
- **Lock screen vs. locked account**: rolo has no password (`passwd -S` = L), so hyprlock can never accept a password. Unlock from SSH or the root console (Ctrl+Alt+F1): `pkill -USR1 -x hyprlock` (tested: unlocks in ~3 s, session intact). Until Rolando runs `passwd rolo` himself, either do that or disable idle-lock with Super+Ctrl+I (waybar then shows the red idle icon).
- Chromium's Arch first-run "Additional Terms of Service" window: suppressed with `--no-first-run`.

## Files (all written by omarchy-setup.sh, owner rolo)
`~/.local/bin/hypr-session` (adds PATH, cursor, Qt/Electron Wayland env), `~/.config/hypr/{hyprland.lua,bindings.lua,hypridle.conf,hyprlock.conf}`,
`~/.config/waybar/{config.jsonc,style.css}`, `~/.config/mako/config`, `~/.config/fuzzel/fuzzel.ini`, `~/.config/alacritty/alacritty.toml`,
`~/.config/foot/foot.ini`, `~/.config/gtk-{3.0,4.0}/settings.ini`, `~/.icons/default/index.theme`, `~/.config/fontconfig/fonts.conf`,
`~/.config/xdg-desktop-portal/hyprland-portals.conf`, `~/.config/mimeapps.list`, `~/.config/chromium-flags.conf`, `~/.config/starship.toml`,
`~/.bashrc` (marked block), `~/.local/bin/omarchy-lite-{menu,keybindings,screenshot,toggle,indicator,webapp,battery,theme-apply}`,
`~/.local/share/wallpapers/omarchy-lite.png` (generated by inline Python), pipewire/wireplumber user units enabled.

Packages (`pacman -S --needed`, 214 incl. deps, ~2 GB installed): alacritty fuzzel mako libnotify nautilus gvfs chromium
hyprlock hypridle swaybg hyprpicker hyprpolkitagent satty wl-clip-persist cliphist ttf-cascadia-mono-nerd ttf-jetbrains-mono-nerd
noto-fonts noto-fonts-emoji noto-fonts-cjk otf-font-awesome woff2-font-awesome gnome-themes-extra adwaita-icon-theme
papirus-icon-theme qt5-wayland qt6-wayland xdg-user-dirs xdg-desktop-portal-gtk pipewire pipewire-pulse pipewire-alsa wireplumber
pamixer wiremix playerctl btop fastfetch starship eza fzf zoxide bat fd ripgrep jq inotify-tools imv mpv evince neovim unicode-emoji.

## Rollback
`tar -C /home/rolo -xzf /root/omarchy-backup/rolo-config-20261107-001900.tgz && rm -rf /home/rolo/.config/{mako,fuzzel,alacritty,foot,gtk-3.0,gtk-4.0,fontconfig,xdg-desktop-portal,systemd} && systemctl restart getty@tty2`
(the tarball holds the pre-change .config/.bashrc/.bash_profile/.local; the session was not broken at any point, so no restore was needed).
