# Faster desktop motion: tray drawer and Hyprland animations (2026-11-27)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/36     Kernel: 7.3.0-g0f96ca644485

## What broke
The bar's hidden tray area (the `<` chevron) opened and closed too slowly, and window and layer animations felt sluggish.

## Cause
The `rolo.tray` clone kept the 600 ms drawer duration copied from Waybar's tray expander. Omarchy's Hyprland defaults
(`/usr/share/omarchy/default/hypr/looknfeel.lua`) run windows in at about 410 ms, window moves at 380 ms, layer fade-in at
400 ms. The remaining stutter came from the shell drawing on the CPU, fixed in [2026-11-27-gpu-shell.md](2026-11-27-gpu-shell.md).

## Fix
1. `rolo.tray`: drawer duration 600 -> 150 ms; drawer width snapped to device pixels so neighbouring widgets do not land
   between pixels each frame. Repo copy: `contrib/omarchy-mac/plugin-rolo-tray/` (now also carries the 2026-11-19 quit menu).
2. `~/.config/hypr/looknfeel.lua`: overrides after Omarchy's defaults (Hyprland speed is in tenths of a second).

| Animation | Before | After |
|---|---|---|
| windows (move/resize) | 3.79 | 2.5 |
| windowsIn (popin) | 4.1 | 2.5 |
| layersIn | 4 | 2 |
| fadeLayersIn | 1.79 | 1.5 |
| specialWorkspaceIn / Out | 3 / 2 | 2 / 1.5 |
| border | 5.39 | 3 |
| workspaces (slide) | 2.0 | 1.5 |

## Files changed
```diff
--- .config/hypr/looknfeel.lua.pre-fast-anim	2026-11-27 06:47:16.549128083 -0600
+++ .config/hypr/looknfeel.lua	2026-11-27 06:47:16.713751134 -0600
@@ -60,4 +60,13 @@
 -- Workspaces slide (Omarchy switches them instantly). Without this a workspace
 -- swipe follows the fingers and then jumps the rest of the way on release.
 -- Remove the line to get the instant switch back.
-hl.animation({ leaf = "workspaces", enabled = true, speed = 2.0, bezier = "easeOutQuint", style = "slide" })
+hl.animation({ leaf = "workspaces", enabled = true, speed = 1.5, bezier = "easeOutQuint", style = "slide" })
+
+-- Faster motion than Omarchy's defaults (speed is in tenths of a second).
+hl.animation({ leaf = "windows", enabled = true, speed = 2.5, bezier = "easeOutQuint" })
+hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.5, bezier = "easeOutQuint", style = "popin 87%" })
+hl.animation({ leaf = "layersIn", enabled = true, speed = 2, bezier = "easeOutQuint", style = "fade" })
+hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.5, bezier = "almostLinear" })
+hl.animation({ leaf = "specialWorkspaceIn", enabled = true, speed = 2, bezier = "easeOutQuint", style = "slide top" })
+hl.animation({ leaf = "specialWorkspaceOut", enabled = true, speed = 1.5, bezier = "easeInOutCubic", style = "slide bottom" })
+hl.animation({ leaf = "border", enabled = true, speed = 3, bezier = "easeOutQuint" })
```

```diff
--- .config/omarchy/plugins/rolo.tray/Tray.qml.pre-fast-anim	2026-11-27 06:47:16.547997747 -0600
+++ .config/omarchy/plugins/rolo.tray/Tray.qml	2026-11-27 06:52:06.379034067 -0600
@@ -47,10 +47,12 @@
   readonly property bool holdOpen: trayMenuOpen || managePopupOpen || barDragging || (!!bar && bar.traySectionPopoutOpen === true)
   // The mark under the bar sits under the icon whose menu is open.
   readonly property Item openPanelIndicatorItem: trayMenuOpen ? activeTrayAnchor : null
-  // Match Waybar's group/tray-expander drawer transition-duration.
-  readonly property int animationDuration: 600
+  // Was 600 (Waybar's tray-expander duration); Rolando wants it fast.
+  readonly property int animationDuration: 150
   property real revealProgress: expanded || holdOpen ? 1 : 0
-  readonly property real revealExtent: drawerExtent * revealProgress
+  // Snapped to whole device pixels: a fractional width made every widget to
+  // its side land between pixels on each frame, which reads as shimmer.
+  readonly property real revealExtent: Math.round(drawerExtent * revealProgress * Screen.devicePixelRatio) / Screen.devicePixelRatio
   // The pinned icons sit against the tray's fixed edge with the chevron past
   // them. Opening, the drawer grows the tray between the two and pushes the
   // chevron out of the way, while the pointer that opened it stays over the
```
Full file: [files/2026-11-27-fast-animations/looknfeel.lua](files/2026-11-27-fast-animations/looknfeel.lua).

## Verified
`hyprctl reload` with no `configerrors`; `hyprctl -j animations` shows the new speeds. The shell reloaded the tray (restarted
once because the running shell had cached the old file). Rolando: "much better" for the tray drawer.

## Rollback
```bash
cp -a ~/.config/hypr/looknfeel.lua.pre-fast-anim ~/.config/hypr/looknfeel.lua && hyprctl reload
cp -a ~/.config/omarchy/plugins/rolo.tray/Tray.qml.pre-fast-anim ~/.config/omarchy/plugins/rolo.tray/Tray.qml && omarchy restart shell
```
