# Steam client UI at a readable size on the 3456x2234 panel (2026-11-27)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/58     Kernel: 7.3.0-g0f96ca644485

## What broke
Steam (Valve's native arm64 client, started by `/usr/local/bin/m5pro-steam` inside a muvm microVM) drew its whole UI at 1x: menus, library and store text were half the size of every other app on the desktop (Hyprland scale 2).

## Cause
Omarchy runs Xwayland unscaled (`xwayland.force_zero_scaling = true`), so an X11 client gets device pixels and has to scale itself. The launcher tries to make Steam do that with `-e STEAM_FORCE_DESKTOPUI_SCALING=<scale>` and `-forcedesktopscaling <scale>`. This client build (`1794536281`, built Nov 13 2026) implements neither:

- `grep -ra -i 'forcedesktopscaling\|FORCE_DESKTOPUI_SCALING'` over `steamrtarm64/`, `linuxarm64/`, `steamui/` and `clientui/` in the Steam directory finds nothing, while `bootstrap_log.txt` shows the argument arriving (`Startup - Steam Client launched with: '.../steamrtarm64/steam' '-forcedesktopscaling' '2'`);
- `webhelper_gpu.txt`: `Display[33] bounds=[0,0 3456x2234], workarea=[0,0 3456x2234], scale=1`;
- no `ThreadSetForceDeviceScaleFactors` line in `webhelper.txt` for the desktop window before the fix.

What the build does have is its own setting: `steamui.so` maps `accessibility_desktop_ui_scale` to the config key `Accessibility/DesktopUIScale`, and `steamui/sp.js` shows it as a slider (label "UI Scale", 0.5 to 2.0 in 0.05 steps) on the Accessibility page.

## Fix
In Steam: Steam > Settings > Accessibility > UI Scale. Rolando set it to 1.55. Steam asks to restart after a change. Nothing else was changed; the two launcher options stay in `m5pro-steam`, where they do nothing with this build (removing them needs root).

Choosing a value: 2.0 is the monitor scale; lower values trade size for content (1.55 on this panel is close to the rest of the desktop, whose GTK text scale is 0.82).

Found on the way: on that restart Steam stayed at "Loading user data..." and had to be stopped (`kill <pid of the host muvm process>`); the next start was fine. Tracked in https://github.com/rolotrealanis98/m4-m5-linux/issues/59.

## Files changed
- `~/.local/share/Steam/config/config.vdf`, written by Steam itself (no backup taken), new section at the top level of `InstallConfigStore`:

```diff
+	"Accessibility"
+	{
+		"DesktopUIScale"		"1.54999995231628418"
+	}
```

## Verified
- After a fresh start: `webhelper.txt` has `ThreadSetForceDeviceScaleFactors 1.000000 * 1.550000 = 1.550000` and the renderers are started with `--force-device-scale-factor=1.55`.
- A capture of the main X11 window (`magick import -window <id>`) before and after: the menu bar text went from about 12 device pixels to about 18, and the library, store tabs and sidebar are all larger; nothing clipped or blurred in the capture.
- Not checked: Big Picture mode, the overlay inside a game, a game's own window size.

## Rollback
Steam > Settings > Accessibility > UI Scale back to the middle (1.0), or with Steam closed delete the `"Accessibility"` block above from `~/.local/share/Steam/config/config.vdf`.
