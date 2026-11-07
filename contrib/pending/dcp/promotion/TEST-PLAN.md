# ProMotion 120 Hz test plan (J716s, T6050) - after DCP stage C, attended

Runs only once stage C passed (`endpoints started`, `[drm] Initialized appledrm`, no `DCP has crashed`, the panel
survived a modeset and a brightness change; see ../TEST-PLAN.md and ~/Work/agents/dcp-bwscratch/REPORT.md). Every step
is attended: a DCP crash leaves the panel black until a cold reboot, so keep SSH from the Studio open throughout.
Stop at the first unexpected result and save `dmesg`, the outputs below and `/sys/kernel/debug/dri/*/eDP-1/*`.

Kernel: stage C kernel plus kernel/0001-0003 (dcp/27.3-promotion). 0001 and 0002 change nothing visible when the
firmware reports one 120 Hz timing with no range keys; 0003 does nothing unless `appledrm.promotion_rates=1`.
DT: stage C DTB; with dt/0001 applied only if the notch is to be trimmed (without `chosen.asahi,show-notch=1`).
Boot args to add: `trace_event=dcp:iomfb_timing_mode drm.debug=0x04` (keep the stage C ones).
Tools: tools/dcp-dict.py, tools/promotion-frametime.sh (copy to the target); `modetest` (libdrm-tests),
`hyprctl`, `vkcube` (vulkan-tools) for the GPU session.

## P1 - what the firmware lists (one boot, read-only)
- `dmesg | grep -iE 'notch|panel identity|timing|set_digital_out_mode'`
- `grep iomfb_timing_mode /sys/kernel/tracing/trace`
- `python3 dcp-dict.py /sys/kernel/debug/dri/*/eDP-1/TimingElements --timings` (and without `--timings` for the
  full dictionary; also `DisplayAttributes`: look for SupportsVariableRefreshRate, MinimumRefreshRate,
  MaximumRefreshRate, SupportsDiscreteMediaRefreshRate).

Expected: one timing, 3456x2234, vertical PreciseSyncRate 120.000 (or 119.880), IsPreferred, ID and Score whatever
the firmware says; MinimumVariableRefreshRate/MaximumVariableRefreshRate present and both 0 (the VRR work's reading of
the 27.x firmware; the driver keeps the timing fixed on 27.x, `vrr_capable` 0 unless `appledrm.fw27_panel_vrr=1`),
absent (the driver assumes 24-120 Hz) or a real range; possibly DiscreteMediaRefreshRates. Record all of it in
RESULTS. Decision points:
- range keys present and both 0: the timing is fixed 120 Hz; 0001 is what keeps it presenting at 120 fps.
- a second timing of the native size at 60 Hz ranked first: 0002 is what makes 120 Hz the preferred mode.
- `panel identity fallback: ADT parsed|unavailable, panel node absent, dimensions 345x223 mm` (no /panel node in
  the J716s ADT; make "APP", model "Apple Panel").

## P2 - DRM mode list
- `modetest -M appledrm -c` and `cat /sys/class/drm/card*-eDP-1/modes`.

Expected (show-notch=1, the current payloads): connector `eDP-1`, connected, 345x223 mm, one mode
`3456x2234 120.00 ... type: preferred, driver`, property `vrr_capable` = 0 with zero range fields (1 with a real or
absent range, or with the VRR work's `fw27_panel_vrr=1`). With `appledrm.promotion_rates=1` (next boot): six more
`3456x2234` modes, 100.00, 60.00, 59.94, 50.00, 48.00, 47.95, `type: driver`, same clock and htotal, larger vtotal
(fewer if a reported range starts above 47.95). With the notch trimmed (dt/0001,
no show-notch): `3456x2160`, 345x216 mm.

## P3 - KMS mode set and frame cadence (no compositor)
Stop the Hyprland session (switch to a VT or `loginctl terminate-session`), then, with two SSH shells:
1. `modetest -M appledrm -s <connector>@<crtc>:3456x2234-120.00 -v` (prints `freq:` about every 5 s)
2. `sudo sh promotion-frametime.sh 10`

Pass: `freq:` about 120 Hz; frametime reports about 120 fps, p50 about 8.33 ms, nearly all intervals under 9.5 ms,
and as many timestamped swaps as completions. 60 fps with p50 16.7 ms means the swaps lost their timestamps (0001
not in the kernel, or `needs_timestamps` false): stop and report.
With `appledrm.promotion_rates=1`: repeat with `-60.00`, `-50.00`, `-48.00`, `-59.94`, `-47.95`, `-100.00`.
Record per rate: fps, p50, `adaptive sync parameter refused` lines. Pass: fps within 0.5 % of the rate. A rate that
runs at 120 fps (the panel follows the frames instead of holding the rate) means the media target rate does not
pin the cadence: keep `promotion_rates` off and hand the numbers to the VRR work (param 15 semantics).

## P4 - Hyprland at 120
Start the GPU (zink) Hyprland session; the monitor rule is `mode = "preferred"` today, which is the 120 Hz mode, or
explicitly `hl.monitor({ output = "eDP-1", mode = "3456x2234@120", position = "0x0", scale = 2 })`.
- `hyprctl monitors`: `3456x2234@120.00000 at 0x0`, `scale: 2.00`, `vrr: false`, make/model from the identity EDID.
- `sudo sh promotion-frametime.sh 10` while `vkcube` runs (or a window is dragged): about 120 fps.
- Hyprland overlay (`hyprctl keyword debug:overlay true`) shows about 120 FPS under load.
- With `promotion_rates=1`: `mode = "3456x2234@60"`, reload, `hyprctl monitors` shows `@60.00000`, frametime about
  60 fps. Then back to 120.
llvmpipe cannot render 3456x2234 at 120 fps; a software session measures the renderer, not the panel.

## P5 - power, 60 vs 120 at idle
AC plugged (PSTR is valid on AC; battery discharge readings need the brick out), brightness fixed (note the level),
Wi-Fi and Bluetooth state unchanged, static desktop, no cursor movement, 2 min settle per setting.
`P=$(grep -l 'Total System Power' /sys/class/hwmon/hwmon*/power*_label | head -1 | sed 's/_label/_input/')`, then
average 60 samples one second apart (microwatts): `for i in $(seq 60); do cat $P; sleep 1; done | awk '{s+=$1} END {print s/NR/1e6 " W"}'`.
Settings, three runs each, alternating: 120 (preferred mode), 60 (`promotion_rates=1`), and 120 with `vrr = 1`
in the Hyprland rule plus `appledrm.fw27_panel_vrr=1` from the VRR work (contrib/pending/dcp/vrr; the panel may
fall to 24 Hz at idle).
Report mean and spread per setting; the 60-vs-120 delta is the deliverable, the VRR row is for the VRR work.

## Rollback
Remove `appledrm.promotion_rates=1` from the boot args, or boot the stage C payload without 0001-0003. A DCP crash
or a black panel: cold reboot (power hold 10 s); nothing here persists.
