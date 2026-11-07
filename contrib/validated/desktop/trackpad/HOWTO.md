# J716s trackpad: macOS-like feel on Hyprland

Files (repo path → MacBook path):

| Repo | MacBook | What |
|---|---|---|
| `local-overrides.quirks` | `/etc/libinput/local-overrides.quirks` | libinput size/palm thresholds for this pad, with the measured ranges |
| `hypr/trackpad/curves.lua` | `~/.config/hypr/trackpad/curves.lua` | Apple's trackpad curves and the maths that turns them into libinput points |
| `hypr/trackpad/macos.lua` | `~/.config/hypr/trackpad/macos.lua` | preset: macOS curve, macOS click/tap/scroll behaviour |
| `hypr/trackpad/between.lua` | `~/.config/hypr/trackpad/between.lua` | preset: halfway between macOS and libinput |
| `hypr/trackpad/linux-default.lua` | `~/.config/hypr/trackpad/linux-default.lua` | preset: libinput default (what the machine did before) |
| `hypr/trackpad/select.lua` | `~/.config/hypr/trackpad/select.lua` | which preset is active |
| `hypr/trackpad/switch-preset.sh` | `~/.config/hypr/trackpad/switch-preset.sh` | switch presets and reload |
| `device-inventory.txt` | — | what the device and libinput report |

Kernel-side limits and draft patches: `contrib/pending/platform/trackpad-feel/`.

## Enable (once)

Add one line to `~/.config/hypr/hyprland.lua`, after the `hl.config({...})` block:

```lua
dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/select.lua")
```

Log out and back in (or reboot) once: libinput reads the quirks file only when it opens the
device, and `hyprctl reload` does not reopen it. After that, presets switch live.

`Hyprland --verify-config -c ~/.config/hypr/hyprland.lua` checks the config without starting
anything (all three presets pass it, with and without the line above).

## Switch presets

```sh
~/.config/hypr/trackpad/switch-preset.sh macos          # or between, linux-default
~/.config/hypr/trackpad/switch-preset.sh                # show the active one
```

It edits `select.lua` and runs `hyprctl reload`. Knobs (tracking speed, gain, scroll acceleration,
tap to click, three-finger drag) sit at the top of each preset file; edit, then `hyprctl reload`.
`lua ~/.config/hypr/trackpad/curves.lua 1.0` prints the curves for a given tracking speed.

## What the presets do

| | macos | between | linux-default |
|---|---|---|---|
| Pointer curve | Apple's, tracking 0.6875 (macOS default) | geometric mean of Apple's and libinput's | libinput adaptive, speed 0 |
| Scroll | libinput default speed at rest, Apple scroll-curve shape when flicking | half the Apple shape | libinput default |
| Natural scrolling, 2-finger scroll | on | on | on |
| Click | clickfinger (2 fingers = right, 3 = middle) | same | same |
| Tap to click / tap-and-drag | on / on | on / on | on / on |
| Drag lock | timeout (lift briefly during a drag, like macOS "Dragging") | timeout | off |
| Three-finger drag | off (knob) | off | off |
| Disable while typing | on | on | on |

Pointer speed, logical px per mm of finger travel (`lua curves.lua`):

| finger mm/s | 5 | 10 | 30 | 50 | 100 | 200 | 300 | 500 | 1000 |
|---|---|---|---|---|---|---|---|---|---|
| macos | 3.9 | 4.2 | 5.4 | 6.5 | 9.4 | 15.2 | 21.1 | 29.2 | 34.6 |
| between | 6.1 | 6.7 | 7.5 | 8.3 | 9.9 | 14.4 | 21.5 | 39.0 | 44.1 |
| linux-default | 9.4 | 10.5 | 10.5 | 10.5 | 10.5 | 13.7 | 22.0 | 52.1 | 56.1 |

So: macOS is 2.5x slower than libinput at slow, precise speeds, the two meet around 130 mm/s and
300 mm/s, and libinput races ahead on fast flicks (it saturates at 4.8x its base gain; Apple's
curve turns into a square root).

### Where the macOS curve comes from

- **Curve parameters:** Apple's own trackpad table, `HIDAccelCurves` in the "Trackpad HID Bridge
  - MT" personality of `AppleTopCaseHIDEventDriver.kext` (macOS 27). It holds one curve per
  Tracking speed setting (0, 0.125, 0.5, 0.6875, 0.875, 1, 1.5, 2, 2.5, 3). The same plist sets
  `HIDPointerReportRate` = 120. The default setting is 0.6875 (`HIDTrackpadAcceleration` = 45056
  on a stock install).
