# VRR on the J716s panel through the DCP (firmware 27.3) — analysis, 2026-11-07

Nothing ran on the MacBook; patches compile-checked only (checkpatch --strict clean, clang -fsyntax-only with the
j716s-series-gpu-27 flags). Test order: after display stage C and after 120 Hz is validated.

## Verdict: feasible through the DCP

- The control is IOMFBParameter 15 "adaptive_sync", sent with `set_parameter_dcp` (A500 on 27.2/27.3, A450 on
  27.0; input 0x28 bytes `{u32 param; u64 value[4]; u32 count}`). Case 15 takes 1-3 values: minRR (16.16 Hz),
  mediaTargetRate (16.16 Hz), fractional flag; target > 120 Hz or flag > 1 zeroes both. Case 31 = external_sync.
  Case 14 (the desktop 26.6 constant) is an unrelated setter on 27.x and must never be sent.
- `set_display_refresh_properties` (A526) takes no input; it publishes the IOMFBDisplayRefresh dictionary once at
  boot (refresh interval 8.333-41.667 ms = 120-24 Hz, 4.167 ms steps). The range is applied at mode selection
  (`program_M3_gen_config`, `init_timing_mode_params`), not live.
- Frames are paced by swaps inside [minRR, 120 Hz] in 240 Hz subframes (ADT disp0 `subframe-duration-nclks` =
  4.17 ms; macOS publishes IOMFBSupportsLFC = Yes). Swap timestamps (words 0, 1, 6) are at the same place in the
  27.3 swap layout.
- Panel: ADT disp0 `supports-apt=1`, no refresh-range property anywhere. Six timings at 3456x2234: ID 2 = 120 Hz
  (preferred), IDs 3-7 = 60, 48, 59.94, 47.952, 50 Hz ("IsPromoted"); all report Min/MaximumVariableRefreshRate = 0.
  Runtime properties APTFixedRR (#107) and limitRefreshRate (#135) are unusable now (no method tag; a wrong tag
  crashes the DCP).
- What macOS sends is not provable statically (inference: ProMotion = timing 2 + minRR 24 Hz; fixed = a promoted
  timing and/or APTFixedRR). Confirming needs an m1n1 hypervisor trace of A500 while switching refresh in macOS.
- Prior art: Aurora VRR on the J616s panel (26.6 firmware, parameter 14; linux #763), M1/M2 ProMotion VRR;
  external VRR #776 reverted in #788, H17P external VRR refused (#294); Asahi chadmed #477 open. Nobody has done
  firmware 27 or T6050.
- dcp/27.3 already sends parameter 15 in the firmware-27 mode set and wires vrr_capable; gaps: the zero range is
  turned into 24-120 only on desktop 26.6 (on 27.x the panel parses as fixed), and VRR_ENABLED in a plain page
  flip never reached the firmware.

## Patches (branch dcp/27.3-vrr in /Volumes/linux-cs/wt-vrr, cut from dcp/27.3 716bce007fd3)

- 0001 `drm/apple: Name the firmware 27 adaptive sync parameter` (IOMFBPARAM_ADAPTIVE_SYNC_V27 = 15; no change).
- 0002 `drm/apple: Offer VRR on the firmware 27 panel and apply VRR_ENABLED`, opt-in `appledrm.fw27_panel_vrr=1`:
  zero range -> 24-120 Hz on the 120 Hz timing, connector reports vrr_capable + range; a flip that changes
  VRR_ENABLED re-selects the current mode from dcp_flush() (parameter 15 {24<<16 or 0,0,0}, then
  set_digital_out_mode; ~200 ms dark, no ALLOW_MODESET needed; failure drops the frame and marks VRR failed);
  swap watchdog 1 s while VRR is on (fires -> VRR off for good, fixed-rate retrain);
  `appledrm.fw27_counter_timestamps=0` swaps ARM-counter timestamps for the constant 120 of desktop 26.6.
- `on-promotion/`: the same two on top of the 120 Hz agent's three patches (two small conflicts resolved).

## Fallback: fixed-rate mode sets (timings 2-7) via `hyprctl keyword monitor eDP-1,3456x2234@60,...`, ~200 ms dark
each; unverified that firmware 27 accepts set_digital_out_mode for a promoted timing on the internal panel.
Hyprland: `misc:vrr = 1` (toggle once at startup; 2/3 would blank 200 ms per fullscreen change), keep
`cursor:min_refresh_rate = 24`.

## Risks: a wrong payload crashes the DCP (black until cold boot) — parameter number verified in three builds,
minRR 24 Hz = the panel's floor, Aurora already sends {15,0,0,0} at every fw-27 power-on; minRR validation inside
the setter unresolved. Mode set inside a flip assumes an idle present queue; a firmware timeout blocks up to 8.5 s.
Counter timestamps unproven on H17 (knob above).

## Attended test plan (stop on `DCP has crashed`, `swap failed`, `set_digital_out_mode timed out|returned`,
`adaptive swap timed out`)
V0 default boot: modetest shows vrr_capable 0, mode @120 on timing 2 (120 Hz regression check).
V1 `appledrm.fw27_panel_vrr=1 drm.debug=0x1e`: vrr_capable 1; debugfs vrr_range 24-120 (121 until the EDID fix).
V2 console: `modetest -M appledrm -a -s <conn>@<crtc>:3456x2234-120 -w <crtc>:VRR_ENABLED:1 -v`, then 0; pass =
dmesg `VRR_ENABLED 1: selecting ... again`, panel back within ~0.3 s, flips continue.
V3 Hyprland `misc { vrr = 1 }`, `hyprctl monitors` shows vrr: true. V4 variable-rate content (vkcube with
MANGOHUD fps_limit 50|40|30, mpv --video-sync=display-desync). V5 trace-cmd on dcp:iomfb_swap_submit/complete,
iomfb_vrr_timestamps, drm_vblank_event: at 50 fps intervals cluster at 20.8 ms, no swaps on a static desktop.
V6 misc:vrr = 2, 10 fullscreen toggles, no watchdog. V7 if stalls: fw27_counter_timestamps=0. V8 idle power.
Redact the EDID serial from dumps.

## Coordination with the 120 Hz work (contrib/pending/dcp/promotion)
- Their TEST-PLAN expects vrr_capable = 1: on dcp/27.3 only with patch 0002 and fw27_panel_vrr=1.
- Their 0003 synthesizes fixed rates on one timing; 27.3 publishes promoted timings 3-7 already, and the
  parameter-15 fixed-rate route relies on mediaTargetRate.
- Shared code: the timing table (VRR attaches to timing 2 = 0x780001), iomfb_modeset_v27, dcp_set_adaptive_sync,
  the timestamp code.
- Identity EDID: dcp_panel_edid_snapshot() rounds the range up (120.00002 Hz -> 24-121); fix = DIV_ROUND_CLOSEST
  in dcp-display-metadata.c (as Aurora's cdd7efe4c52b did for get_modes); left to the 120 Hz owner.

Studio: ~/Work/agents/vrr/{patches,tools/{paramnum.py,paramswitch.py,syncheck.sh},out/setparameter-15.txt,
out/setparameter-switch-27.3.txt}.
