# plugin-rolo-image-picker

Omarchy shell plugin that replaces `omarchy.image-picker` with a version that works under software rendering.

- Scope: `generic`. Status: installed. Upstream: Omarchy itself (software-render fix for the stock picker).
- Install: `sudo contrib/omarchy-mac/install-item.sh --user NAME plugin-rolo-image-picker`. Needs `rolo.image-picker` in `plugins` and `omarchy.image-picker` in `disabledPlugins` of `shell.json`. Rename the `rolo.` id before proposing it upstream.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove plugin-rolo-image-picker` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
