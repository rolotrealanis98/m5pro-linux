# Glitch survey (phase 1 on 2026-11-27, status after phase 2 on 2026-11-28)

Observed on the Mac with the upstream `v2.1.6+desktop.96` build and our identical rebuild: Hyprland, scale 2, 3456x2234, Aurora GPU. Method: protocol traces (`WAYLAND_DEBUG=client`), screenshots of the window (kept only in `/Volumes/m5pro/bench/bluebubbles/shots/`, they show private conversations and are never published), and the code. Nothing was sent, marked, or changed in the app. Effort: S under a day, M a few days, L a week or more.

"Observed" means seen on screen or in a trace; "code" means read in the source, not yet seen running.

| # | Glitch | How to reproduce | Proposed fix | Effort |
|---|---|---|---|---|
| 1 | Emoji do not render properly. Some emoji (in a contact name, in a chat-list preview, in a message) show as empty boxes (tofu); an emoji-only message shows as a flat white heart glyph instead of the colored emoji. Observed. `fc-match emoji` resolves to Noto Color Emoji, so the font exists; Flutter's fallback is not picking it for these sequences. | Open the chat list and a conversation that has emoji (VS16 or ZWJ sequences). | Set an explicit `fontFamilyFallback` with Noto Color Emoji in the app theme, or use the app's own "Download iOS Emoji Font" option (`theming_panel.dart:521`). Verify which sequences fail first; the Noto version installed may lack the newest emoji. | S-M |
| 2 | Wrong window identity at first map: the xdg title is `bluebubbles_app` (runner, `linux/my_application.cc`) until Dart sets `BlueBubbles`; the launcher is named "Messages". Observed in the trace. | Launch and read `hyprctl clients`. | Set title and header text in the runner to the product name; app id `bluebubbles` already matches `StartupWMClass`. | S |
| 3 | Flutter-drawn minimize, maximize and close buttons sit on top of the conversation header (top right of the iOS-skin split view). Minimize has no meaning under Hyprland. Observed. | Open any conversation; `titleBarStyle` is `custom` by default. | Default `titleBarStyle` to `hidden` on Wayland non-GNOME (SLIM-PROFILE.md). | S |
| 4 | The window opens floating at the last saved size (1100x759 at an arbitrary position) instead of tiling like the Omarchy apps. Observed (`floating: true`). Cause not isolated: saved size restore (`main.dart:193`) or a Hyprland rule. | Launch; compare with `hyprctl clients`. | Check the Omarchy window rules for the class `bluebubbles`; if size hints cause it, stop calling `setSize` on Wayland. | S |
| 5 | Startup resize: the first dmabuf buffers are 2652x1628 and 2640x1616 (about 1326x814 logical), then the compositor configures 1100x759 and the real 2200x1518 buffers follow. Observed in the trace. A brief wrong-size first frame. | `WAYLAND_DEBUG=client bluebubbles`, look at `create_immed` and `xdg_toplevel.configure`. | Apply the saved size before the first realize in the runner (read prefs in C++ or pass through an argument). | M |
| 6 | Frame cadence is locked at 60 fps on a 120 Hz panel: commit interval p50 16.7 ms in every run (upstream, ours, Skia and Impeller). Observed. Pacing at 60 Hz is clean (p95 19.7 ms, p99 21 ms, worst 26 ms). | Scroll the chat list while tracing surface commits (tools/bb-measure.py). | Find where vsync is taken (the GTK3 frame clock or the engine's timer) and whether Hyprland's frame callbacks reach the client at 120 Hz. Try `FL_` and GDK frame-clock settings; this is the main smoothness item. | M |
| 7 | Memory growth while scrolling: RSS 520 MB at start, 770 MB at idle after a minute, 900-1000 MB after 10 s of list scrolling with Skia; 1.1-1.4 GB with Impeller. Observed. | `tools/bb-measure.py`. | Cap `PaintingBinding.imageCache` (maximumSizeBytes) and the decoded size of avatars and previews (`attachment_preview.dart:271` already caps at 512 px); profile with DevTools memory. Quick win. | S-M |
| 8 | Idle cost with the window visible and nothing happening: 1.2-3.3 percent CPU and 26-35 context switches per second. Observed. Something ticks (animation, timer, polling). | Leave the window open for 60 s. | Profile with a `--profile` build and the timeline; candidates: socket ping or polling timers, a running animation (typing indicator, sync spinner). | M |
| 9 | No fractional scale. The embedder is GTK3: `wp_fractional_scale_v1` is never requested and `set_buffer_scale` is always an integer (2 for any scale above 1). At Hyprland scale 1.5 to 1.75 the compositor resamples a 2x buffer and the UI comes out about 1.14-1.33 times too large and soft. Measured at the current scale 2 only (the live scale change was not run on the owner's display); the buffer-scale and fractional-scale facts are from the trace. | Set a fractional monitor scale in `monitors.lua`. | At scale 2 nothing to fix. For fractional scales: run under XWayland with `GDK_SCALE` (blurry too), or move the runner to a GTK4 embedder when one exists. Not a phase 1 fix. | L |
| 10 | `GDK_SCALE=2` from Omarchy has no effect on this Wayland build: the protocol traces with `GDK_SCALE` 2, 1 and unset are identical (buffer scale 2, same buffers). So the wrapper cannot fix scaling through that variable. Observed. | `tools/bb-measure.py ... --set=GDK_SCALE=1 --wldebug`. | None needed; documented so nobody tunes it. | - |
| 11 | The GIF picker lost its key in a self-built bundle: the upstream release ships a 79-byte `.env` (Klipy key); builds here have an empty one. Fixed in `install.sh` (copies the installed upstream `.env`). | Open the GIF picker in a build with an empty `.env`. | Done. Longer term get our own Klipy key. | - |
| 12 | Notifications (code): no inline reply on Linux (Windows branch only), no category or desktop-entry hint, actions are Mark Read plus tapbacks. Not yet observed. | Receive a message with the window hidden. | See SLIM-PROFILE.md C2. | S-M |
| 13 | Close to tray (observed): closing the window hides it and the process keeps running; `hyprctl` close does not quit the app. Whether a tray icon shows under the Omarchy bar (`rolo.tray` plugin) was not verified. | Close the window, then look for the icon. | Verify the StatusNotifier icon; default `closeToTray` only when a tray host exists. | S |
| 14 | The app reopens the last opened chat at start (observed), so launching it shows a conversation immediately; this can mark that chat as read on the server. Not changed. | Launch after using a chat. | Option to start on the chat list (phase 2, needs the owner's call). | S |
| 15 | Settings clutter: about 120 options, many dead on Linux (for example "Use Linux Accent Color" does nothing). Code. | Open Settings. | SLIM-PROFILE.md. | M |

## Checked and not a problem
- Rendering is crisp at scale 2: the window is 1100x759 logical, the steady buffers are 2200x1518 (`set_buffer_scale(2)`), text edges are sharp in the screenshots.
- GPU path: GL runs on the Aurora Mesa stack (`libEGL_aurora`, `libgallium-26.3.0-devel`), not llvmpipe.
- `text-scaling-factor` is 0.8182 in the user's GSettings; running the app with `GSETTINGS_BACKEND=memory` (factor 1.0) gave an identical rendering, so the app does not consume it.
- Window minimum size: Dart sets 300x300 logical (`main.dart:181`); GTK briefly reports smaller sizes during startup (111x42 and similar) and settles at 300x300.

## Not covered yet (needs interaction that could change state, or owner input)
Typing and sending, IME (fcitx5 is running here), drag and drop, paste, attachment viewer and video, tapbacks, link previews, search, new-chat flow, resize behavior below 300 px and during live resize, popup menus and tooltips under Hyprland focus rules, dark and light theme switching, multi-monitor (see `contrib/omarchy-mac/external-displays`). None of these were exercised, to honour the rule of never sending, deleting or marking messages.

## Phase 2 status (offline build; "seen" = observed once on the device before it was withdrawn)
| # | Status |
|---|---|
| 1 emoji | Fixed in 0005 (Noto Color Emoji fallback in the theme and the explicit emoji styles). Seen: color emoji in a contact name and in previews. Newest emoji depend on the installed Noto version. |
| 2 title | Fixed in 0003 (runner title `BlueBubbles`); Dart already set it after start. |
| 3 window buttons | Fixed in 0002 (titlebar hidden by default). Seen: no buttons over the header. The Window Behavior tile still lets the owner pick Native or Custom. |
| 4 floating window | Not an app bug. Omarchy has floating and tiling modes per workspace (`/usr/share/omarchy/default/hypr/workspace-modes.lua`); phase 1 ran on a floating workspace, phase 2 on workspace 9 where the window tiled. |
| 5 startup wrong-size buffers | Open. Needs the saved size applied before the first realize in the runner; not attempted blind. |
| 6 60 fps | Diagnosed, not a cap: the engine reports `refreshRate=120.0` and the runner does not use the GTK frame clock; 16.7 ms commits mean each frame costs over 8.3 ms. `BB_DIAG` prints build and raster p50/p95/max every 5 s to say which thread is over budget; the device run answers it. Not fixed. |
| 7 memory | Image cache capped at 48 MB / 300 images (0007). One run: RSS after scroll 869 MB against 890-1002 MB; confirm with repeats. Other holders (Skia caches, glyphs, ObjectBox) are listed by `bb-measure.py` (`smaps_after_scroll`). |
| 8 idle cost | Measurement ready (`BB_DIAG` frames per 5 s while idle); no fix until it names the ticker. |
| 9 fractional scale | Open, unchanged (GTK3 embedder). |
| 10 `GDK_SCALE` | Documented, nothing to do. |
| 11 GIF key | Fixed in `install.sh` (phase 1). |
| 12 notifications | Open; planned in SLIM-PROFILE.md C2. |
| 13 tray | Open; close-to-tray stays on, a tray-host check is still to do. |
| 14 last chat at start | Fixed in 0006 (starts on the chat list; Desktop Settings can restore the old behaviour). |
| 15 settings clutter | Done in 0009 for about 45 tiles and 7 entries (see SLIM-PROFILE.md). |
