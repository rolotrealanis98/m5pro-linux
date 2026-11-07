# Hyprland desktop on the M5 Pro MacBook (J716s) - report, 2026-11-06

## Result
A Hyprland 0.57.1 desktop runs on the internal panel with software rendering (Mesa 26.2.6 llvmpipe, LLVM 23.1.4)
over simpledrm (`/dev/dri/card0`, `eDP-1`, 3456x2234@60, scale 2). It uses **stock Arch Linux ARM packages**:
no mesa-aurora and no rebuilt packages were needed. Waybar, foot, Xwayland and xdg-desktop-portal-hyprland run.
Screenshots: `screenshots/05-desktop.png`, `06-desktop-waybar-workspaces.png` (grim, 3456x2234).

| Item | State |
|---|---|
| Compositor | `start-hyprland` -> Hyprland 0.57.1 (Lua config), aquamarine 0.16.0 DRM backend, libseat via **logind** (no seatd daemon) |
| Renderer | llvmpipe, 16 rasterizer threads (`LP_NUM_THREADS=16`), GBM/kms_swrast dumb buffers, LINEAR XR24, scanout verified in `/sys/kernel/debug/dri/0/state` (`allocated by = Hyprland`, fb flips 42/43 under load) |
| Output | eDP-1 3456x2234@60, scale 2 (1728x1117 logical), notch rows included (waybar sits in them); no VRR, no HDR, no gamma, EDID unparsable (simpledrm), physical size reported 914x591 mm (wrong, comes from simpledrm) |
| Keyboard (Apple MTP keyboard, event2) | seen by libinput and Hyprland, us layout; emits KEY_KBDILLUMUP/DOWN/TOGGLE, KEY_BRIGHTNESSUP/DOWN, KEY_FN; `hid_apple fnmode=3` |
| Trackpad (Apple MTP multi-touch, event1) | libinput: `Capabilities: pointer gesture`, 157x96 mm, clickfinger, two-finger scroll, disable-while-typing on, BUTTONPAD, MT slots + pressure + BTN_TOOL_QUINTTAP: **multitouch gestures available** (3-finger horizontal swipe bound to workspaces). Tap-to-click enabled in Hyprland config |
| USB mouse/keyboard (Logitech receiver, event3/4) | pointer + keyboard in libinput and Hyprland |
| Lid/power switch (Apple SMC power/lid events) | libinput switch device, paired with keyboard/trackpad for lid handling |
| Keyboard backlight | **works**: `kbd_backlight` LED (max 255). `brightnessctl -d kbd_backlight set 60%` from inside the session (logind SetBrightness) -> brightness 153; bound to XF86KbdBrightnessUp/Down, XF86KbdLightOnOff, Ctrl+F1/F2 and Ctrl+brightness keys. Rolando should see the backlight at 60% now. Outside the session (root runuser) it fails with EPERM, as expected |
| Display brightness | no backlight device (no DCP driver), keys unbound |
| VT switching | tested: `chvt 1` -> fbcon owns the plane again (root console), Hyprland stays alive; `chvt 2` -> Hyprland takes the plane back, dpms on |
| Boot | nothing new enabled. `getty@tty2` is disabled; the session starts only when VT2 is opened (logind autovt) -> autologin `rolo` -> `~/.bash_profile` -> `hypr-session` |

### CPU cost (llvmpipe, `top`)
- Idle desktop (clock + bar): Hyprland 0-5 %, 16 % with two terminals whose cursors repaint.
- A terminal running `top -d 0.5` (half the screen updating twice a second): Hyprland ~48 % (one core half busy).
- `es2gears_wayland` (continuous animation): **70-86 FPS** client-side, ~81 compositor commits/s, Hyprland **~880 %** (all 16
  llvmpipe threads at ~60 % each; Hyprland main thread 10 %), es2gears itself 63 %. Total system ~46 % of 18 cores.
