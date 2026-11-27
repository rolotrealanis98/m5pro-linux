# More display controls in Omarchy's Display panel (2026-11-27)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/57     Kernel: 7.3.0-g0f96ca644485

## What broke
Nothing broke. Omarchy's Display panel in the bar offered brightness, text size and two scale buttons (1x and 2x). XDR brightness and auto brightness were rows in the System menu; refresh rate, variable refresh, HDR and night light had no control in the panel. Rolando asked for more complete display controls (finer scaling, refresh rate, VRR), with XDR brightness moved in, so that the bar's Display widget is the one place for display settings. As with the Power panel: inside Omarchy's own widget, not a second one, and without holding it back from Omarchy updates.

## Cause
Missing UI, plus two things specific to this machine:

- The panel is 3456x2234 and gcd(3456, 2234) = 2, so only 1x and 2x give whole logical pixels. Hyprland's scale check rounds every scale in between to one of those, which is why the stock panel shows two buttons. A scale in between needs `debug.disable_scale_checks`.
- The session profile (`m5pro-dcp.lua`, loaded last) sets the panel's rule (mode, scale 2, bit depth), `misc.vrr` and `render.cm_auto_hdr` at every config load. A value changed at run time is therefore undone by the next Hyprland reload, and Omarchy's own scale command rewrites `monitors.lua`, which triggers that reload. Inferred from the config order and from the scaling log (a request for 1x followed seconds later by a state of 2x); not reproduced today.

## Fix
A user plugin, `rolo.display`, takes the place of `omarchy.monitor` in the bar: same icon, same panel, same `omarchy.monitor` IPC target (brightness keys and key bindings keep working). It does not copy the stock panel: `Display.qml` subclasses the packaged `Panel.qml` through a symlink (`stock -> /usr/share/omarchy/shell/plugins/panels/monitor`), as `rolo.power` does. Added to the stock panel:

- under the brightness slider, for the built-in panel: **XDR range** (600, 800, 1000, 1300, 1600 nits; 600 is XDR off) with the current level in nits, through `m5pro-xdr`, and an **Auto brightness** switch (`m5pro-auto-brightness on|off`);
- under the scale buttons: a **Fine scale** slider with 13 stops from 1x to 3x (1.125, 1.25, 1.33, 1.5, 1.6, 1.67, 1.75, 1.875, 2.25, 2.5 in between), showing the size the desktop then "looks like"; the wheel is ignored on it so that scrolling the panel cannot rescale the screen;
- **Refresh rate**: the rates the monitor lists for its resolution, and its resolutions when it lists more than one (the built-in panel lists one mode, 120 Hz, so it shows one button);
- **Variable refresh**: Off, On, Fullscreen (`misc.vrr` 0, 1, 2);
- **HDR**: Off, Auto (HDR while an HDR client is fullscreen, `render.cm_auto_hdr`), On (`cm = "hdr"`, 10 bit);
- **Night light** switch (`omarchy-toggle-nightlight`);
- a "Reset display settings" button once something is remembered.

A change of mode and HDR "On" are applied on trial: the panel asks "Keep this setting?" and goes back after 12 s without an answer.

