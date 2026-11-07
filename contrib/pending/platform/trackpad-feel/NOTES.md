# J716s trackpad feel: what the kernel reports vs what libinput needs

Base: the running kernel, j716s-series a0f2f30c967b (`drivers/hid/hid-magicmouse.c`, MTP path).
Measured with `libinput record` and libinput 1.32.0 on the MacBook. Nothing built.
Userspace side: `contrib/validated/desktop/trackpad/`.

| libinput uses | Driver reports | Verdict |
|---|---|---|
| ABS_MT_POSITION_X/Y with resolution (mm, accel normalisation, thumb lines, DWT travel) | -7456..7976 / -9283..163 at 98 u/mm from the firmware dimension report at open → 157.5 x 96.4 mm | OK. The resolution is truncated, so the size can be up to 1 % too big → 0002 (cosmetic) |
| ABS_MT_TOUCH_MAJOR/MINOR for touch begin/end and palm size (raw units, quirks) | 0..5000, firmware contact size << 1, no resolution (libinput needs none) | OK. Thresholds 150:130 / 1600 are inherited from the M1/M2 MTP pads (same driver and scaling); measure on J716s |
| ABS_MT_PRESSURE for touch detection, palm and thumb pressure | 0..6000 with resolution 1 and INPUT_PROP_PRESSUREPAD → libinput disables pressure on purpose (tp_init_pressurepad) | By design. Pressure drives the kernel click and haptics instead. No pressure quirk can work here |
| ABS_MT_TOOL_TYPE = MT_TOOL_PALM (firmware palm flag, checked first) | Not reported. `mtp_palms` is set only for `apple,t6041` | **The real gap.** With edge palm zones off for Apple pads and pressure off, contact size and DWT are the only palm signals → 0001 |
| Thumb: size or pressure, else position and speed | size possible via quirk (needs measurement); pressure off | Position/speed works now; size thumb needs measurement, or the class byte (0001) |
| MSC_TIMESTAMP | Not reported | No impact. libinput uses it only to avoid false jump detection on pads that batch frames; regular jump detection applies |
| BTN_LEFT on a buttonpad | Derived from summed pressure (haptic_press_threshold 120 / release 75), actuator plays the click | OK |
| INPUT_PROP_BUTTONPAD, 16 slots, BTN_TOOL_*TAP up to 5 | yes | OK |

## 0001: MTP palm class on any SoC (module parameter)

The standard MTP finger record has the controller's contact class in the low byte of word 1
(recorded on a T6041 J616C: 1 thumb, 2-3 finger, 6+ palm). The driver already turns it into
MT_TOOL_PALM on T6041, with hysteresis (a contact stays a palm until it lifts) and a tool-area
floor, so a flickering class cannot hide a finger. J716s uses the same standard record layout
(not the J700 C1FE one) and MTP firmware 6320.86.1. Whether its class byte means the same thing
is unverified, so the patch does not enable it on T6050. Instead it adds
`hid_magicmouse.mtp_palm_class`: -1 keeps today's behaviour (T6041 only), 0 disables it, 1 forces
it on. One kernel built with 0001 can then test J716s from the command line, without another
rebuild. When the class byte checks out, a one-line follow-up adds `of_machine_is_compatible(
"apple,t6050")` to the -1 case.

Check before enabling: run `sudo python3 -I tp-contacts.py` and touch with a moving finger, a
resting thumb and a resting palm. Then compare the `cls` column with 2-3 / 1 / 6+. The script
reads hidraw and runs on the current kernel.

## 0002: rounded resolution

`x_res = 100 * x_span / width` truncates; DIV_ROUND_CLOSEST halves the worst-case error
(1 % → 0.5 %). Cosmetic. It moves libinput's mm-based thresholds by at most 0.5 %.

## Not a kernel problem

- The custom acceleration curve runs in device units for touchpads, so it depends on the 98 u/mm
  resolution (handled in `curves.lua`, `M.RES`).
- The disable-while-typing timeout is not configurable from Hyprland 0.57 (libinput has the API).
- Touch major/minor having no resolution is fine: libinput's size quirks are raw units by design.

Apply check: both patches `git apply` cleanly in sequence onto
`a0f2f30c967b:drivers/hid/hid-magicmouse.c`, and 0001 passes `git apply --check` in
`/Volumes/linux-cs/wt-series`.
