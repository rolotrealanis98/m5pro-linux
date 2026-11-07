# ProMotion 120 Hz test plan (J716s, T6050) - after DCP stage C, attended

Runs only once stage C passed (`endpoints started`, `[drm] Initialized apple`, no `DCP has crashed`). Every step is
attended: a DCP crash leaves the panel black until a cold reboot, so keep SSH from the Studio open throughout.
Stop at the first unexpected result and save `dmesg`, the outputs below and `/sys/kernel/debug/dri/1/eDP-2/*`.
Stop words, besides the stage C ones: `flip_done timed out`, `IOMFB transaction timed out` (the driver then sets
`crashed` silently: every later commit fails with -EINVAL and every brightness write is dropped).

Kernel: stage C kernel plus kernel/0001-0002 (branch dcp/27.3-promotion-v2). On the 2026-11-07 build
22ec57f56b27 (old 0001-0003 + VRR pair) `appledrm.fw27_counter_timestamps=0` sends the same swap timestamps as
the new 0001 (types 1, 2, 7 = 120).
Boot args: `trace_event=dcp:iomfb_swap_submit,dcp:iomfb_swap_complete,dcp:iomfb_vrr_timestamps,dcp:iomfb_timing_mode
drm.debug=0x16` (0x10 = ATOMIC: a refused commit names the failing check).
Tools: tools/dcp-dict.py, tools/promotion-frametime.sh, tools/kms-flip (static aarch64 build of tools/kms-flip.c),
`modetest`, `hyprctl`, `vkcube`.

## P0 - the first present completes
`dmesg | grep -E 'flip_done|IOMFB transaction|set_digital_out_mode finished'`; `grep -c iomfb_swap_complete
/sys/kernel/tracing/trace` > 0. Fail: stop; boot once with 0001 reverted (zero timestamps, about 60 fps) to tell a
timestamp rejection from a 27.3 swap layout problem.

## P1 - the firmware's timings (seen 2026-11-07)
`python3 dcp-dict.py /sys/kernel/debug/dri/1/eDP-2/TimingElements --timings`. Seen: ID 2 3456x2234 120.000 Hz
preferred (score 17026, totals 3536x2456), promoted IDs 3 60, 4 48, 5 59.94, 6 47.952 (same totals, pixel clock
scaled), 7 50.000 (totals 3536x2946); range fields 0/0 on all; DiscreteMediaRefreshRates empty.

## P2 - DRM mode list
`modetest -M apple -c`: eDP-2, 345x223 mm, six 3456x2234 modes 120.00 (preferred), 60.00, 59.94, 50.00, 48.00,
47.95, one per firmware timing; `vrr_capable` 0 (1 with `appledrm.fw27_panel_vrr=1`).

## P3 - mode set and flip cadence (no compositor)
Stop any compositor. Either
- `./kms-flip -d /dev/dri/card1 -c 49 -m 0 -t 8` (atomic; prints the real errno of a refused ioctl; `--test-only`
  checks the mode set only; `-m N` = mode index as in `modetest -c`), or
- `modetest -M apple -s 49@47:3456x2234-120.00 -v` (legacy; on failure it prints drmModeDirtyFB's ENOSYS, not the
  SETCRTC error: drm/apple framebuffers have no dirty hook).
Run `sudo sh promotion-frametime.sh 8` alongside. Pass: about 120 fps, p50 8.33 ms, every swap timestamped. Then
`-m 1` (60), `-m 2` (59.94), `-m 3` (50), `-m 4` (48), `-m 5` (47.95): each a set_digital_out_mode with timing ID
3..7; pass when the flip rate matches the mode within 0.5 %.

## P4 - backlight
`echo 150 > /sys/class/backlight/apple-panel-bl/brightness`, wait 1 s, `cat actual_brightness` (150 after the fade)
and a firmware `brightness_changed: brightness value: 9830400` journal line; then 450 (29491200). With the new 0002
a crashed processor fails both with -EIO instead of accepting them.

## P5 - Hyprland at 120
GPU (zink) session; rule `mode = "preferred"` (= 3456x2234@120) or `mode = "3456x2234@120"`. `hyprctl monitors`:
`3456x2234@120.00000 at 0x0`, `scale: 2.00`, `vrr: false`; frametime under `vkcube` about 120 fps; then
`mode = "3456x2234@60"`: `@60.00000`, about 60 fps.

## P6 - power, 60 vs 120 at idle
AC plugged, brightness fixed, radios unchanged, static desktop, 2 min settle per setting.
`P=$(grep -l 'Total System Power' /sys/class/hwmon/hwmon*/power*_label | head -1 | sed 's/_label/_input/')`, then
`for i in $(seq 60); do cat $P; sleep 1; done | awk '{s+=$1} END {print s/NR/1e6 " W"}'`. Three runs each,
alternating: 120, 60 (firmware timing 3), and 120 with `vrr = 1` plus `appledrm.fw27_panel_vrr=1` (VRR work).

## Rollback
Boot the stage C payload without these patches. A black panel: cold reboot (power hold 10 s); nothing persists.
