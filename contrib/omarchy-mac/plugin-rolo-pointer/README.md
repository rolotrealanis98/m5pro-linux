# plugin-rolo-pointer

Omarchy shell panel ("Pointer" in the bar) that writes `~/.config/hypr/pointer-tuning.lua` from
`~/.config/hypr/pointer-tuning.json`: the single source of trackpad, mouse, wheel and cursor settings on this Mac.

- Two profiles, switched at the top of the panel:
  - **macOS**: the owner's macOS 27.3 settings through Apple's own curves (trackpad 0.875 / scroll 0.4412, G502 mouse
    2.0 / wheel 0.75, natural scrolling, no tap, sizes matched to macOS's "looks like" width, per-app scroll
    normalisation, 4-finger swipe and pinch). Mapping: `../macos-feel/README.md`.
  - **Custom**: the hand-tuned values (Apple trackpad curve with tracking/gain, adaptive or flat mouse).
  Each keeps its own values; the sliders edit the active one. Switching runs `~/.local/bin/macos-feel desktop on|off`
  (text size, browser wheel animation) when it is installed.
- Needs `~/.config/hypr/trackpad/curves.lua` (`contrib/validated/desktop/trackpad/`).
- Scope: `t6050`. Status: installed. Upstream: Omarchy itself, as an optional plugin.
- Install: `sudo contrib/omarchy-mac/macos-feel/install.sh --user NAME [--macos]` (plugin, curves, macos-feel, JSON
  conversion, one `hyprctl reload`), or the plugin alone with `sudo contrib/omarchy-mac/install-item.sh --user NAME plugin-rolo-pointer`.
  Add `rolo.pointer` to the bar layout in `shell.json`. A changed `Panel.qml` shows at the shell's next start (or
  `omarchy-shell shell rescanPlugins`).
- Undo: `macos-feel/install.sh --user NAME --uninstall`, or `install-item.sh --remove plugin-rolo-pointer`.
- CLI: `apply-pointer.py --read | --write JSON | --profile macos|custom | --reset | --generate`.
