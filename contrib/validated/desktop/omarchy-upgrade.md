# Omarchy 4.5 ("Quattro") on the J716s root

Validated 2026-11-07 on the MacBook Pro 16-inch M5 Pro (J716s), Arch Linux ARM root, kernel 7.3.0-g3671d907d570.
No reboot, nothing written to the ESP, no desktop session started during the change.

## Starting point

The root ran "omarchy-lite": a hand-written Lua Hyprland config with Waybar, Mako and swaybg from the Arch Linux
ARM repos (see `omarchy/`). There was no Omarchy checkout or package, so the Omarchy Mac 3.x -> Quattro script
(`omarchy-upgrade-to-quattro-mac`) does not apply. Hyprland 0.57.1 was already configured in Lua.

## What upstream ships for Apple Silicon (Omarchy 4.5.0)

- pkgs.omarchy.org publishes aarch64 builds on stable/rc/edge. `omarchy` and `omarchy-settings` 4.5.0-3 are the
  same packages on stable and edge (identical sha256); `quickshell` is Omarchy's 0.3.2.r7 build (stable -1 built
  against Qt 6.12.0, edge -7 against the exact Qt 6.12.0-3/-4 ALARM ships).
- Apple Silicon additionally gets `omarchy-mac` (Wi-Fi backend, speaker safety, notch, keyboard) and
  `omarchy-mac-boot` (initramfs, Limine, U-Boot, m1n1, update verification). `omarchy-mac-boot` depends on
  `limine`, `limine-mkinitcpio-hook`, `m1n1`, `uboot-asahi`, `asahi-scripts`; the repo also carries
  `linux-aurora`, `m1n1-aurora`, `uboot-aurora`, `mesa-aurora`.
- `omarchy-apply-system` and the Omarchy Mac `install.sh` run `mkinitcpio -P`, add the Plymouth hook, edit boot
  entries, enable SDDM, disable systemd-networkd and move the network to NetworkManager.
  `omarchy-reinstall-configs` also refreshes Limine and Plymouth (initramfs rebuild).

None of that is compatible with a hand-built ESP payload and a network that must stay up for remote access.

## What was done

1. Backups: `/etc`, `~rolo` and the audio/GPU bits archived; `.pre-quattro` copies of every user file replaced.
2. Boot guard: `IgnorePkg` for kernel/boot packages plus a pacman hook (`00-m5pro-boot-guard.hook`) that aborts
   any transaction installing or upgrading them (override: `M5PRO_ALLOW_BOOT_PKGS=1`). Tested with a dummy
   `linux-asahi-guardtest` package: refused.
3. `[omarchy]` (stable) appended last in `pacman.conf`, key 40DFB630FF42BCFFB047046CF0134EE680CAC571 imported.
4. Installed `omarchy/omarchy omarchy/omarchy-settings omarchy/quickshell omarchy/yaru-icon-theme hyprsunset`
   (33 packages incl. deps; no kernel/boot/Mesa/Hyprland/PipeWire package touched), then `omarchy/mise-bin` and
   `extra/xdg-terminal-exec`. `ttf-jetbrains-mono-nerd` is replaced by Omarchy's `-basic` (conflict).
   mkinitcpio hooks masked for the transaction (no presets exist; restored afterwards).
5. User step as a fresh install does it, without the system parts: `cp -a /etc/skel/. ~`, then
   `OMARCHY_THEME_HEADLESS=1 omarchy-provision-user --first-install` (marks all 218 migrations done).
6. Re-applied: `~/.config/hypr/m5pro.lua` (effects off for simpledrm/llvmpipe/zink, no direct scanout, software
   cursor, keyboard and touchpad settings, gestures), `require("hypr.m5pro")` + the trackpad preset `dofile` at
   the end of Omarchy's `hyprland.lua`, scale 2 and the eDP-1/Unknown-1 lines in `monitors.lua`, our
   `~/.bash_profile` (tty2 autostart; `/etc/skel` had replaced it), two Chromium flags.
7. Fallback: `m5pro-desktop lite|omarchy|status` (`~/.local/bin`) toggles a flag that Omarchy's `hyprland.lua`
   checks first; `lite` loads `~/.config/hypr-lite/` (the pre-Quattro config) at the next Hyprland start.

Session launch is unchanged: getty@tty2 autologin -> `hypr-session` / `hypr-gpu-session` -> `start-hyprland`.
SDDM and NetworkManager are installed (hard dependencies of `omarchy`) but not enabled.

## Results

- ESP: 485 files hash-identical. Protected customisations hash-identical (trackpad presets, libinput quirks,
  WirePlumber j716 fragments, UCM, speakersafetyd, `/usr/local/bin`, `/opt/mesa-aurora`, `/opt/gpubench`,
  logind/sleep/udev m5pro files, network config). Enabled system units unchanged.
- `spa-json-dump` OK on all PipeWire/WirePlumber configs; `alsaucm` loads; `libinput quirks validate` OK.
- `Hyprland --verify-config`: the lite config passes as is. The Omarchy config passes ("config ok") once
  `HYPRLAND_INSTANCE_SIGNATURE` is set and `hl.timer` is stubbed. Without that, verify mode fails on two bugs
  that a live session does not hit: Omarchy's `default/hypr/startup-cursor.lua:79` passes the unset signature to
  `hl.env`, and Hyprland 0.57.1 segfaults in `CConfigManager::cleanTimers` -> `CEventLoopManager::removeTimer`
  (no event loop in verify mode).
- `uwsm-app` works outside a uwsm session, so Omarchy's `o.launch` bindings work under `start-hyprland`.
- Quickshell resolves the Omarchy shell's QML offscreen up to the first `PanelWindow`; rendering needs the session.

## Side effects of omarchy-settings 4.5 on Apple Silicon

`/etc/nsswitch.conf` gains `mdns_minimal [NOTFOUND=return]` (nss-mdns absent, skipped), faillock `deny = 10`,
Plymouth config and `/etc/skel/.bashrc` replaced, logind `10-ignore-power-button` and `20-inhibit-delay`
(our m5pro logind files sort later and still win), sysctl (swappiness 150, dirty limits, ARP), 5 s stop timeout,
inert NetworkManager/zram/usbcore drop-ins. `00-omarchy-update-guard.hook` makes a plain `pacman -Syu` stop;
use `omarchy update` or `OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu`.

## Open

- First login not yet seen. The Omarchy network UI expects NetworkManager, so it shows offline and the first-run
  step nags for Wi-Fi; first-run also retries each login (no `omarchy-mac`, missing bt-agent/owed/fcitx5 units).
- `omarchy update` is a full `pacman -Syu`; a Mesa/LLVM bump could break `/opt/mesa-aurora`. Run it attended.
- Upstream reports to file: Omarchy `startup-cursor.lua` in verify mode; Hyprland 0.57.1 verify-mode timer crash.
