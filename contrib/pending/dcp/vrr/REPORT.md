# VRR on the J716s ProMotion panel (T6050, DCP firmware 27.3 beta 1)

## Status (2026-11-08)
Adaptive refresh works on hardware (payload dcpc-120d-ct0-vrr: kernel 22ec57f56b27 = the 120 Hz series + this directory's
two patches, `appledrm.fw27_panel_vrr=1 appledrm.fw27_counter_timestamps=0 appledrm.promotion_rates=1`). To merge, use
`patches/on-promotion-v2/` (branch `dcp/27.3-vrr-on-promotion-v2` = dcp/27.3-promotion-v2 c9c843f7082e + 83fc22a6cda9 +
b9af1331f42e; the counter-timestamp switch is dropped since v2 sends the constant presentation deadline; adaptive sync is
sent as `vrr_on ? mode->min_vrr : 0`); syntax-check and `checkpatch --strict` clean. `patches/` and `patches/on-promotion/`
are the earlier drafts.

## How it works
Adaptive sync is IOMFBParameter 15 (same in 27.0/27.2/27.3: 33 setParameter cases, 15 adaptive_sync, 31 external_sync),
sent through `set_parameter_dcp` (A500) as `{15, {minRR, mediaTargetRate, fractional}, count 3}` (16.16 Hz values; the
firmware zeroes the last two when the target is above 120 Hz or the flag above 1). `set_display_refresh_properties`
(A526) takes no input and publishes IOMFBDisplayRefresh (8.33-41.67 ms in 4.167 ms steps: 24-120 Hz in 240 Hz subframes).
Patch 0001 names parameter 15. Patch 0002 (opt-in `appledrm.fw27_panel_vrr=1`): the 120 Hz timing (ID 2) reports a zero
range, the opt-in makes it 24-120 Hz and the connector `vrr_capable`; timings 3-7 stay fixed and are real mode sets; a
VRR_ENABLED change in a plain page flip re-selects the current mode from that flip (parameter 15 with minRR 24 Hz or 0,
then `set_digital_out_mode`; no ALLOW_MODESET needed); the 1 s swap watchdog is armed while VRR is on and turns VRR off
for good if it fires.

## Hardware results (tools/vrrflip.c via tools/vrrflip-run.sh: atomic mode set, continuous flips in 8 s phases)
`vrr_capable` 1, `vrr_range` 24-120; mode set 3456x2234@120 OK; no flip_done or transaction timeouts with the constant
deadline. VRR_ENABLED 1: `VRR_ENABLED 1: selecting ... again`, firmware `IOMFBParameter_adaptive_sync Req minRR =
0x180000`, `set_digital_out_mode ... vrr:1`, re-select ~385 ms (panel dark meanwhile); VRR_ENABLED 0: the same with minRR 0.

| Phase | Flips | p50 (ms) | Meaning |
|---|---|---|---|
| fixed | 446 | 13.18 | 120 Hz frames plus slow client frames |
| vrr-on | 439 | 8.35 | 120 Hz at full content rate |
| vrr-on-50 (paced at 50 fps) | 400 | 20.83 | VRR follows the content: 5 subframes of 4.167 ms |
| vrr-off | 452 | 8.34 | fixed 120 Hz again |
| vrr-off-50 | 399 | 16.65 (p95 41.7) | fixed refresh quantizes 20 ms content to 16.7/25 ms |

The low averages and long p95 intervals are client-side: matching swap_submit to swap_complete by swap id, the DCP took
4.4-5.3 ms (p50) and never more than 10.7 ms to complete a swap; the gap from a completion to the next submit (vrrflip
repainting a 31 MB uncached dumb buffer) reached 83-139 ms. The single `swap failed! status 4294967295` at 106.77 s is the
surface-less swap the driver submitted after vrrflip's RMFB at exit (plane disabled, black background only): firmware
returned -1 or an empty reply, no crash flag, the next swap completed; a firmware-27 surface-less-swap issue for the
120 Hz / stage C side (any client exiting while its framebuffer is on screen).

## Next
Compositor: Hyprland `misc { vrr = 1 }` (switch once at session start; avoid 2/3, each fullscreen change would blank
~0.4 s); then idle power VRR on vs off. Optional: test a live minRR change (parameter 15 without the re-select).