- Interpretation: every composited frame costs ~0.1 core-seconds, i.e. a near full-frame 7.7 Mpixel repaint in
  llvmpipe. simpledrm has no vblank, so frames are not throttled to 60 Hz (81 commits/s > 60). Interactive feel is
  fine for terminals; anything animating burns ~9 cores. Latency impression from the numbers: a frame takes ~6-12 ms
  wall-clock on 16 threads, so typing/pointer latency is dominated by the uncapped loop, not by rendering.

## Steps (reproducible: `desktop-setup.sh`)
1. `pacman -Syu --needed hyprland aquamarine xorg-xwayland foot kitty waybar grim slurp wl-clipboard mesa mesa-utils libinput seatd noto-fonts ttf-dejavu polkit xdg-desktop-portal-hyprland cage sway wayland-utils brightnessctl evtest htop otf-font-awesome ttf-nerd-fonts-symbols` (301 packages; systemd 261.2->262.1, openssh 10.4p1->10.6p1 (sshd restarted by the hook, session survived); networkd, tailscale, sshd stayed active; nothing written to /boot).
2. `useradd -m -G video,input,render,seat rolo` (password locked, no sudo; sudo is not even installed).
3. Drop-ins `/etc/systemd/system/{getty,autovt}@tty2.service.d/autologin.conf` (`agetty --autologin rolo`), not enabled.
4. `~rolo/.local/bin/hypr-session` exports `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe LP_NUM_THREADS=16 WLR_RENDERER_ALLOW_SOFTWARE=1 WLR_NO_HARDWARE_CURSORS=1 AQ_DRM_DEVICES=/dev/dri/card0 AQ_NO_MODIFIERS=1 HYPRLAND_NO_RT=1 LANG=C.UTF-8` and execs `start-hyprland` (log `~/.cache/hyprland-tty2.log`, real log `/run/user/1001/hypr/*/hyprland.log`). `~/.bash_profile` runs it only on `/dev/tty2`, only if `/tmp/nohypr` is absent, and falls back to a shell when Hyprland exits (no respawn loop).
5. `~rolo/.config/hypr/hyprland.lua` (0.57 uses Lua; `hyprland.conf` is gone): blur/shadow/animations off, rounding 0, `misc.vrr=0`, `disable_hyprland_logo`, `disable_splash_rendering`, `force_default_wallpaper=0`, `render.direct_scanout=false`, `cursor.no_hardware_cursors=true`, `ecosystem.no_update_news/no_donation_nag`, touchpad natural scroll + tap + clickfinger, 3-finger swipe, binds (below).
6. Waybar config = stock with sway modules swapped for `hyprland/workspaces|window|language`.
7. `/usr/local/bin/hyprctl-rolo` (root helper to run hyprctl/grim inside the session), `libinput-tools`.

Control: `chvt 2`/Ctrl+Alt+F2 desktop, `chvt 1`/Ctrl+Alt+F1 root console; `systemctl restart getty@tty2` restarts the
session; stop: `touch /tmp/nohypr; pkill -x start-hyprland; pkill -x Hyprland`.
Binds: Cmd(Super)+Return or +Q terminal, +C/+W close, +F fullscreen, +V float, +arrows focus, +1..0 workspace,
+Shift+1..0 move, +Shift+M exit, Super+LMB/RMB drag/resize, Print = grim to ~/Pictures.

