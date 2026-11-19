# Mission Control rebuilt: live window previews, finger-following swipe, drag and drop (2026-11-19)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/37     Kernel: 7.3.0-gc1e08542a544

## What broke
Not a bug: the 2026-11-08 overview (`rolo.mission-control`, an Omarchy shell plugin) was not good enough. It showed app
icons instead of window pictures, the three-finger swipe only toggled it (no following the fingers), and windows could not
be dragged between workspaces or closed. Rolando asked for the macOS behaviour: a swipe that tracks the fingers at every
point, live previews in the workspace strip and on the stage, drag and drop between workspaces, closing windows, adding and
closing workspaces, and the three-finger sideways swipe working inside the overview.

## Cause
Why the old plugin could not be grown into this, from what the machine shows:

- The Omarchy shell runs on Qt's software renderer (`QT_QUICK_BACKEND=software`, the stopgap for tracker #36). An
  offscreen benchmark of an overview-like scene at panel resolution gave 7 to 8 ms of CPU raster per frame before the
  buffer copy and the compositor upload, so the plugin could not hold 120 Hz, and its window pictures would have been CPU
  copies.
- Hyprland's Lua gestures run a function once per swipe. There is no begin/update/end hook (`/usr/share/hypr/stubs/hl.meta.lua`
  has no gesture event), so a config gesture cannot follow the fingers.

## Fix
A separate Quickshell instance, GPU rendered, with its own trackpad reader. Rolando chose the GPU renderer in chat
("we need to use the GPU rendering mode").