All changes go through one script in the plugin, `display-ctl`. It applies a change with `hyprctl eval` (one `hl.monitor` call that carries mode, position, scale, transform, bit depth and color mode, read from the monitor's current state, so the result does not depend on an earlier rule) and remembers it in `~/.config/rolo-display/overrides.json`. It edits no Hyprland config file. The panel runs `display-ctl reapply` when the shell starts, after every Hyprland `configreloaded` event and when a monitor is added; `reapply` only acts where the current state differs from the remembered one. A scale set later with Omarchy's own command (Super + /) is seen in Omarchy's scaling log and makes `reapply` forget the remembered scale. XDR is not remembered: it starts off at every boot, as before.

The stock panel's `setScale()` is replaced in the subclass, so the 1x and 2x buttons take the same path (applied at once, remembered, `monitors.lua` not rewritten). That is the only stock behaviour changed. The additions are parented into the stock content when the panel loads it: into the brightness section (found by its 1-100 slider), into the scale section (found by its grid of buttons) and at the end of the content column. If a later Omarchy changes that layout they go to the end of the panel, or are left out with one warning in the shell log, and the stock panel works as shipped. The added controls are mouse only: the stock keyboard cursor does not visit them.

Found on the way: after the first load, the running shell logged "Local plugin changed, reloading" for every edit of `Display.qml` but kept running the first version (a new IPC function stayed "Function not found", also after `rescanPlugins`). `omarchy-restart-shell` loads the edited file.

Commands, in order: created `~/.config/omarchy/plugins/rolo.display/`, `omarchy-shell shell rescanPlugins`, `omarchy-plugin-enable rolo.display` (it swaps the bar entry because the manifest says `clonedFrom: omarchy.monitor`), `omarchy-restart-shell` after later edits. No package, no root change, nothing under `/usr/share/omarchy` or `~/.config/hypr` edited. The System menu rows for XDR and auto brightness are left in place.

## Files changed
- `~/.config/omarchy/plugins/rolo.display/` (new): `Display.qml`, `DisplayModel.js`, `display-ctl`, `manifest.json`, `i18n/en.json`, `tests/test_display_model.js`, and the symlink `stock -> /usr/share/omarchy/shell/plugins/panels/monitor`. Copies in [files/2026-11-27-display-controls/](files/2026-11-27-display-controls/) (the symlink is not copied).
- `~/.config/omarchy/shell.json` (backup `shell.json.pre-display-controls`):

```diff
       "right": [
 ...
-          "id": "omarchy.monitor"
+          "id": "rolo.display"
```

- Written at run time by the panel: `~/.config/rolo-display/overrides.json` (remembered choices) and `~/.config/m5pro-xdr/nits` (the last XDR ceiling picked, which `m5pro-xdr on` and the menu row then use).

## Verified
- `node tests/test_display_model.js`: ok (state parsing with markup-shaped and out-of-range input, exact scales of this panel, scale stops, modes and rates, XDR stops).
- `display-ctl state` prints the live state (eDP-2, 3456x2234 at 120 Hz, scale 2, VRR 1, auto HDR 1, XDR range, auto brightness on) in about 40 ms; a bad scale, a mode the monitor does not list, a VRR value of 9, an XDR ceiling of 5000 and an unknown HDR word are each refused with a message; `reapply` with nothing remembered does nothing.
- After `omarchy-restart-shell`: no `rolo.display` warning in the shell log; `omarchy-shell rolo.display selftest` reports the three additions in place at the brightness and scale sections and that the stock scale button reaches the replaced `setScale()` (a dry run: `scale 1 eDP-2` recorded, nothing applied); `omarchy-shell omarchy.monitor state` still answers; screenshots show the stock sections with the additions.
- Rolando picked 800 in XDR range himself while the panel was open: `m5pro-xdr status` then read "on, up to 800 nits", and the panel showed 800 nits at 100 %.
- Not checked (Rolando chose to test the switches himself): the fine scale slider and with it `debug.disable_scale_checks`, whether `misc.vrr` changes take effect without a reload, the HDR switch and the "Keep this setting?" step, that remembered choices come back after a Hyprland reload and a login, a second monitor (resolution and rate buttons, position), night light, the auto brightness switch, a vertical bar, a right-to-left language.

## Rollback
```bash
cp -a ~/.config/omarchy/shell.json.pre-display-controls ~/.config/omarchy/shell.json
rm -r ~/.config/omarchy/plugins/rolo.display ~/.config/rolo-display
omarchy-restart-shell
hyprctl reload     # puts the config's own scale, VRR and HDR values back
```
`~/.config/m5pro-xdr/nits` can stay or go: without it `m5pro-xdr on` uses the panel's peak again. If an Omarchy update ever moves or renames the stock Display panel, the widget will not load and the display icon will be missing: the first line above alone brings the stock widget back.
