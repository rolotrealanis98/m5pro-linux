# Keep top-bar widgets clear of the notch (2026-11-08)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/42     Kernel: 7.3.0-g0933f881d736

## What broke
The camera notch obscured the center widgets on the internal display.

## Cause
Omarchy 4.5.0-3 includes notch-aware positioning in Bar.qml and BarModel.js, but `/usr/share/omarchy-platform/display-cutouts.json` is absent and omarchy-mac is not installed. Thus the bar has no cutout description. Live panel: 3456x2234, scale 2, 120 Hz; top reservation 26 logical pixels.

## Fix
Read the machine brief, bar guide, live monitor state and installed notch handling. Searched the tracker for notch issues (none returned), synced both repos, and opened the tracker issue. Backed up shell.json and changed only bar.layout with Python JSON parsing. Moved indicators and clock after workspaces on the left; prepended world time, weather and updates to the existing right section. All three center sections are empty. Shell configuration hot-reloads; no restart was requested. No packages installed.

Initial sandboxed GitHub and compositor queries failed; elevated read-only queries worked. Initial issue-creation approval timed out before execution; retry with the prepared body succeeded.

## Files changed
`~/.config/omarchy/shell.json` (backup: `~/.config/omarchy/shell.json.pre-notch-layout`). Exact diff:

```diff
--- shell.json.pre-notch-layout
+++ shell.json
@@ -2,20 +2,27 @@
   "bar": {
     "background": "none",
     "layout": {
-      "center": [
+      "center": [],
+      "centerBegin": [],
+      "centerEnd": [],
+      "left": [
+        {
+          "id": "omarchy.menu"
+        },
+        {
+          "id": "omarchy.workspaces"
+        },
+        {
+          "id": "omarchy.indicators"
+        },
         {
           "format": "dddd HH:mm",
           "formatAlt": "d MMMM 'W'ww yyyy",
           "id": "omarchy.clock",
-          "verticalFormat": "HH\n—\nmm"
+          "verticalFormat": "HH\n\u2014\nmm"
         }
       ],
-      "centerBegin": [
-        {
-          "id": "omarchy.indicators"
-        }
-      ],
-      "centerEnd": [
+      "right": [
         {
           "cities": [
             {
@@ -46,17 +53,7 @@
         },
         {
           "id": "omarchy.system-update"
-        }
-      ],
-      "left": [
-        {
-          "id": "omarchy.menu"
         },
-        {
-          "id": "omarchy.workspaces"
-        }
-      ],
-      "right": [
         {
           "id": "omarchy.tray"
         },
```

## Verified
JSON parses. Assertions confirm every widget and its settings is preserved, all center sections are empty, and all configuration outside bar.layout is unchanged. No display mode or bar height setting was changed. After applying, hyprctl still reports a 26-logical-pixel top reservation; recent user-journal warnings are empty.

## Unverified
Physical notch clearance and appearance need visual confirmation by Rolando. No feature matrix status changed.

## Rollback
```bash
cp -a ~/.config/omarchy/shell.json.pre-notch-layout ~/.config/omarchy/shell.json
```
The restored configuration hot-reloads.