1. `~/.config/quickshell/mission-control/` (new): `shell.qml`, `WindowTile.qml`, `SpaceThumb.qml`, `Layout.js`,
   `mc-gestures.c` and its binary, `mission-control.service`.
   - The overlay is a layer surface (namespace `mission-control`, overlay layer, below the bar's reserved strip) that is
     mapped only while the overview is in use. Its first frame is the desktop itself: the wallpaper where the desktop
     draws it, and each window as a live `ScreencopyView` (toplevel export, dmabuf) at the window's real box, with
     Hyprland's border and rounding. One `progress` value (0 desktop, 1 overview) moves every window to its place in the
     spread and slides the workspace strip in.
   - The spread keeps the desktop's arrangement: the workspace is zoomed out to fit the stage, after overlapping windows
     are pushed apart (`Layout.js`).
   - `mc-gestures` (C, libinput + libudev) opens touchpads only (`ID_INPUT_TOUCHPAD`), read-only and without a grab, and
     prints hold/swipe begin, update and end lines. The overlay maps and captures when three fingers rest on the pad,
     follows the unaccelerated vertical travel 1:1, and on release continues with a critically damped spring that takes
     the fingers' velocity. Sideways swipes inside the overview move the stage 1:1; Hyprland's own workspace swipe does
     the real switch underneath and the stage settles on Hyprland's answer.
   - Actions go through `hyprctl dispatch`: `hl.dsp.focus`, `hl.dsp.window.move({ workspace, follow = false, window })`,
     `hl.dsp.window.close`, `o.workspaces.focus(slot, monitor)`.
   - If the Pointer panel's "Three-finger drag" is on (`~/.config/hypr/pointer-tuning.json`), the overlay ignores swipes.
2. `systemctl --user enable --now mission-control.service` (unit symlinked into `~/.config/systemd/user/`). The unit sets
   `QT_QUICK_BACKEND=rhi` and `QSG_RHI_BACKEND=opengl` for this process only; the session files and the shell's renderer
   were not touched.
3. `~/.config/hypr/bindings.lua`: Ctrl+Up and Ctrl+= now dispatch the global shortcut `mission-control:toggle`; the
   three-finger-down "hide" gesture line is gone (the overlay reads the trackpad itself).
4. `~/.config/hypr/looknfeel.lua`: a `no_anim` layer rule for the `mission-control` namespace.
5. `omarchy plugin disable rolo.mission-control` (the old plugin stays installed, disabled).
6. `hyprctl reload`; `hyprctl configerrors` is empty.

7. Follow-up the same day, after Rolando tried it ("the feel is great") and said yes to the protected files:
   `~/.config/hypr/m5pro-dcp.lua` and `m5pro.lua` lost the old three-finger-up line (it ran
   `omarchy-shell shell toggle rolo.mission-control`, a no-op since step 5) and its comment now points at the overlay. Only
   that line and the comment changed.
8. Same follow-up: the bar stayed bright above the dark workspace strip (the bar's background is `none`, so the wallpaper
   showed through it). The overlay now maps a second surface, namespace `mission-control-bar`, on the bottom layer under the
   bar's reserved strip, click-through, which darkens with the strip. The layer rule covers both namespaces.

## Files changed
New files, copies under `files/2026-11-19-mission-control-live/` (install to `~/.config/quickshell/mission-control/`, then
`cc -O2 -o mc-gestures mc-gestures.c $(pkg-config --cflags --libs libinput libudev)`).

`~/.config/hypr/bindings.lua` (backup `bindings.lua.pre-mission-control-live`):
```diff
@@ -26,20 +26,18 @@
--- Mission Control (macOS-style overview), shell plugin rolo.mission-control in
--- ~/.config/omarchy/plugins/. Ctrl + Up (and Ctrl + =) toggle it.
-o.bind("CTRL + UP", "Mission Control", { panel = "rolo.mission-control" })
-o.bind("CTRL + EQUAL", "Mission Control", { panel = "rolo.mission-control" })
+-- Mission Control (macOS-style overview): its own Quickshell instance in
+-- ~/.config/quickshell/mission-control/ (mission-control.service). Ctrl + Up
+-- (and Ctrl + =) toggle it; three fingers up / down on the trackpad open and
+-- close it following the fingers (the overlay reads the trackpad itself).
+o.bind("CTRL + UP", "Mission Control", hl.dsp.global("mission-control:toggle"))
+o.bind("CTRL + EQUAL", "Mission Control", hl.dsp.global("mission-control:toggle"))
 
 -- Ctrl + Left / Right move between workspaces on this monitor (including empty
 -- ones, like macOS Spaces). Use m+1 / m-1 to cycle only existing workspaces.
 o.bind("CTRL + RIGHT", "Next workspace", hl.dsp.focus({ workspace = "r+1" }))
 o.bind("CTRL + LEFT", "Previous workspace", hl.dsp.focus({ workspace = "r-1" }))
 
--- Three-finger swipe down closes Mission Control. It only hides the overlay (a
--- no-op when it is closed); three-finger up, in the m5pro profiles, opens it.
-hl.gesture({ fingers = 3, direction = "down", action = function() hl.exec_cmd("omarchy-shell shell hide rolo.mission-control") end })
-
```

`~/.config/hypr/looknfeel.lua` (backup `looknfeel.lua.pre-mission-control-live`):
```diff
@@ -53,3 +53,6 @@
+
+-- Mission Control draws its own open and close animation.
+hl.layer_rule({ match = { namespace = "^mission-control(-bar)?$" }, no_anim = true, animation = "none" })
```

`~/.config/hypr/m5pro-dcp.lua` and `~/.config/hypr/m5pro.lua` (backups `*.pre-mission-control-live`), the same hunk in both:
```diff
--- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 3 up = Mission Control, 4 down = fullscreen.
--- (3 up was the scratchpad; that stays on Super + S. Mission Control is the shell plugin rolo.mission-control.)
+-- Apple MTP trackpad gestures: 3-finger swipe = workspaces, 4 down = fullscreen.
+-- (3 up / down is Mission Control: ~/.config/quickshell/mission-control/ reads the trackpad itself,
+-- so there is no gesture line for it here. The scratchpad stays on Super + S.)
 hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
-hl.gesture({ fingers = 3, direction = "up", action = function() hl.exec_cmd("omarchy-shell shell toggle rolo.mission-control") end })
 hl.gesture({ fingers = 4, direction = "down", action = "fullscreen" })
```

`~/.config/omarchy/shell.json` (backup `shell.json.pre-mission-control-live`), written by `omarchy plugin disable`:
```diff
@@ -129,9 +129,6 @@
     {
       "id": "m5pro.touchid"
-    },
-    {
-      "id": "rolo.mission-control"
     }
```

## Verified
Seen on the machine, from the agent session:

- GPU rendering: open and close animations average 8.2 to 8.5 ms per frame (120 Hz), worst single frame 11 to 22 ms, read
  from the overlay's own frame timer (`qs -p ~/.config/quickshell/mission-control ipc call mc status`).
- Live capture over dmabuf works on the Aurora GPU: every window of the visible workspace had a frame 6 to 24 ms after the
  surface was mapped; `grim` screenshots show live window pictures on the stage and in every workspace thumbnail,
  including workspaces that are not visible.
- Seamless start: a `grim` screenshot of the overlay frozen at progress 0 against one of the plain desktop differs in 258
  of 7.7 million pixels (`magick compare -metric AE -fuzz 4%`).
- `dmesg` has no `GPU work of a client failed` line for the whole session of tests (about 20 map/unmap cycles).
- Gesture state machine, with swipes fed over IPC in the reader's line format: resting fingers map and unmap the surface;
  a short flick falls back; half a swipe holds at progress 0.50 with the fingers down; release opens; a sideways swipe
  moves the stage and settles on Hyprland's active workspace; a swipe down closes.
- `mc-gestures` finds the built-in trackpad (`Apple MTP multi-touch`) and runs under the service.
- Ctrl+Up path: `hyprctl dispatch 'hl.dsp.global("mission-control:toggle")'` opens and closes the overlay.
- Actions, on throwaway terminal windows on spare workspaces: add workspace, close workspace (its windows moved to the one
  beside it), the three dispatch expressions (move, focus, close), drop-target hit testing.

- After the follow-up: `hyprctl configerrors` is empty; `hyprctl layers` shows `mission-control-bar` at 0,0 1728x37 under the
  bar while the overview is up and nothing after it closes; a `grim` screenshot shows the bar on the same dark band as the
  strip.

Seen by Rolando: the real three-finger swipes ("the feel is great").

**Not verified**: dragging a window with the pointer, hover close buttons, keyboard navigation inside the overview, and the
sideways swipe with Hyprland really switching underneath were not reported on either way.

Known limits: a fullscreen window covers the bar strip the overlay leaves free, so its top edge shows above the overlay; an
open bar panel is hidden while the overview is up; window opacity rules are not reproduced in the pictures. The process
idles at about 350 MB and peaks near 1.2 GB while open (full-size window pictures). It is one more GPU client: tracker
#36 applies to it as to any other.

## Rollback
```bash
systemctl --user disable --now mission-control.service
rm ~/.config/systemd/user/mission-control.service && systemctl --user daemon-reload
cd ~/.config/hypr
cp -a bindings.lua.pre-mission-control-live bindings.lua
cp -a looknfeel.lua.pre-mission-control-live looknfeel.lua
cp -a m5pro-dcp.lua.pre-mission-control-live m5pro-dcp.lua    # only with the old plugin re-enabled below
cp -a m5pro.lua.pre-mission-control-live m5pro.lua
hyprctl reload
omarchy plugin enable rolo.mission-control        # the old icon-only overview
rm -r ~/.config/quickshell/mission-control        # optional
```

## Update: the swipe up trailed the fingers (2026-11-19)
Rolando, after using it: the three-finger swipe up "sort of lags behind a little bit".

Cause, from the overlay's own log during his swipes (`journalctl --user -u mission-control.service`):

- The layer surface was created on each use. Between asking for it and its first frame went 114 to 260 ms ("surface up
  after ..."), a whole swipe: the first picture appeared when the swipe was already 67 to 110 % done. The agent-session
  tests had not shown this because they timed the animation after the surface was up. Inferred, not measured further:
  the time goes into creating the window's GPU surface (EGL window and swapchain on zink).
- Building the window and workspace items took about 15 ms of each opening on top of that.
- libinput reports a swipe only after it has told it from a pinch, a few millimetres in, so the travel before that was lost.

Fix:

1. The overlay's surface (and the strip under the bar) is created once and stays mapped: transparent, click-through, no
   keyboard focus, and not redrawn while the overview is closed. It is parked on the focused monitor ahead of time.
2. The window and workspace items are kept between openings; only their pictures are dropped on close.
3. One silent run 1.2 s after the service starts draws everything once at 0.4 % opacity, so the first real opening does not
   pay for shader compiles (88 to 133 ms that one time).
4. `mc-gestures` also reads the pad's raw contacts (a second read-only descriptor, `ABS_MT_*`): `T <count>` when the
   number of fingers changes, and `RB` / `R dx dy ms` / `RE` once three fingers have each moved 0.4 mm the same way (a
   resting palm, a pinch or a third finger under a two-finger scroll do not qualify). The overlay starts taking the window
   pictures the moment three fingers land and follows the raw centre for up and down. libinput remains the fallback for up
   and down (for example with a palm resting as a fourth contact) and the source for sideways, which is what Hyprland
   itself listens to. Raw millimetres are scaled by 10.517 to libinput's unaccelerated units, so `swipeDistance` keeps its
   meaning (250 units is about 24 mm).
5. While the fingers move the overview is drawn 8 ms ahead along their speed (`leadMs`), and if the first picture arrives
   after the fingers have moved, the gap is closed over at most 45 ms (`catchMs`) instead of jumping.

Verified from the agent session: over six IPC-triggered openings the first pictures were ready 14 to 22 ms after the
request (was 114 to 260 ms on Rolando's swipes); `hyprctl layers` shows both surfaces mapped while closed; simulated raw
swipes (`T 3`, `RB`, `R ...`, `RE`, with late libinput lines that must be ignored) hold at half, open, and close; the
libinput-only path still works; no `GPU work of a client failed` line in `dmesg`. The new reader reports
`raw contacts on /dev/input/event1, 16 slots, 98 x 98 units/mm` and printed `T 1` / `T 0` for a real touch.

**Not verified**: how it feels under real fingers, the 10.517 scale against libinput on this pad (the reader logs both
travels per swipe: `swipe libinput ... units, raw ... mm`), and accidental openings from odd three-contact touches.

Cost of staying mapped: the compositor blends one more transparent full-screen surface in the regions it redraws, and the
process holds its buffers (about 500 MB resident right after start, where it was about 350 MB). Rollback of this update only:
set `visible: mc.mapped && !!mc.screen` on the two `PanelWindow`s in `shell.qml`.

## Update: text jittered and blurred while the windows scaled (2026-11-19)
Rolando, after the latency fix ("working amazingly"): text "seems to feel a little jumpy during the animation as if it's
scaling weirdly. It sort of blurs out slightly".

Seen by Rolando's swipes in the log after the latency fix: fingers down to first picture 16 to 21 ms, swipe seen to first
picture 2 to 12 ms (progress 0.06 to 0.11 at that moment). The reader's comparison lines put the raw contacts 2.4 to 3.7 mm
ahead of libinput's swipe, and the scale at about 9.6 to 10.1 units per mm on full swipes (10.517 is used; left as is).

Cause, read from `/usr/lib/qt6/qml/Quickshell/Widgets/ClippingRectangle.qml`: the rounded clip draws its content through a
`ShaderEffectSource` of an item the size of the clip. Each tile's clip was the size of the shrinking tile, so the window
picture was resampled twice (into an offscreen copy at the tile's size, in whole pixels, then onto the screen), and that
copy's size stepped a pixel at a time as the tile scaled. Also the spread subtracted the same gap from width and height, so
a window was scaled by slightly different factors across and down (0.772 against 0.767 for a full-width window).

Fix:
- `WindowTile.qml`: the clip and the picture are laid out at the window's own size (one texel per pixel) and scaled once
  by a transform. That full-size offscreen copy exists only while the overview is in use (a `Loader`).
- `Layout.js`: one scale per window for both directions; the resting position is on whole pixels.
- The CPU-renderer refresh timer and `refreshMs` are gone (the overlay is GPU only).

Verified from the agent session: the overlay frozen at progress 0 still matches the desktop (414 of 7.7 million pixels);
open and close average 8.0 ms per frame, worst frame 10 ms; first pictures after 13 to 19 ms; edge sharpness of a text
region at rest rose about 5 % (Laplacian standard deviation 3.56 to 3.72, same window); the process idles at about 390 MB
(was 560 to 710 MB with the items kept and their copies alive). **Not verified**: how text looks in motion, which only
shows on the panel.

## Update: swipes commit more readily, workspace slide, motion resampled per frame (2026-11-19)
Rolando: the text fix is "working great"; now a quick swipe "is sort of not committing to the move as much, especially
when I swipe between workspaces", and the animations should be extremely smooth and efficient.

What the machine showed:
- Hyprland's workspace swipe committed only past half the swipe distance (`workspace_swipe_cancel_ratio` 0.5 of 300), and
  the speed that forces a commit (`workspace_swipe_min_speed_to_force` 30 units per event) is out of reach of a flick.
- The `workspaces` animation is off (Omarchy's default, `hyprctl animations`: `enabled: 0`), so a workspace swipe followed
  the fingers and then jumped the rest of the way on release. `m5pro-dcp.lua` notes that choice was kept on purpose
  ("every frame of a slide recomposites and re-blurs the whole panel"); the swipe itself already does that per frame.
- The overlay decided an up/down release by `position + speed x 0.16 > 0.5`, with speed taken over the last six reports.
- The overlay drew the last report it had. Reports come on the pad's clock and frames on the display's, so some frames
  carried two reports and some none.

Changes:
1. `~/.config/hypr/input.lua` (backup `input.lua.pre-mission-control-live`): `workspace_swipe_cancel_ratio = 0.2`,
   `workspace_swipe_min_speed_to_force = 6`.
2. `~/.config/hypr/looknfeel.lua`: `hl.animation({ leaf = "workspaces", enabled = true, speed = 2.8, bezier =
   "easeOutQuint", style = "slide" })`. This also makes keyboard workspace switches slide (280 ms) instead of jumping.
3. `shell.qml`:
   - Release rule (`flickSpeed`, `commitTravel`, `commitPage`): faster than 1.4 overviews (or workspaces) per second, the
     swipe goes where it was heading however short; slower, it needs 28 % of the way (20 % of a workspace). Speed is taken
     over the last 70 ms.
   - Each frame carries the last report forward along the fingers' speed to the present (at most 16 ms, plus `leadMs`),
     for up/down and for sideways.
   - Sideways in the overview follows the raw contacts too. When the swipe ends the stage decides: 70 ms later Hyprland's
     active workspace is compared with the one shown and corrected if it differs.
   - After any workspace change the overlay is not unmapped for 330 ms, so Hyprland's slide underneath is never uncovered
     midway.
   - A window picture whose recording Hyprland ends (`Ending recording due to screencopy failure`, seen a few times,
     cause not found) is made afresh, at most four times per opening, and logged (`capture stopped: ...`).

`~/.config/hypr/looknfeel.lua`, appended:
```diff
+-- Workspaces slide (Omarchy switches them instantly). Without this a workspace
+-- swipe follows the fingers and then jumps the rest of the way on release.
+-- Remove the line to get the instant switch back.
+hl.animation({ leaf = "workspaces", enabled = true, speed = 2.8, bezier = "easeOutQuint", style = "slide" })
```
`~/.config/hypr/input.lua`, appended:
```diff
+-- Workspace swipes commit more readily: a fifth of the way is enough (was half),
+-- and a quick flick commits however short (the old speed could not be reached).
+-- See https://wiki.hypr.land/Configuring/Basics/Variables/#gestures
+hl.config({
+  gestures = {
+    workspace_swipe_cancel_ratio = 0.2,
+    workspace_swipe_min_speed_to_force = 6,
+  },
+})
```

Verified from the agent session: `hyprctl configerrors` empty, `hyprctl getoption` shows 0.2 and 6, `hyprctl animations`
shows `workspaces` enabled, slide, 2.80. Simulated raw swipes: up 36 % slowly opens, 16 to 18 % slowly goes back; in the
overview a 12 % sideways nudge returns and 25 % commits, and Hyprland's active workspace followed the stage both ways
(2 to 3 and back). 32 open/close cycles without a restart of the service.

One crash while testing: `The Wayland connection experienced a fatal error: Invalid argument`, once, on an interactive open
three seconds after a service start, with an earlier retry scheme (restarting a recording in place, and asking a thumbnail
for a frame again). The service restarted itself. That scheme was replaced by re-creating the picture; the error did not
come back in the cycles above, but its cause is not proven.

**Not verified**: real flicks (the simulated ones are slowed by the IPC round trip, so only the distance rule was
exercised), the feel of the resampling, and the GPU cost of the workspace slide in daily use.

Rollback of this update: `cp -a ~/.config/hypr/input.lua.pre-mission-control-live ~/.config/hypr/input.lua`, delete the
`workspaces` animation line from `looknfeel.lua`, `hyprctl reload`.

## Update: faster animations, steadier motion for text (2026-11-19)
Rolando: "How can we improve the text rendering whenever I animate? Can we make the animations faster, too?"

Faster:
- `shell.qml`: `omega` 24 to 34 and `pageOmega` 21 to 32 (a keyboard open now settles in 39 frames, was 53; 90 % of the way
  in about 115 ms); the wait before uncovering the desktop after a workspace change 330 to 260 ms.
- `WindowTile.qml`: tiles re-arrange in 180 ms (was 240).
- `~/.config/hypr/looknfeel.lua`: the `workspaces` slide `speed = 2.0` (was 2.8).

Text while the windows move. Two things blur or shake it; one is addressed here:
- Uneven motion. The overlay extrapolated the fingers from the last three reports, with millisecond timestamps, to a wall
  clock read at whatever moment the frame handler ran. Both add noise to where each frame is drawn, and a window whose
  speed wobbles by a pixel or two per frame makes its text shimmer. Now: `mc-gestures` prints timestamps to the
  microsecond; the overlay fits a line through the last 45 ms of reports and reads it off at the frame's own clock
  (`FrameAnimation.elapsedTime`, tied to the wall clock by a slow average), and only in the frame handler, never when a
  report arrives.
- The filter. A window drawn smaller than it is gets resampled, here with the GPU's bilinear filter, which is soft and
  uneven from pixel to pixel. A bicubic filter would be sharper (about 7 % more edge contrast on a crop of on-screen text
  scaled to 83 % with ImageMagick, bilinear against Catmull-Rom) and steadier in motion. That needs a custom fragment
  shader, and compiling one needs `qsb` from `qt6-shadertools` (6.12.0-1, not installed; `pacman -Sp` lists no other
  package). Not done: waits for `sudo pacman -S --needed qt6-shadertools`.

Also: `~/.config/hypr/bindings.lua` gains Super+Ctrl+Up, which restarts `mission-control.service`. The surface is always
mapped, so a hung overlay holding the keyboard would otherwise need a reboot.

Verified from the agent session: `hyprctl configerrors` empty; open and close by key and by simulated swipes average
8.0 ms per frame, worst 8.7 to 9.0 ms; no restart of the service; no GPU fault line. The machine rebooted twice during the
day's work (06:18 and 06:51 local); both were orderly shutdowns in the journal, with no GPU fault line and no core dump
before them.

**Not verified**: whether text in motion looks steadier (only visible on the panel), and the new speeds by feel.
