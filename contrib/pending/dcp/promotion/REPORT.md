# ProMotion 120 Hz on the J716s panel through the DCP driver (2026-11-07) — unverified until stage C

Kernel branch `dcp/27.3-promotion` (3 commits on dcp/27.3 716bce007fd3; sparse worktree /Volumes/linux-cs/wt-promotion:
dd9405339692, 9ccc42a52b5b, 7d421ee81108). W=1 warning-free; drm/apple unit tests under qemu arm64 265/266 (one
unrelated skip). Here: `kernel/0001-0003`, `dt/0001` (notch-height for mk-fixed9.py, not applied), `tools/dcp-dict.py`,
`tools/promotion-frametime.sh`, `TEST-PLAN.md`.

## How modes arrive on firmware 27.x
- No get_timing_modes call: the firmware pushes TimingElements / ColorElements / DisplayAttributes dictionaries
  (callbacks D126-D128) after start and set_display_device (A461). `dcp_modes_replace()` -> `enumerate_modes(internal)`
  keeps the firmware ranking (IsPreferred, then Score). Notch rows are cut only with `apple,notch-height` set and
  no show-notch. Mode set = set_digital_out_mode (A463); adaptive sync = set_parameter_dcp (A500) parameter 15
  {min rate, media target rate, fractional flag}.
- No panel-id gate on T6050 (the J715 commit is in the T8132 path; the 14.7 path uses a board flag; 27.x takes the
  list as is). Identity EDID (e0b062cdc9c4): no /panel node, so make APP, model "Apple Panel", serial hashed from
  /product; modes do not depend on it.
- ADT has no rate list, panel-id or boot-display data (disp0 display-timing-info is a 1024x600 pipe default;
  subframe-duration-nclks 100058, subframe-interrupt-time-lines 1066, display-lead-time-nclks 19167, dot-pitch
  254.6; /product partially-occluded-display 1, artwork-device-subtype 2234; display-scale 2; TCON Parade DP855).
- 27.3 firmware strings: per-timing Minimum/MaximumVariableRefreshRate, DiscreteMediaRefreshRates, IsPromoted;
  DisplayAttributes SupportsVariableRefreshRate / SupportsDiscreteMediaRefreshRate; iomfb_fixed_120hz,
  iomfb_RuntimeProperty_limitRefreshRate. Inferred (not observed): one timing 3456x2234 @ 120 Hz with zero range
  fields; fixed rates as media rates on it (the VRR analysis found separate promoted timings 3-7 in the firmware
  tables; P1 decides).
- Payload sizes on 27.3: A463 0x8/0x4, A461 0x4/0x4, A500 0x28/0x4, A526 -/0x4 unchanged; only A457/A458 changed.
- Expected `modetest -M appledrm -c` with show-notch=1: eDP-1 connected 345x223 mm, one mode 3456x2234 120.00
  preferred; vrr_capable 0 with zero range fields; with `appledrm.promotion_rates=1` six more modes (100, 60,
  59.94, 50, 48, 47.95); with the notch trimmed 3456x2160. iBoot lights the native timing, so no visible switch.
- Prior art: J314/J316 one 120 Hz timing, swaps must carry timestamps or the panel shows 60 fps; J514/J516 board
  promotion flag + timestamps; J614/J616 (desktop 26.x) takeover trial, fixed 120 keeps timestamps, VRR = param 14.

## Patches
- 0001 (real bug): outside desktop 26.x the mode set sent swap timestamps only when the timing had a VRR range; a
  120 Hz timing with zero range fields showed 60 fps. Now `needs_timestamps` (as 9df36a2c42b6 did for desktop).
- 0002: 120 Hz timing becomes preferred when the firmware ranks a slower native-size timing first (no-op with one).
- 0003 (opt-in `appledrm.promotion_rates=1`): 100/60/59.94/50/48/47.95 as modes of the 120 Hz timing (longer
  vertical front porch); mode set sends parameter 15 with min = target = rate (+ fractional flag); refusals logged.
- Unit tests parser_promotion_default, parser_promotion_fixed_modes. DT: `apple,notch-height = <74>`,
  `adj-height-mm = <216>` (no effect while show-notch=1).

## Hyprland
Omarchy's `hl.monitor({ output = "eDP-1", mode = "preferred", scale = 2 })` already yields 3456x2234@120 once
appledrm owns the panel (explicit: `mode = "3456x2234@120"`). Expected `hyprctl monitors`: 3456x2234@120.00000,
scale 2 (1728x1117 logical), vrr false, make APP / model Apple Panel. 120 fps needs the GPU (zink) session.

## Test plan after stage C (attended; TEST-PLAN.md)
P1 firmware readout (`trace_event=dcp:iomfb_timing_mode`, dcp-dict.py on debugfs eDP-1/TimingElements);
P2 `modetest -c`; P3 mode set at 120 with promotion-frametime.sh (pass ~120 fps, median 8.33 ms, every swap
timestamped), then each fixed rate with the parameter on; P4 Hyprland at 120 + vkcube; P5 idle power PSTR at
120 vs 60 vs VRR, 3 runs each.

## VRR coordination
The VRR patches (contrib/pending/dcp/vrr) apply cleanly on this final series; their on-promotion branch should rebase
onto 7d421ee81108. Shared: parse_mode() range/timestamp fields (fixed_rate added; fixed-rate modes are not VRR
modes), the generic mode set in iomfb_template.c (timestamp line + adaptive-sync branch with media_rate), refusal
handling of parameter 15, the VRR_ENABLED re-select ignoring fixed-rate modes, vrr_capable gating, swap timestamps
in iomfb_flush, Hyprland vrr vs fixed @rate exclusive. 0001/0002 do not depend on the VRR work.

Risks: mode list inferred until P1; 0003's rates unproven (P3); the 27.3 method table and swap layout have never
run (stage C is their first test). Removable: /Volumes/linux-cs/wt-promotion-build (worktree), wt-promotion-out,
wt-promotion-kunit.
