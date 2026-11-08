# Hyprland on the DCP: the two-card session (render on the GPU, scanout on the DCP)

Status: installed on the MacBook 2026-11-08 02:47 UTC (backups `<file>.pre-dcp`, `install.sh --uninstall` reverts);
first boot on the DCP daily test twin queued. Nothing here has run against a real apple-drm card yet.

## How aquamarine 0.16 handles the two cards

- Only KMS cards count as display devices; the aurora card is skipped ("not a KMS device"). `AQ_DRM_DEVICES` names
  the apple card, found by driver name (`hypr-cards.sh`), never by card number. `AQ_NO_KMS_REQUIREMENT` must stay
  unset.
- The render device is not chosen: aquamarine falls back to the only `renderD` node (renderD128, the GPU). Two
  `renderD` nodes would mean software rendering; the pre-check and the verifier count them (`DRM_ASAHI=y` could add one).
- Scanout buffers are LINEAR dumb buffers on the apple card, rendered into directly by the GPU; no multi-GPU copy,
  no CPU copy (the simpledrm path copied every frame).
- `AQ_NO_MODIFIERS=1` for the first boots: apple-drm on firmware 27 also advertises `APPLE_INTERCHANGE` on the
  T6050. Touch `/etc/hypr-dcp-modifiers` to try without it.
- Explicit sync needs no setting (timeline syncobjs on both cards; Hyprland 0.57 enables it itself).

## Profile `m5pro-dcp.lua`

3456x2234@120 scale 2 on eDP-1 and eDP-2 (exact names, 0.57 has no globs), `render:direct_scanout=1`, software
cursor (apple-drm has no cursor plane) with `inactive_timeout=3`, `misc:vrr=1` only when the launcher exports
`M5PRO_PANEL_VRR=1` (from `vrr_capable` or `appledrm.fw27_panel_vrr`), `debug:vfr=true`, animations back on with
Omarchy's curves, blur on. Omarchy's `no-animations` and Glassy toggles win. With the Lua config there is no
`hyprctl keyword`; use `hyprctl eval 'hl.config({ misc = { vrr = 1 } })'`.

## Launchers

`hypr-gpu-session` waits up to 20 s for a connected eDP on the apple card, exports the display card, the profile,
`M5PRO_PANEL_VRR` and `AQ_NO_MODIFIERS=1`, drops `HYPRLAND_NO_RT`; `/etc/hypr-dcp-disable` forces the simpledrm
path. `hypr-session` keeps the 30 s software fallback, now on the apple card at 60 Hz. Both follow
`/etc/mesa-aurora/session.env` (zink or native). `/run/hypr-dcp-trace` gives one boot of `AQ_TRACE`/`HYPRLAND_TRACE`.

## Verifier `hypr-dcp-verify` (root, ~2 min; `--static`, `--quick`)

Static: cards and `renderD` count, backend "with driver apple", renderer not llvmpipe, LINEAR 3456x2234 scanout
buffer, explicit sync, `hyprctl monitors -j` at 120 Hz with `vrrCapable`, direct-scanout blockers, DCP/GPU errors.
Timed (private tracefs instance on `dcp:iomfb_swap_complete`): idle, vkcube 20 s (pass: median >= 115 swaps/s,
8.0-8.7 ms, < 2 % late), glmark2, mpv fullscreen (direct scanout), and on the VRR twin a 50 fps client with VRR off
then on (pass: typical interval 19-21 ms, >= 80 % within 1.5 ms of 20). Every step has a timeout; it never reboots.

Results: appended below after the first boots.
