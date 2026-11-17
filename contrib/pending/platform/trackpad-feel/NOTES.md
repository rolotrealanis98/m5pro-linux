# J716s trackpad feel: what the kernel reports vs what libinput needs

Base: the running kernel, j716s-series a0f2f30c967b (`drivers/hid/hid-magicmouse.c`, MTP path).
Measured with `libinput record` and libinput 1.32.0 on the MacBook. Nothing built.
Userspace side: `contrib/validated/desktop/trackpad/`.

**Update 2026-11-17:** palm rejection is now `PALM-REJECTION.md` (the Asahi commit, the J716s recordings
and the `j716s-trackpad` branch, patches 0001-0003 here). The old drafts are replaced: the old 0001
(`mtp_palm_class`) is part of the new 0003, and the old 0002 (rounded resolution) is dropped because it
rescales `curves.lua`. The table below is the state before that branch.

| libinput uses | Driver reports | Verdict |
|---|---|---|
| ABS_MT_POSITION_X/Y with resolution (mm, accel normalisation, thumb lines, DWT travel) | -7456..7976 / -9283..163 at 98 u/mm from the firmware dimension report at open → 157.5 x 96.4 mm | OK. The resolution is truncated, so the size can be up to 1 % too big. Left alone: `curves.lua` depends on 98 |
| ABS_MT_TOUCH_MAJOR/MINOR for touch begin/end and palm size (raw units, quirks) | 0..5000, firmware contact size << 1, no resolution (libinput needs none) | Measured (PALM-REJECTION.md): fingers up to 776, palms mostly under 1450, so 1600 almost never fires; 150:130 ends about 4 % of real finger frames |
| ABS_MT_PRESSURE for touch detection, palm and thumb pressure | 0..6000 with resolution 1 and INPUT_PROP_PRESSUREPAD → libinput disables pressure on purpose (tp_init_pressurepad) | By design. Pressure drives the kernel click and haptics instead. No pressure quirk can work here |
| ABS_MT_TOOL_TYPE = MT_TOOL_PALM (firmware palm flag, checked first) | Not reported. `mtp_palms` is set only for `apple,t6041` | **The real gap.** Fixed on `j716s-trackpad` (0003): J716s palms are classed 6/7 before touch-down |
| Thumb: size or pressure, else position and speed | size possible via quirk (needs measurement); pressure off | Position/speed. Thumbs (class 1) and fingers overlap in size, so leave the size threshold unset |
| MSC_TIMESTAMP | Not reported | No impact. libinput uses it only to avoid false jump detection on pads that batch frames; regular jump detection applies |
| BTN_LEFT on a buttonpad | Derived from summed pressure (haptic_press_threshold 120 / release 75), actuator plays the click | OK |
| INPUT_PROP_BUTTONPAD, 16 slots, BTN_TOOL_*TAP up to 5 | yes | OK |

## Not a kernel problem

- The custom acceleration curve runs in device units for touchpads, so it depends on the 98 u/mm
  resolution (handled in `curves.lua`, `M.RES`).
- The disable-while-typing timeout is not configurable from Hyprland 0.57 (libinput has the API).
- Touch major/minor having no resolution is fine: libinput's size quirks are raw units by design.
