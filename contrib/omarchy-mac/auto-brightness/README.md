# Automatically adjust brightness

macOS-style auto brightness for the J716s: the panel (`apple-panel-bl`) and the keyboard light (`kbd_backlight`) follow the ambient
light sensor. Small user service, no wluma: wluma needs a Wayland screen-content capture and a tuned DCP/IIO setup; a lux curve plus
a learned multiplier does the job here.

## How it behaves

- **Sensor**: aop_als, `/sys/bus/iio/devices/iio:device1/in_illuminance_input` (lux; the calibration blob stays private). `aop_als` is
  loaded at boot by `/usr/lib/modules-load.d/m5pro-aop-als.conf` (it was not listed anywhere before).
- **Panel**: lux -> percent curve (log scale, conservative: ~54% at 60 lux, 100% above ~3000 lux, 22% in the dark).
  Smoothed (median of 3, then 5 s rise / 12 s fall time constants), 3-point deadband, ramps at 3 %/s. No flicker, no hunting.
- **Manual changes are learned, not fought**: a change that is not ours (brightness keys, slider) is detected from sysfs, waits until
  you stop pressing (2 s), then becomes a multiplier on the curve (`ratio` in `~/.local/state/m5pro-auto-brightness/state.json`).
  Brighter room later -> brighter than before, relative to what you chose.
- **Keyboard**: on (35 % or your last manual level) below 15 lux, off above 50 lux, 1.5 s fade. A manual keyboard change holds until
  the light crosses a threshold again; a non-zero manual level becomes the new "on" level.
- **Pause**: while the panel is off (DPMS) or the session is locked it neither writes nor learns; after wake/unlock and after suspend
  it waits 6 s (Omarchy restores the keyboard level itself), then resyncs.
- Writes go through `brightnessctl` (logind), so it only works as a user service in the logged-in session.

## Toggle, tune, undo

- Toggle: Omarchy menu > System > "Automatically adjust brightness" (check mark = on), or `m5pro-auto-brightness on|off|toggle|status`.
  On = `systemctl --user enable --now` (survives logins), off = `disable --now` (the panel stays where it is).
- "Reset learned brightness" in the same menu (or `m5pro-auto-brightness reset`) forgets your adjustments.
- Tune: `~/.config/m5pro-auto-brightness/config.toml`, then `systemctl --user restart m5pro-auto-brightness`. The
  main knob is `curve = [[lux, percent], ...]` (raise a number to make that light level brighter). Others: `deadband_pct`,
  `ramp_pct_per_s`, `tau_up_s`, `tau_down_s`, `learn`, `kbd_on_below_lux`, `kbd_off_above_lux`, `kbd_level_pct`. All defaults are at
  the top of `~/.local/bin/m5pro-auto-brightness`.
- Watch: `journalctl --user -u m5pro-auto-brightness -f`; `m5pro-auto-brightness status` (current lux, panel, target, ratio).
- Safe test without writing: `M5PRO_AB_NOPAUSE=1 m5pro-auto-brightness run --dry-run` (stop the service first or just run it alongside; dry-run only logs).
- Install: `sudo bash install.sh rolo`. Undo: `sudo bash install.sh --uninstall rolo`.

## Verified on the J716s (kernel 7.3.0-gcee93f953357)

Dry-run read lux 62.8 and chose 54 % without writing; pause detected the locked screen; a live 30 s run (via a transient user unit, 20 %/s
ramp) ramped the panel, lit the keyboard, detected a manual 300/600 change, learned ratio 0.93 and held a manual keyboard 0.

## Limits

- Uses the lux sensor only; no per-light-level learning (one multiplier), no color temperature (`in_colortemp_input` is exposed if you
  want a night-shift-like feature later).
- Hysteresis assumes sensor readings that are not artificially halved by the lid angle; if the lid is nearly closed the sensor may read low.
