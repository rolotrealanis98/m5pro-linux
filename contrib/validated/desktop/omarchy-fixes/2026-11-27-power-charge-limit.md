# Adjustable battery charge limit in Omarchy's Power panel (2026-11-27)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/55     Kernel: 7.3.0-g0f96ca644485

## What broke
Rolando could not change the battery charge limit from the desktop. It sat at 80 % (charging resumes at 75 %), and the only controls were the System menu rows: Limit to 80 %, Charge to 100 % once, No limit. The bar's Power panel showed the limit only while the battery was holding at it. He asked for the control inside Omarchy's own battery widget, not a second widget, and without anything an Omarchy update would undo or that would hold the widget back from updates.

## Cause
Missing feature. `charge_control_end_threshold` is writable by root only, and `/usr/local/bin/m5pro-charge-limit` already takes any value from 50 to 99, 100 and `full`; nothing in the shell called it with a value other than 80, 100 or `full`.

## Fix
A user plugin, `rolo.power`, takes the place of `omarchy.power` in the bar (one battery icon, same panel, same `omarchy.power` IPC target). It does not copy the stock panel: its entry file subclasses the packaged `Panel.qml` through a symlink (`stock -> /usr/share/omarchy/shell/plugins/panels/power`), so the panel is whatever the installed Omarchy ships. On top of that it adds one section at the bottom of the panel, "Charge limit":

- a slider from 50 % to 100 % (100 % reads "Off"), 1 % steps by drag and 5 % by wheel; a drag or a wheel run becomes one write, 700 ms after the last change;
- a line that says where charging stops and resumes, read from sysfs and `/etc/udev/macsmc-battery.conf` every 5 s while the panel is open;
- a "Charge to 100% once" button (`m5pro-charge-limit full`), which turns into "Back to N% now" while that one-time charge runs.

Writes go through `m5pro-charge-limit`: first `sudo -n` (works only if a sudoers rule allows that command without a password; none is installed), otherwise `pkexec`, which raises the desktop's polkit prompt. Only an integer 50-100 or the word `full` is ever passed, as an argv element.

The section is parented into the stock panel's content column when the panel loads its content. If a later Omarchy changes that layout, the section is left out with one warning in the shell log and the stock panel works as shipped.

Two things found on the way, both in this shell (quickshell 0.3.2 with `//@ pragma OmarchyLoadPatch`):

1. Importing the stock panel's directory by its own path (`import "file:/usr/share/omarchy/shell/plugins/panels/power" as Stock`, or a relative path to it) fails with `Type Stock.Panel unavailable` / `InfoLabel is not a type` whenever the stock `Panel.qml` was loaded before the wrapper. Reproduced in a windowless scratch quickshell with a copy of the shell tree; it does not happen without the pragma, nor in plain Qt. Importing the same directory through a symlink inside the plugin works in every load order.
2. With `QS_DISABLE_FILE_WATCHER=1`, the running shell kept the first content it had read of a plugin file: edits to an entry file that had failed to load, and a renamed entry file ("File name case mismatch"), were only picked up after `omarchy-restart-shell`.

Commands, in order: created `~/.config/omarchy/plugins/rolo.power/`, `omarchy-shell shell rescanPlugins`, `omarchy-plugin-enable rolo.power` (it swaps the bar entry because the manifest says `clonedFrom: omarchy.power`), `omarchy-restart-shell` once. No package, no root change, nothing under `/usr/share/omarchy` edited.

## Files changed
- `~/.config/omarchy/plugins/rolo.power/` (new): `Power.qml`, `ChargeLimit.js`, `manifest.json`, `i18n/en.json`, `tests/test_charge_limit.js`, and the symlink `stock -> /usr/share/omarchy/shell/plugins/panels/power`. Copies in [files/2026-11-27-power-charge-limit/](files/2026-11-27-power-charge-limit/) (the symlink is not copied).
- `~/.config/omarchy/shell.json` (backup `shell.json.pre-charge-limit-panel`):

```diff
       "right": [
 ...
-          "id": "omarchy.power"
+          "id": "rolo.power"
```

## Verified
- `node tests/test_charge_limit.js`: ok (parsing, the full-once state, clamping, the argument filter).
- After `omarchy-restart-shell`: no `rolo.power` warning in the shell log; `omarchy-shell omarchy.power open` opens the panel; a screenshot showed the stock sections followed by "Charge limit", slider at 80 %, "Charging stops at 80% and resumes at 75%.", and the button.
- Rolando then moved the slider himself: the journal shows `pkexec ... m5pro-charge-limit 99` and `... 100` after the polkit prompt, and afterwards end=100 start=100, CHARGE_CONTROL_END_THRESHOLD=100; the panel read "Off" and "No limit: the battery charges to 100%.".
- Not checked: the "Charge to 100% once" button, the look of the busy and failed states, a vertical bar, a right-to-left language.

## Rollback
```bash
cp -a ~/.config/omarchy/shell.json.pre-charge-limit-panel ~/.config/omarchy/shell.json
rm -r ~/.config/omarchy/plugins/rolo.power
omarchy-restart-shell
```
If an Omarchy update ever moves or renames the stock Power panel, the widget will not load and the battery icon will be missing: the first line above alone brings the stock widget back.
