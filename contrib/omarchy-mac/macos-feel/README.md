# macos-feel: the owner's macOS 27.3 input and size settings on Omarchy

The **macOS profile of the Pointer panel** (the owner's rolo.pointer plugin) plus a small desktop helper. Together
they map every macOS setting read from this MacBook (J716s, 2026-11-17) to Hyprland, libinput, GTK and the browsers,
using Apple's own acceleration tables and code (IOHIDFamily, open source) and the driver tables read from `ioreg` on
the same machine. The panel is the single source of pointer, scroll, wheel and cursor settings.

- Scope: `j716s` (owner's settings; the maths in `curves.lua` is generic). Status: installed 2026-11-17 (user `rolo`).
  Upstream: none/personal.
- Files:
  - `contrib/omarchy-mac/plugin-rolo-pointer/`: the panel. `apply-pointer.py` keeps two profiles in
    `~/.config/hypr/pointer-tuning.json` ("custom" = the hand-tuned values, "macos" = this mapping) and writes the active one
    to `~/.config/hypr/pointer-tuning.lua`.
  - `contrib/validated/desktop/trackpad/hypr/trackpad/curves.lua`: Apple's curves (trackpad, mouse table, wheel,
    display factor k), installed to `~/.config/hypr/trackpad/`.
  - `home/.local/bin/macos-feel`: text size and browser wheel animation (`desktop on|off`), `status`, `measure`.
  - `install.sh`: installs these for one user, with backups (`*.before-macos-profile`).

## Install, switch, undo

```sh
sudo contrib/omarchy-mac/macos-feel/install.sh --user rolo --macos      # install, panel on the macOS profile (one hyprctl reload)
sudo contrib/omarchy-mac/macos-feel/install.sh --user rolo --uninstall  # restore the files it replaced
```

Switch profiles in the bar's **Pointer** panel: Profile **macOS** / **Custom**. Each profile keeps its own values; the
sliders edit the active one, and "Reset to macOS values" / "Reset to defaults" restores it. From a terminal:
`python3 ~/.config/omarchy/plugins/rolo.pointer/apply-pointer.py --profile macos|custom`.
Changing profile applies live (`hyprctl eval` of `pointer-tuning.lua`) and runs `macos-feel desktop on|off` (text size,
browser flags; the previous values come back with "off"). Browsers and Electron apps pick up the flag change at their
next start.

The macOS profile's fixed values (not on the panel) are in the JSON under `macos_fixed`: trackpad scroll index 0.4412,
wheel 0.75, report rate 1000 Hz, `looks_like_width` 2246, `display_scale` 2 (must equal the panel scale in
`monitors.lua`), per-app scroll rules on, 4-finger gestures on. Mouse settings go per device to the G502 receiver's
two interfaces; other pointers (KM Link's virtual pointer) keep the custom profile's global mouse values.

History: the first version (commit d5735da) was a separate `macos-exact` trackpad preset that overrode the panel
through a hook in `hyprland.lua`. The owner wanted the panel to be the one place, so the preset and hook were removed
and their output moved into the panel; the generated Hyprland config is identical (checked with a recording `hl` stub:
same devices, curve points, gestures and window rules; only the cursor command differs, same final size 19).

## Mapping

Status: **exact** = Apple's algorithm and values reproduced; **approx** = right shape, an assumption sets the size;
**no** = cannot be done on this stack.

| macOS value | Linux setting | Status |
|---|---|---|
| Trackpad tracking `com.apple.trackpad.scaling` 0.875 (`HIDTrackpadAcceleration` 57344) | `apple-mtp-multi-touch` `accel_profile = custom` from Apple's trackpad `HIDAccelCurves` row 0.875, times k | exact (same curve, same units as the `macos` trackpad preset) |
| `HIDPointerAcceleration` 45056 (0.6875), `HIDScrollAcceleration` 20480 (0.3125) | not used: IOHIDPointerScrollFilter reads the per-type keys first (`HIDTrackpadAcceleration`, `HIDMouseAcceleration`, ...); these two are only the fallback | n/a |
| Trackpad scrolling speed `com.apple.trackpad.scrolling` 0.4412 (`HIDTrackpadScrollAcceleration` 28914) | `scroll_points`: Apple's `HIDScrollAccelCurves` row 0.4412, with IOHIDScrollAccelerator's own speed estimate (x 1.38 at 120 Hz) | shape exact; size approx (panel "Scroll speed (at rest)" 0.68 = owner's own tuning) |
| Natural scrolling `com.apple.swipescrolldirection` 1 | `natural_scroll = true` on the trackpad **and** the mouse (macOS uses one switch for both) | exact |
| Momentum `TrackpadMomentumScroll` 1 | kinetic scrolling is per toolkit: on in GTK3/4, Chromium/Electron, kitty; absent in Qt, alacritty, foot (see "Scrolling in every app") | approx / no |
| Tap to click `Clicking` 0, `Dragging` 0, `DragLock` 0 | `tap_to_click = false`, `tap_and_drag = false`, `drag_lock = 0` | exact |
| Secondary click `TrackpadRightClick` 1, corner click 0 | `clickfinger_behavior = true` (two fingers anywhere) | exact |
| Three-finger drag 0 | `drag_3fg = 0` | exact |
| Click pressure `FirstClickThreshold` 1 (medium), `ActuateDetents` 1, Force Click 1 | kernel `hid_magicmouse` `haptic_press_threshold` 120 / release 75 (defaults, medium) | approx: left unchanged (kernel side) |
| 3-finger horizontal swipe = switch Spaces (2) | profile: `hl.gesture` 3 fingers horizontal = workspace (already there) | exact |
| 4-finger horizontal swipe = switch Spaces (2) | panel (macOS profile) adds 4 fingers horizontal = workspace | exact |
| 4-finger pinch = Apps (2) | panel (macOS profile) adds 4-finger pinch in = `omarchy-shell omarchy.dock apps` | approx |
| 3-finger up = Mission Control | profile: 3 up = Mission Control (m5pro) / scratchpad (m5pro-dcp, in use); unchanged | owner's choice |
| Pinch to zoom, rotate | two-finger pinch reaches apps (Chromium, GTK4) through pointer-gestures | approx (app-side) |
| Smart zoom (two-finger double tap) | no Hyprland/libinput gesture for it | no |
| Mouse tracking `com.apple.mouse.scaling` 2.0 (`HIDMouseAcceleration` 131072) | `logitech-usb-receiver` `accel_profile = custom` from IOHIDFamily's built-in mouse table at 2.0, in counts per report, times k | exact |
| Mouse DPI 2450, 1000 Hz (G502 X PLUS onboard profile) | not touched (onboard). Neither macOS nor libinput's custom profile uses DPI (both work in counts), so the curve needs none | exact |
| Scroll wheel `com.apple.scrollwheel.scaling` 0.75 (`HIDMouseScrollAcceleration` 49152) | mouse `scroll_points` (libinput runs wheel v120 through the custom scroll curve): IOHIDFamily mouse table at 0.75, slow notch = 1 point delta | shape exact; size approx (Chrome-based, see below) |
| Display "looks like" 2246x1452 (BetterDisplay) on 3456x2234 | panel scale 2 (1728x1117), the owner's choice after trying 185/120 (macOS's exact size); pointer, scroll and text are sized physically through k = 0.769 (`macos_fixed.display_scale`) | matched physically |
| Text size `FontSizeCategory` L (the default category), system font 13 pt | GTK `text-scaling-factor` = 13 x k x 0.75 / 11 (Liberation Sans 11): 0.682 at scale 2 (7.5 pt), 0.886 at 185/120 | exact physical size for GTK (and apps reading GTK settings) |
| Cursor size `mouseDriverCursorSize` 1.26 | Adwaita size = round(17 pt x 1.26 x k / 0.85) = 19 at scale 2: the panel's cursor size in the macOS profile (`hyprctl setcursor` + gsettings `cursor-size`) | exact (arrow height) |
| Dark mode `AppleInterfaceStyle` Dark | already dark (`color-scheme prefer-dark`, Adwaita-dark) | exact |
| Dock autohide, tile size 28 | Omarchy's dock/bar is a separate shell; not mapped | no (note only) |
| `NSTableViewDefaultSizeMode` 2 | no equivalent | no |

k = Linux logical px per macOS point = (3456 / scale) / 2246 = 0.7694 at scale 2, 0.998 at 185/120.

## Derivations

**Trackpad pointer.** Unchanged maths from `curves.lua` (see `contrib/validated/desktop/trackpad/HOWTO.md`): Apple's
three-segment parametric curve, x = inches per 1/120 s x 67, output x 96/67 points; libinput's custom profile on a
touchpad works in device units (98/mm). The `ioreg` read today confirms the table (`HIDAccelCurves` on
AppleMultitouchTrackpadHIDEventDriver), `HIDPointerReportRate` 120 and resolution 400 dpi. New: the curve is
multiplied by k, because macOS moves the cursor in points of the 2246-wide mode (0.154 mm each), and Hyprland at scale 2
in 1728-wide logical px (0.200 mm each).

| finger mm/s | 5 | 10 | 20 | 50 | 100 | 200 | 300 | 500 | 1000 |
|---|---|---|---|---|---|---|---|---|---|
| macOS profile, px/mm | 3.05 | 3.37 | 4.01 | 5.94 | 9.17 | 15.7 | 22.3 | 31.3 | 36.7 |
| custom profile (tracking 1.0, gain 0.93) | 3.74 | 4.26 | 5.28 | 8.37 | 13.6 | 24.1 | 34.8 | 49.3 | 57.1 |

The previous hand tuning was 25-55 % faster on the glass than macOS. It had tracked macOS points, not millimetres.

**Mouse.** On macOS the receiver's mouse interface (`046d:c547`, AppleUserHIDEventDriver) has no `HIDAccelCurves` and
no `HIDPointerReportRate`. So IOHIDPointerScrollFilter uses IOHIDTableAcceleration with IOHIDFamily's built-in
`defaultAccelTable`, at acceleration 2.0 (above the table's last row 1.0, so y x (2+1)/(1+1)), resolution 400 dpi (the
default) and rate 67. With no report rate, speed = |delta| counts **per report**: the transfer is counts per report ->
points per report, and DPI never appears. libinput's custom profile for a mouse is also in raw counts per ms
(`filter-custom.c`, no DPI normalisation). At 1000 Hz, one report = 1 ms, so the curve is T(v) x k with v in counts/ms.
Piecewise: 0.305 pt/count up to 2.6 counts/report, then slopes 1.50, 3.67, 1.45, 0.54, 0.10, flat at 322 pt/report.
At 2450 dpi: 22.6 px/mm below about 25 mm/s, 87 px/mm at 100 mm/s, 182 px/mm at 500 mm/s
(`lua curves.lua mouse 2450 0.7694`). macOS floors |delta| before the table, which only matters above 2.6
counts/report. Not reproduced.

**Wheel.** Same table at 0.75 (interpolated between rows 0 and 1), resolution 9, rate 67, in IOHIDScrollAccelerator:
speed = (A t^2 - B t + C) x mean ticks x sqrt(event count), with t = mean ms between notches. The result is the CGEvent
point delta. Chromium's mac event builder documents a floor of 1 per notch, and Chrome on macOS scrolls deltaY x 40 =
4 CSS px per point delta. So a lone notch is 4 px, 8 notches/s is 44 px/notch, 10/s is 170, and a fast spin is ~680.
libinput 1.32 runs wheel events through the custom profile's scroll curve in v120 units (speed = 120 / ms since the
last notch). The base is 4 x k x scale / 120 = 0.051 Linux notches (Chrome on Linux: 120/scale px per notch).
libinput treats the first notch after a 1 s pause as 7 ms after the previous one, so the curve dips back to the slow
gain at 15.5-19 v120/ms. Otherwise every first notch would jump. macOS averages over up to 9 notches, while libinput
uses each interval, so uneven spins vary more than on macOS. Clients older than wl_pointer v8 (GTK3, alacritty) take
one whole step per notch and see no acceleration.

**Trackpad scroll.** Apple's `HIDScrollAccelCurves` row 0.4412 (between 0.125 and 0.5). IOHIDScrollAccelerator's
speed estimate is used: at 120 Hz it is 1.38 x the pointer's. The size at rest stays the owner's tuned 0.68 x
libinput's default (7.1 units/mm). macOS's absolute scroll size depends on the multitouch driver's scroll units, which
`ioreg` does not reveal (with 1/400" units it would be 2.6 px/mm). The side-by-side check sets it.

| finger mm/s | 5 | 20 | 50 | 100 | 200 | 300 | 500 |
|---|---|---|---|---|---|---|---|
| macOS profile, axis units/mm | 9.9 | 11.1 | 16.0 | 24.7 | 42.0 | 54.6 | 62.6 |
| custom profile (accel 0.38, factor 0.68) | 7.7 | 8.0 | 9.0 | 10.8 | 14.4 | 18.0 | 22.0 |

**Text.** macOS draws the 13 pt system font at 13 points. A GTK point is 96/72 logical px. Equal size on the glass when
linux_pt = 13 x k x 0.75. FontSizeCategory "L" is the default Dynamic Type category (Finder and Messages are "Custom",
so they are not mapped). Chrome page zoom is not set: web content at scale 2 is 1/k = 1.30x macOS. Set Chrome's default
zoom to 75 % by hand if wanted (at scale 185/120 it would match by itself).

**Cursor.** `NSCursor.arrow` measured on macOS 27: an image of 28x40 pt, with an opaque arrow 17 pt tall. Adwaita's
arrow is 0.85 of its nominal size (measured at 24-96).

## Scrolling in every app

Upstream source, per toolkit (wl axis unit = what Hyprland sends for a touchpad):

| App/toolkit | Touchpad px per axis unit | Momentum after lift | Wheel per notch | Wheel animation |
|---|---|---|---|---|
| Chromium/Chrome/Electron (Ozone Wayland) | 12 (physical) = 12/scale logical; `WaylandUnscaledTouchpadScrolling` off | yes (Chromium fling on `axis_stop`); no switch | value120 -> 120/scale px | yes by default; **off** via `--disable-smooth-scrolling` (set) |
| GTK4 | 2.5 (`MAGIC_SCROLL_FACTOR`) | yes (kinetic, per widget; no global switch) | value120/120 x pow(page, 2/3) | no |
| GTK3 (wl_pointer v5) | pow(page, 2/3)/10 (~10 at a 1000 px page) | yes | one discrete step = pow(page, 2/3) | no |
| Qt Widgets | angleDelta = axis x 12 -> ~6 px (singleStep 20) | no | 3 lines x singleStep | no |
| QtQuick (Quickshell shell) | 1 | no (only return to bounds) | 72 px, animated 300 ms | yes, no switch |
| alacritty 0.17 | 3 (`[scrolling] multiplier` 3) | no | 3 lines (axis_discrete) | no |
| kitty 0.50 | 1 x `touch_scroll_multiplier` | yes (`momentum_scroll 0.96`, default) | 5 lines (`wheel_scroll_multiplier`) | no |
| foot 1.28 | `multiplier`/scale (7.0 here) | no | 7 lines (may count the axis value too) | no |

What the macOS profile sets so the same gesture moves content the same distance:

- Reference is Chromium/Chrome/Electron (the default browser). It has no rule and device scroll factor 1.0.
- Hyprland window rules `scroll_touchpad` / `scroll_mouse` (they replace the device factor per window), each =
  reference / toolkit. At scale 2: GTK4 apps (`org.gnome.Nautilus|Papers|TextEditor|...`, Pinta) touchpad 2.4, wheel
  0.60. GTK3 (Evince, Disks) touchpad 0.60. Alacritty 2.0, kitty 6.0, foot touchpad 1.71, wheel 0.66. The
  Alacritty/kitty rules also cover TUIs launched from them (`org.omarchy.*`, `TUI.*` by initial title), as Omarchy's own
  rules do. These replace Omarchy's terminal rules (1.5 / 2.0), which were sized against its 0.4 default.
- Wheel animation off in Chrome, Chromium and Electron (`--disable-smooth-scrolling` in `~/.config/{chrome,chromium,electron}-flags.conf`;
  Chromium already had it). AppKit does not animate wheel notches either.
- Momentum: on wherever the toolkit has it. That covers everything the owner uses daily except alacritty (the default
  terminal), Qt apps and the shell's own lists. kitty is installed and has momentum on by default. Switching the
  default terminal to kitty would make terminals glide like macOS. That is the owner's choice and has not been changed.
- Not normalised: Qt Widgets apps (singleStep differs per widget), the Quickshell shell (layer surfaces take no window
  rules), LibreOffice (own scroll code), GTK3's page-dependent step (taken at a 1000 px page).

## Display: the "looks like" size

macOS reports the built-in panel at 2246x1452 points (`system_profiler`: `_spdisplays_resolution`
"2246 x 1452 @ 120.00Hz", pixels 4492x2904 scaled to 3456x2234), a BetterDisplay/"More Space" mode. The owner tried
the exact match (Hyprland scale 185/120 = 1.5417 -> 2242x1449, which needs `debug:disable_scale_checks` because
3456x2234 has no clean fractional scale) and kept scale 2 (1728x1117). So the macOS profile matches physical sizes
instead: k = (3456 / `display_scale`) / `looks_like_width` = 0.769 multiplies the pointer and scroll curves, and
`macos-feel` sets the text factor from the same k. If the panel scale in `monitors.lua` ever changes, set
`macos_fixed.display_scale` to the same value and switch the profile off and on (the cursor size, 19 at scale 2, is
round(17 x 1.26 x k / 0.85)).

## Side-by-side check (attended, about 15 minutes)

Do each step on macOS, then on Linux, with the same hand, the same table and the same mouse pad. Put a ruler next to
the trackpad.

1. **Trackpad, 10 cm slow stroke.** Start at the left edge of the pad and move one finger 10 cm in about 4 s.
   - Linux: run `macos-feel measure` and press Enter before and after the stroke.
   - macOS: run `swift -e 'import AppKit; print(NSEvent.mouseLocation)'` before and after (needs the Xcode command line tools). The difference is in
     points; x 0.154 = mm on the glass.
   - Same mm on the glass is the target. If every speed is off by the same ratio, set the panel's "Pointer gain (on top of macOS)" = macOS / Linux.
2. **Trackpad, fast flick.** Do the same with a 10 cm stroke in about 0.3 s. Check that the fast/slow ratio matches.
3. **Mouse, slow and fast.** Move the mouse 5 cm slowly, then 5 cm fast, and compare as in step 1. Set the panel's
   "Tracking speed (macOS)" a tick up or down if both are off by the same ratio.
4. **Scroll a page (trackpad).** Open the same long page (for example a Wikipedia article) at the top, in Chrome, with
   the same window height on both systems. Do one two-finger stroke of 3 cm, slowly, and lift without flicking. Note
   the heading you land on.
   - Linux: multiply the panel's "Scroll speed (at rest)" by (macOS distance / Linux distance).
   - Repeat in Files (Nautilus) and a terminal running `seq 1000 | less`. Each should move the same distance as
     Chrome. If not, adjust that row of `rules` in `apply-pointer.py`.
5. **Flick and coast.** Do one quick 3 cm flick and lift. Compare how far the page coasts and for how long (Chrome and
   Files glide; alacritty does not glide at all, kitty does).
6. **Wheel.**
   - 5 single notches about one second apart: on macOS each moves a few pixels.
   - A steady spin of about 10 notches/s for 2 s.
   - Then a fast spin.
   - Compare the distances in Chrome. If the slow notches differ, set the panel's "Scroll wheel size (x macOS)" to macOS / Linux.
7. **Text and cursor.** Hold a ruler to the glass. Measure the height of the same menu text (Chrome's tab title, a
   Files sidebar label) and of the arrow cursor on both systems.

Panel changes apply immediately.
