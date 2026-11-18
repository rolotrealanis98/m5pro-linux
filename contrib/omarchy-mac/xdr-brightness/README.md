# XDR brightness (and HDR) on the J716s panel

Status: **staged, untested.** Needs the `j716s-xdr` kernel (branch on the work volume, two commits on `j716s-next8`).

## What it does

macOS caps everyday brightness at 600 nits, the panel's SDR maximum. BetterDisplay's XDR mode takes the backlight
directly from 0 to 1600 nits, the panel's peak (macOS capture 2026-11-18: `AppleBuiltInDirectController - configured
nits min 0 max 1600`, `IOMFBBrightnessLevel` following the slider up to 1600). This item does the same on Linux:

- Kernel (`drm/apple: dcp: an XDR brightness range up to the panel's peak`): the internal panel's display processor
  gets `xdr_max_nits` (read/write), `xdr_peak_nits` and `sdr_max_nits` (read-only), found through
  `/sys/class/backlight/apple-panel-bl/device/`. Writing up to the peak widens the backlight device's range, the
  request check and the ceiling every frame carries; `0` narrows them back to 600. It starts off at every boot.
- `m5pro-xdr on|off|toggle|status`: switches the range and keeps the slider position, so the screen gets brighter at
  once (300 of 600 becomes 800 of 1600). Brightness keys and auto brightness then cover 0-1600. A lower XDR maximum
  can go in `~/.config/m5pro-xdr/nits`.
- Omarchy menu row **XDR brightness** (check mark while on).
- `m5pro-auto-brightness` follows a range change without treating it as a manual adjustment.
- udev rule: the `video` group may write `xdr_max_nits` (install adds the user to `video`).

HDR is separate: `appledrm.fw27_3_edr=1` (kernel commit 2, default off) sends the EDR headroom words on firmware
27.3, which this Mac runs. With it, an HDR output mode in Hyprland gets real headroom for HDR video. Without it the
swap is unchanged.

Safety: the firmware keeps its own limits (`RTPLCBLNitsCap`, which stayed at 1600 under BetterDisplay on macOS).
Linux does not run macOS's brightness service, so a test of full-screen white at 1600 nits is attended only.

## Install

```
sudo bash install.sh rolo            # files, udev rule, menu row; harmless on a kernel without the range
sudo bash install.sh --uninstall rolo
```

Also install the updated `auto-brightness` (`sudo bash ../auto-brightness/install.sh rolo`).

## Test plan (owner present)

1. Boot the `j716s-xdr` test file. `m5pro-xdr status`: SDR max 600, peak 1600, off.
2. `m5pro-xdr on 800`, then `on 1000`, `on 1300`, `on 1600`, with the slider at the top each time. Watch for
   flicker, a pulse, or the panel dimming itself. Check `dmesg` for swap errors.
3. Keys and auto brightness with XDR on; `m5pro-xdr off` returns to the same slider position at 600.
4. Sleep and wake with XDR on (it should stay on), and a reboot (it starts off).
5. HDR: `echo 1 | sudo tee /sys/module/appledrm/parameters/fw27_3_edr`, then in Hyprland (keys from the monitorv2
   wiki, check them against Hyprland 0.57.1 before use):
   `hl.monitor({ output = "eDP-2", mode = "preferred", position = "0x0", scale = 2, bitdepth = 10, cm = "hdr" })`.
   Play an HDR10 clip. Then try `sdrbrightness = 1.3` and `1.6`. Watch for swap errors and firmware crash logs.
