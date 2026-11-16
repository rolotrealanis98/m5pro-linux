# Theme and background pickers showed no previews: the software-render picker clone was not enabled (2026-11-16)
Tracker: pending (`gh` returned 401 Bad credentials on 2026-11-16, so no issue number yet; filled in when `gh` is logged in again)     Kernel: 7.3.0-g0933f881d736

This doc also records the picker clone itself, built on 2026-11-08 and never written up before.

## What broke
The Omarchy theme picker (Style > Theme, `omarchy-theme-switcher`) and the background picker opened, but the cards had no
preview pictures: no theme previews, no wallpaper thumbnails. The cache they read was fine: every
`~/.cache/omarchy/theme-selector/previews/*.png` link resolved to a stock `preview.png`, and `~/.cache/omarchy/image-selector/`
held its generated thumbnails. Nothing in the user journal pointed at the picker.

## Cause
Proven on the live machine:

- The shell runs with `QT_QUICK_BACKEND=software` (read from the running `quickshell -n -p /usr/share/omarchy/shell` process
  environment; the session launcher pins it, see commit f85ee2e).
- Before the fix `omarchy-shell shell listPlugins` showed `omarchy.image-picker` `enabled: true` and `rolo.image-picker`
  (`clonedFrom: omarchy.image-picker`) `enabled: false`. The shell routes the `image-selector` IPC target, which both
  pickers use through `omarchy-menu-images`, to a clone only while the clone is enabled (`PluginRegistry.resolveEnabledId`).
  So the stock picker was serving both pickers.
- `~/.config/omarchy/shell.json` had neither `{"id": "rolo.image-picker"}` in `plugins[]` nor `omarchy.image-picker` in
  `disabledPlugins[]`.
- The clone was already installed and complete. It is the stock plugin plus the three hunks in
  `files/2026-11-16-image-picker-software/ImagePicker.qml.diff`; `ImagePickerModel.js`, `PreviewHold.qml` and `list.sh` are
  byte-identical to the stock copies, and `ImagePicker.qml.pre-software-render` is byte-identical to the stock `ImagePicker.qml`.

Inferred, not reproduced here: the stock picker draws each card through a `MultiEffect` mask, which is a ShaderEffect, and
Qt's software scene graph cannot draw ShaderEffects, so the cards stay blank. That is the reason the clone was written on
2026-11-08 (its own comment says so) and it matches the symptom, but I did not capture the blank stock picker or test the
stock plugin under a GPU backend.

When the entries went missing is bounded by the `shell.json` backups, which `cp -a` stamped with the original file's mtime:
`shell.json.pre-notch-layout` (mtime 2026-11-08 14:44) still has `rolo.image-picker` in `plugins[]` and
`omarchy.image-picker` in `disabledPlugins[]`; `shell.json.pre-m5w-windows` (mtime 2026-11-12 18:37) has an empty `plugins[]` and
no `disabledPlugins`. So they were dropped between those two points. What dropped them is unknown. `rolo.mission-control` was
dropped the same way (present in `pre-notch-layout`, gone in `pre-m5w-windows`) and is still disabled; it was not part of
this report and was left alone.

## Fix
1. Backed up `~/.config/omarchy/shell.json` as `shell.json.pre-image-picker-enable`.
2. `omarchy plugin enable rolo.image-picker`. This calls the shell's own `enablePlugin` IPC, which writes `shell.json` and
   applies it live; no restart of the shell, Hyprland or anything else. (The shell runs with `QS_DISABLE_FILE_WATCHER=1`, so a
   hand edit of `shell.json` would not hot-reload; the command is the reliable route.)
3. The shell added the three keys shown below: the clone to `plugins[]`, the stock picker to `disabledPlugins[]`, and a
   `cloneSourceRestores` record so that disabling the clone brings the stock picker back.

The picker clone itself (done 2026-11-08, documented here for the first time): `omarchy plugin clone omarchy.image-picker`,
then in `~/.config/omarchy/plugins/rolo.image-picker/ImagePicker.qml`: a `softwareRender` property (true when
`QT_QUICK_BACKEND` starts with `software`); when set, the card face is a rectangle sheared into the card's parallelogram with
`clip: true`, its content carrying the opposite shear so the picture stays straight, and the `Shape` mask layer and
`MultiEffect` are switched off. On a GPU backend the original mask path is used unchanged.

## Files changed
`~/.config/omarchy/shell.json` (backup `shell.json.pre-image-picker-enable`):

```diff
--- a/shell.json
+++ b/shell.json
@@ -109,6 +109,15 @@
   "plugins": [
     {
       "id": "m5w.reboot-windows"
+    },
+    {
+      "id": "rolo.image-picker"
     }
+  ],
+  "disabledPlugins": [
+    "omarchy.image-picker"
+  ],
+  "cloneSourceRestores": [
+    "rolo.image-picker"
   ]
 }
```

`~/.config/omarchy/plugins/rolo.image-picker/manifest.json` (from the 2026-11-08 clone; full copy in
`files/2026-11-16-image-picker-software/manifest.json`):

```diff
--- a/manifest.json
+++ b/manifest.json
@@ -1,7 +1,7 @@
 {
   "schemaVersion": 1,
-  "id": "omarchy.image-picker",
-  "name": "Image picker",
+  "id": "rolo.image-picker",
+  "name": "My Image picker",
   "version": "1.0.0",
   "author": "Omarchy",
   "description": "Image-grid selector overlay used for wallpapers, themes, and any other directory of images",
@@ -11,5 +11,8 @@
   "keepLoaded": true,
   "entryPoints": {
     "overlay": "ImagePicker.qml"
+  },
+  "omarchy": {
+    "clonedFrom": "omarchy.image-picker"
   }
 }
```

`~/.config/omarchy/plugins/rolo.image-picker/ImagePicker.qml`: stock plus the three hunks in
`files/2026-11-16-image-picker-software/ImagePicker.qml.diff` (unified diff against
`/usr/share/omarchy/shell/plugins/image-picker/ImagePicker.qml` from Omarchy 4.5.0-3, quickshell 0.3.2, qt6-declarative 6.12.0-4).
Backup of the stock copy: `ImagePicker.qml.pre-software-render`. The other three plugin files are unchanged copies of the stock files.

## Verified
- `omarchy-shell shell listPlugins` after the change: `omarchy.image-picker` `enabled: false`, `rolo.image-picker`
  `enabled: true`, `clonedFrom: omarchy.image-picker`.
- `omarchy-shell image-selector ping` returned `ok`; the shell process kept its PID, so nothing restarted.
- The user journal since the change shows one new line, the usual `quickshell.qmlscanner: Module path ... is outside of the
  config folder` warning that every user plugin gets (`rolo.kmlink` has it too); no QML errors.
- `dmesg` has no `GPU work of a client failed` or `recovery fault` lines.
- Rolando confirmed in chat that the previews show again.

## Rollback
```bash
omarchy plugin disable rolo.image-picker     # removes the clone's entry and re-enables the stock picker (cloneSourceRestores)
```
or put the backup back and have the shell re-read it (`omarchy-shell shell reloadConfig`; not tested here, the shell does not
watch the file):
```bash
cp -a ~/.config/omarchy/shell.json.pre-image-picker-enable ~/.config/omarchy/shell.json
omarchy-shell shell reloadConfig
```
If the previews go blank again, check `omarchy-shell shell listPlugins | jq '.[] | select(.id|test("image-picker"))'` first: the
clone must show `enabled: true`.