## What failed / quirks (with log excerpts, `logs/`)
1. **aquamarine has no renderer for simpledrm and retries on every commit** (harmless functionally, log spam ~4 lines/frame):
   ```
   ERR from aquamarine ]: [EGL] Command eglQueryDeviceStringEXT errored out with EGL_BAD_PARAMETER (0x12300)
   ERR from aquamarine ]: CDRMRenderer(drm): Can't create renderer, no matching devices found
   ERR from aquamarine ]: drm: initMgpu: no renderer
   ERR from aquamarine ]: drm: Failed to update renderer state for eDP-1 on applyCommit
   ```
   Cause: Mesa's EGL device list (egldevice.c) only adds DRM devices with a render node, so card0 (KMS-only) never
   matches; aquamarine v0.16.0 `CDRMBackend::registerGPU` (DRM.cpp:1124) only clears `rendererRequired` for evdi, so
   `updateSecondaryRendererState()` calls `initMgpu()` (new GBM device + EGL device scan) on every `applyCommit`.
   Measured overhead is small (Hyprland main thread 10 % at 81 fps; no thread churn), the cost is the log in
   `/run/user/1001` (tmpfs, ~30 KB/s while animating, 0 when idle). Fix: `aquamarine-simpledrm-no-renderer.patch`
   (treat `simpledrm` like evdi, plus an `AQ_DRM_NO_RENDERER` override). **Not built**: compiling the upstream
   aquamarine source on the MacBook was refused by this session's permission policy; Rolando can build it (cmake,
   install to /opt/aquamarine-simpledrm and add `LD_LIBRARY_PATH` in hypr-session, or rebuild the Arch package with the patch).
2. `drm: failed to parse edid` and physical size 914x591 mm: simpledrm has no EDID; the DT framebuffer node lacks
   panel width/height-mm. Harmless with an explicit `scale = 2`.
3. eglinfo: GBM/Wayland/X11 platforms fail outside a session ("Not allowed to force software rendering when API explicitly selects a hardware device", no render node); surfaceless/device -> llvmpipe 4.6 core/ES 3.2. Inside the compositor GBM on card0 works (kms_swrast).
4. Clients print `MESA-EGL: failed to get driver name for fd -1`, `ZINK: vkCreateInstance failed` before falling back to llvmpipe (no Vulkan driver); harmless. Xwayland runs without GLAMOR.
5. `Hyprland is being launched without start-hyprland` nag and the 0.57.1 news popup: fixed (start-hyprland, `ecosystem.no_update_news`).
6. foot `'C' is not a UTF-8 locale`: fixed with `LANG=C.UTF-8` in the session (system locale left as is).
7. Waybar icons missing: fixed with otf-font-awesome + ttf-nerd-fonts-symbols.
8. Live input confirmed while Rolando used the machine (`libinput debug-events` observer, key names hidden, ~8 min):
   event3 Logitech mouse 1452 motion + 8 button events, event1 trackpad 131 motion + 2 button (click) events,
   event2 internal keyboard 4 key events; Hyprland's cursor moved (cursorpos 864,558 -> 1150,148), `screenshots/07-latest.png`.
   No trackpad GESTURE events were produced in that window (nobody swiped), so gestures are "advertised by libinput", not yet exercised.

## Next items
Kernel / DT:
- simpledrm vblank: there is no vblank/page-flip pacing, so compositors run uncapped (81 fps measured). A real display
  driver (DCP) is the fix; short of that, nothing in simpledrm throttles.
- DT framebuffer node: add panel `width-mm`/`height-mm` (or equivalent) so simpledrm reports a real physical size (~345x223 mm).
- Display backlight: no `/sys/class/backlight` (needs DCP or a backlight node); keyboard backlight is fine.
- CONFIG_ZRAM (edimoldovan's note) before running a heavier Omarchy session.
Userspace:
- aquamarine: upstream the simpledrm `rendererRequired=false` patch (above); until then, consider `debug.disable_logs`
  for long sessions.
- Frame cost: ~0.1 core-s per frame looks like full-frame repaints; check Hyprland damage/buffer-age on kms_swrast
  dumb buffers (debug.damage_blink) and try `LP_NUM_THREADS=18`; a 60 Hz cap would cut animation cost ~25 %.
- Omarchy proper (omarchy-mac packages, SDDM/UWSM) can sit on top of this; mesa-aurora is not required for llvmpipe
  (stock Arch mesa 26.2.6 already ships llvmpipe + kms_swrast); it matters only once the GPU (asahi/aurora DRM) works.