- **Curve formula:** IOHIDFamily `IOHIDAccelerationAlgorithm.cpp` (open source). It has three
  segments: a polynomial `gl*x + (gp*x)^2 + (gc*x)^3`, then its tangent line from
  `TangentSpeedLinear`, then a square root tangent to that line from `TangentSpeedParabolicRoot`.
  Settings between table rows blend linearly. `curves.lua` copies this exactly.
- **Units:** `IOHIDPointerAccelerator` feeds it the per-report delta (normalised to 120 Hz),
  divided by resolution/67, and scales the result by 96/67. So x = inches per 1/120 s × 67, and
  the flat index-0 curve is exactly 96 points per inch. macOS runs this panel at
  1728x1117 points and Hyprland runs it at 1728x1117 logical pixels (scale 2), so points and
  pixels compare 1:1.
- **libinput side:** for touchpads the custom profile works in raw device units
  (`tp_filter_motion` → `filter-custom.c`), not 1000 dpi units. Input is device units per ms
  (98 per mm on this pad, measured). Output is pixels per ms. The curve has 64 points (the
  libinput maximum) from 0 to 1000 mm/s, at a step of 1.556 units/ms, and is extrapolated beyond.
- **Assumption:** the multitouch stack hands IOHID deltas that match its declared resolution, and
  it reports at 120 Hz. If every speed feels off by the same factor, that is where the error is:
  change `GAIN`, not the curve.
- **Scroll:** with a custom profile and no scroll curve, libinput scrolls 1:1 in device units, which
  is 9.3x too fast. That is why every custom preset sets `scroll_points`. Their base slope is
  libinput's default scroll speed. Their shape comes from Apple's `HIDScrollAccelCurves` at the
  default scroll setting (0.3125). macOS scrolls through its gesture engine with momentum, so this
  copies the shape of Apple's curve, not macOS scrolling itself.
- `sensitivity` does nothing with the custom profile (libinput ignores speed there). Use
  `TRACKING` or `GAIN`.

### macOS behaviours and their libinput equivalents

- **Tap to click:** macOS ships with it off, and this config had it on. Tap timing is fixed
  inside libinput (no knob).
- **Dragging / drag lock:** `drag_lock = 1` (timeout) behaves like macOS "Dragging" without drag
  lock: you can lift and re-place a finger mid-drag. Use `2` for sticky drag lock (a tap ends it).
- **Three-finger drag:** `THREE_FINGER_DRAG = true` sets libinput's 3fg drag. libinput then
  reserves 3 fingers for dragging, so Hyprland's 3-finger workspace and scratchpad gestures in
  `hyprland.lua` stop firing. Move those `hl.gesture` lines to `fingers = 4`, which is what macOS
  does when three-finger drag is on.
- **Right click:** clickfinger with 2 fingers anywhere, as on macOS. Thumb detection keeps a
  resting thumb at the bottom edge out of the finger count.
- **Disable while typing:** libinput's DWT, on. Its timeouts are fixed at 200 ms after the first
  key and 500 ms while typing. libinput 1.32 has a timeout API (100-5000 ms), but Hyprland 0.57
  does not expose it.
- **Force click and haptics:** these come from the kernel, not libinput. The click starts when
  summed finger pressure reaches `haptic_press_threshold` (default 120, roughly grams) and ends
  below `haptic_release_threshold` (75). A deep click needs `haptic_deep_threshold` (500).
  Waveforms are set by `haptic_softness`/`haptic_strength`, and 0 keeps the MTP firmware values.
  All are writable at runtime under `/sys/module/hid_magicmouse/parameters/`; they are lost at
  reboot unless they go on the kernel command line (`hid_magicmouse.haptic_press_threshold=150`).
  Higher means a "firmer" click, like macOS Click: Firm. `haptic_deep_keycode` (command line only)
  sends a key on force click; nothing is sent by default.

## See what libinput decides

```sh
sudo libinput debug-events --verbose --device /dev/input/event1
```

At start it prints `using size-based touch detection (150:130)` and
`thumb: enabled thumb detection (area)`. Then, per touch:

- `palm: touch N (...), palm detected (touch size)`: the contact passed AttrPalmSizeThreshold
- `palm: touch N (...), palm detected (typing)`: disable-while-typing swallowed it
- `thumb: touch N, STATE → STATE` and `touch N is speed-based thumb`: thumb decisions (bottom 15 % of the pad)
- `touch-size: begin touch N` / `end touch N`: touch-size thresholds firing
- `GESTURE_*`, `POINTER_SCROLL_FINGER`, `POINTER_BUTTON`: what the compositor gets

This runs alongside Hyprland (libinput tools do not grab the device). Add `--enable-tap`,
`--set-profile=custom --set-custom-type=motion --set-custom-step=... --set-custom-points="a;b;..."`
and similar flags to try a setting in the tool's own output without touching the config.

## Measure the thresholds (do this once, it makes the quirks real)

