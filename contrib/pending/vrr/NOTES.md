# VRR on the J716s panel (area `vrr`), 2026-11-15

Branch `vrr` (worktree `/Volumes/m5pro/wt/vrr`) on `j716s-next2`.

## Review of the 27.3 VRR path (code and captures, nothing measured yet)

- Adaptive sync is parameter 15 (`IOMFBPARAM_ADAPTIVE_SYNC_V27`) through `set_parameter_dcp` (A500 on 27.3, 0x28 bytes),
  value `{minRR 24<<16, 0, 0}`, count 3. Matches `findings/dcp/vrr/REPORT.md`. The 14 (desktop 26.6) is never sent.
- No capture shows what macOS sends: the only 27.3 DCP capture (`findings/boot/hv27/captures/DECODE-DCP-RPC-20261109.md`)
  is the AppleDCP boot with no WindowServer: no swap, no A463, no A500. The ADT/boot properties give only the refresh
  window (IOMFBDisplayRefresh 8.333 to 41.667 ms, step 4.166 ms) and six timings (120 Hz preferred, 60/48/59.94/47.952/50)
  with min/max VRR 0/0. So "what macOS sends" stays inference; an HV capture with WindowServer is the open item.
- Swap record: the 27.3 wire copies `swap.timestamp[7]` unchanged (`iomfb_v27.c`), so the presentation times set in
  `iomfb_flush()` reach the firmware: `[0]` and `[6]` = now, `[1]` = previous accepted swap's time, in the 24 MHz firmware
  timebase (`dcp_swap_time()` scales the 1 GHz counter). Set while `use_timestamps || vrr_enabled`. No further min/max
  field is known in the swap for VRR; the range comes from the mode select (parameter 15), as the firmware symbols say.
- Upstream: `aurora/djdev/t6050-paired-vrr` is already in the base (paired external VRR). `aurora/vrrneo/ext-vrr` adds
  H17P external policy (not this panel) and the VRR-maximum rounding. `67f52a4d2c01` (deadline at every internal
  timing) is for the 26.6 desktop only. PR #1816 and `dc8695e947d5` (A407, 27.0) do not touch the 27.3 swap
  timestamps; our 27.3 swap record (0x1144, D594 completion 0x730) is not contradicted by anything there.
- Found and fixed: the panel's 120 Hz timing is 120.00002 Hz (0x780001). The EDID range snapshot rounded it UP to 24-121
  (`dcp-display-metadata.c`), the connector range truncated. Both now round to the nearest Hz (commit 077961fd1d4e).
- Fixed 120 Hz internal already sends the deadline stamps (`needs_timestamps`), so the DCP presents at 240 Hz subframe
  granularity with VRR off too: the 2026-11-12 flip cadence (20.83 ms at 50 fps both ways) fits that. A 48 fps client
  (20.83 ms = 5 subframes, not a multiple of 8.33 ms) and 90 fps (11.11 ms, between 8.33 and 16.67) are the discriminating
  rates; 60 fps (16.67) is the control. Whether VRR-off really quantises to the 8.33 ms grid is part of the measurement.

## vrr-1 result (2026-11-15) and the reading

Swaps complete 3.3-4.3 ms after submit on a 4.167 ms lattice at every rate, VRR on and off alike; the firmware logs
VRR=YES/NO. So the swap cadence cannot show VRR; `minRR` is the refresh floor. Decided: default on (commit 9f50374b97d5),
`appledrm.fw27_panel_vrr=0` is the off switch; vrr-2 looks at static power, event rates and rates below 24 Hz.

## vrr-2 result (2026-11-16, kernel 9f50374b97d5, default on, compositor stopped)

- **Cadence: VRR on = VRR off, at every rate.** 45/41/30/24/20/15/90/50 fps: mean interval within 0.1 ms of the target,
  100 % of intervals on the 4.17 ms lattice, 0 stalls, swap latency 3.2-4.4 ms (7.5 ms at 20 fps in both modes). 45 and
  41 fps (not divisors of 120) are paced exactly by mixing 5- and 6-subframe intervals, so a game below 120 fps judders by at
  most one 4.17 ms subframe, VRR or not. 90 fps: min 8.4 ms (one 2-subframe catch-up), p50 12.4.
- **Static screen: no difference.** ~80 DCP events/s both ways (`iomfb_callback` ~79/s with matching send/recv: the
  firmware's own chatter, not swaps; 2-4 swaps per phase). Nothing shows the panel dropping its refresh when idle.
- **Static power: not measured.** The script's battery reads returned -1 (its sysfs path, not the gauge: `power_now`
  worked in low-power-4). Use `contrib/pending/low-power/lp-s2idle-power.sh`'s reader for the next pass.
- Health: no swap timeouts or DCP errors.
- **Reading:** on firmware 27.3 the internal panel already presents on a 240 Hz subframe grid with the deadline stamps,
  so "VRR working properly" is true in the sense that matters for motion (any frame time to 4.17 ms). What VRR on does
  not show is a lower self-refresh rate at idle; that would need the power reader, or an HV capture of macOS's mode select
  (parameter 15 minRR) to compare against.

## Default-on (old text, superseded)

The evidence is one cadence measurement of a different kernel, and no swap-complete data on this one. The parameter stays
default off (`appledrm.fw27_panel_vrr=1` on the cmdline). Flip the default only if `vrr-1` passes in the request and the
compositor path (Hyprland `misc:vrr`) behaves; then the parameter becomes the off switch.

## Tracing

`j716s.config`: `CONFIG_FTRACE=y`, `CONFIG_SCHED_TRACER=y` (the cheapest tracer that selects TRACING: tracefs, trace_marker,
event tracing). The dcp events (`iomfb_swap_submit`, `iomfb_swap_complete`, `iomfb_vrr_timestamps`) are in
`drivers/gpu/drm/apple/trace.h`, system `dcp`.

## Tools

`vrrcadence.c` (derived from `m5pro-linux-re/tooling/vrr/vrrflip.c`: arbitrary `vrr:fps` phases, absolute-clock pacing),
`vrrcadence-run.sh`, `vrrcadence-analyze.py`. Copies in `/Volumes/m5pro/bench/vrr/`.
