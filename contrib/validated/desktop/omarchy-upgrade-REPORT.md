# Omarchy 4.5.0 on the M5 Pro root (2026-11-07) — coordinator's copy of the agent report

Installed from the official signed aarch64 packages (pkgs.omarchy.org stable): omarchy 4.5.0-3, omarchy-settings,
quickshell 0.3.2, yaru-icon-theme, hyprsunset, mise-bin, xdg-terminal-exec (35 packages). Not an upgrade: the root
ran a hand-written "omarchy-lite" (Lua Hyprland + Waybar + Mako + swaybg). No reboot, nothing under /boot (485 ESP
files unchanged), no kernel/boot/Mesa/Hyprland/aquamarine/PipeWire/WirePlumber change; hyprland 0.57.1, aquamarine
0.16.0, mesa 26.2.6, pipewire 1.6.10, wireplumber 0.5.18 unchanged.

Held back: omarchy-mac, omarchy-mac-boot (limine, m1n1, uboot-asahi, asahi-scripts, linux-aurora…),
omarchy-apply-system (mkinitcpio -P, Plymouth, boot entries, SDDM, disables systemd-networkd), the ~110 optional
apps, NetworkManager switch (SDDM and NetworkManager installed but not enabled).

Guards: IgnorePkg for the boot chain (# m5pro-boot-guard) + pacman hook /etc/pacman.d/hooks/00-m5pro-boot-guard.hook
(override M5PRO_ALLOW_BOOT_PKGS=1); [omarchy] last in pacman.conf so ALARM wins; Omarchy's own hook blocks a plain
`pacman -Syu` (use `omarchy update` or OMARCHY_ALLOW_DIRECT_PACMAN=1; -S/-U still work). Do not run `omarchy update`
unattended (a Mesa/LLVM update could break /opt/mesa-aurora).

User setup: /etc/skel copied, `omarchy-provision-user --first-install` (218 migrations marked done). Our settings
re-applied in ~/.config/hypr/m5pro.lua (blur/shadows/animations off, no direct scanout, software cursor, keyboard
40/600, touchpad natural/tap/clickfinger, gestures) + `require("hypr.m5pro")` and the trackpad dofile at the end of
Omarchy's hyprland.lua; scale 2 and eDP-1/Unknown-1 in monitors.lua; ~/.bash_profile restored (tty2 hypr-session
autostart; Omarchy's kept as .bash_profile.omarchy-skel); Chromium flags merged. Fallback: `m5pro-desktop
lite|omarchy|status` (lite = old Waybar desktop from ~/.config/hypr-lite at the next Hyprland start).

Backups: /root/omarchy-backup/pre-quattro-20261107-204200/ (etc, home-rolo, local-bits), .pre-quattro copies of
replaced user files incl. all of ~/.config/hypr, /etc/pacman.conf.pre-quattro.

Verified unchanged: 95 protected files/dirs (trackpad presets, libinput quirks, 99-asahi-j716 WirePlumber, UCM,
speakersafetyd, /usr/local/bin, /opt/mesa-aurora, /opt/gpubench, m5pro logind/sleep/udev, network); systemd-networkd
and wpa_supplicant@wlan0 active; configs parse. `Hyprland --verify-config` on the Omarchy config only passes with a
verify wrapper (Omarchy startup-cursor.lua:79 passes an unset HYPRLAND_INSTANCE_SIGNATURE; Hyprland 0.57.1 segfaults
tearing down Lua timers in verify mode) — both upstream bugs worth reporting.

omarchy-settings side effects left in place: nsswitch mdns_minimal (nss-mdns absent, skipped), faillock deny 10,
Plymouth config, /etc/skel/.bashrc, sysctl (swappiness 150), 5 s stop timeout.

Next login checklist: Quickshell bar appears (journalctl --user -t omarchy-shell -b, ~/.cache/hyprland-gpu.log);
Super+Return Alacritty, Super+Space menu, Super+K bindings; trackpad/gestures/scale/speakers as before; lock screen
Super+Ctrl+L unlocks (else `sudo omarchy-setup-lock`; rolo not in wheel). Expected noise: network widget offline and
first-run asks for Wi-Fi (NetworkManager not running on purpose); first-run retries each login (omarchy-mac,
bt-agent, owed, fcitx5 absent).

Scripts: ~/Work/agents/omarchy-upgrade/scripts/ (10-60; also /root/omarchy-upgrade/ on the machine); logs/; upstream/.
Repo note: contrib/validated/desktop/omarchy-upgrade.md (bfcb493).