```sh
sudo libinput measure touch-size --touch-thresholds=150:130 --palm-threshold=1600 /dev/input/event1
```

Touch with a light fingertip, a normal finger, a flat finger, a resting thumb (lower edge) and a
resting palm. Write down the major/minor of each. Then, in `/etc/libinput/local-overrides.quirks`:

- `AttrTouchSizeRange=hi:lo`: hi just under a light fingertip's major, lo about 20 below
- `AttrPalmSizeThreshold`: between the flat-finger maximum and the palm minimum
- `AttrThumbSizeThreshold`: between the moving-finger and resting-thumb majors. A thumb counts
  only if major > T and minor < 0.6 T, so check the thumb's minor too.

Run `libinput quirks validate`, then log out and back in. For the controller's own classes (thumb,
finger, palm) use `contrib/pending/platform/trackpad-feel/tp-contacts.py`. It prints the same
sizes, plus the class byte.

## Symptom → what to try

| Symptom | Try |
|---|---|
| Cursor too slow when moving slowly (macos) | `TRACKING` up one tick (0.875, then 1.0), or switch to `between` |
| Cursor too fast when moving slowly | `TRACKING` down (0.5, 0.125); in `linux-default`, `SENSITIVITY` below 0 |
| Fine at slow speed, too slow crossing the screen | `TRACKING` up (it mostly raises the fast end), or `between` |
| Everything off by the same factor | `GAIN` (0.8 / 1.2) |
| Palm moves the cursor while typing | watch debug-events: no `palm detected` line → measure, then lower `AttrPalmSizeThreshold`; `typing` palms only last 0.2-0.5 s after a key |
| Resting thumb breaks 2-finger right click or scrolling | measure, then set `AttrThumbSizeThreshold`; rest the thumb in the bottom 8 mm |
| Accidental taps while typing | DWT should catch it (debug-events shows `typing`); if the tap lands later than 0.5 s after a key, set `TAP_TO_CLICK = false` (macOS default) |
| Light touches not registering / dropping out | lower `AttrTouchSizeRange` (e.g. 120:100) |
| Hovering finger registers as a touch | raise `AttrTouchSizeRange` |
| Scroll too fast | `SCROLL_FACTOR` 0.6, or `SCROLL_ACCEL` 0.5 (flicks) |
| Scroll too slow / no momentum feel | `SCROLL_FACTOR` 1.5; kinetic scrolling is app-side (GTK, Firefox), not libinput |
| Workspace swipe needs a long stroke (macos curve) | swipes follow the motion curve; set `gestures = { workspace_swipe_distance = 200 }` in `hl.config` (default 300) |
| Click too hard / too light | `haptic_press_threshold` (see above) |

## Test checklist (at the machine)

1. Add the `dofile(...select.lua)` line, log out and in. `hyprctl devices` lists
   `apple-mtp-multi-touch`; `sudo libinput quirks list /dev/input/event1` shows `AttrSizeHint=157x96`.
2. **macos preset, pointer:** draw slow small circles around a 16 px icon, then sweep corner to
   corner in one flick. Expect precise slow motion and a full-width sweep in roughly half the pad
   width. Too slow or too fast → `TRACKING` up/down a tick; same error everywhere → `GAIN`.
3. Repeat step 2 on `between` and `linux-default` (`switch-preset.sh <name>`), and note which
   one you'd keep.
4. **Scroll:** slow two-finger scroll on a long page (content follows the fingers, natural
   direction), then a fast flick. Tune `SCROLL_FACTOR`, then `SCROLL_ACCEL`.
5. **Clicks:** a 1-finger click, a 2-finger click (menu), and a 3-finger click (middle paste). Rest
   the thumb at the bottom edge and do the 2-finger click with two other fingers: still a right
   click? Press hard for a force click (a second haptic bump).
6. **Taps:** 1/2/3-finger taps (left/right/middle). Double-tap-hold-drag a window, lift
   mid-drag and re-touch within about half a second: the drag continues.
7. **Typing:** type a paragraph with palms on the pad. With `libinput debug-events --verbose`
   running in another terminal, every palm contact should show `palm detected (typing)` or
   `(touch size)`, and the cursor must not move. Tap the pad right after typing: ignored for
   0.2-0.5 s.
8. **Thumb:** rest a thumb in the bottom 8 mm and move the pointer with the index finger. The
   pointer should follow the index finger only.
9. **Gestures:** 3-finger horizontal swipe (workspace), 3 up (scratchpad), 4 down (fullscreen) on
   the macos preset. If the workspace swipe needs too long a stroke, set
   `workspace_swipe_distance`.
10. **Measure** (section above). Paste the touch-size numbers and `tp-contacts.py` class
    summaries (finger, thumb, palm) into an issue or note, so the quirks values and the T6050
    palm-class patch can be finalised.
