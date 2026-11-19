# Bar declutter, Pointer panel redesign, live agent sessions in My Agents (2026-11-19)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/52     Kernel: 7.3.0-gc1e08542a544

## What broke
Not a bug: Rolando asked for desktop polish in one session.

- The Pointer & Trackpad panel (`rolo.pointer`) was cramped: two segmented controls stacked beside the title, a
  four-line technical profile note, four 54 px toggle boxes, and no way to see which values differed from the profile.
- The bar's right side carried widgets he wanted gone: `rolo.cds` (a session list he would rather open as an app),
  Pointer and KM Link.
- My Agents (`rolo.agents`) showed usage and limits only. He wanted to see live coding-agent sessions, know when one
  needs him, and answer it from the panel: "if an agent needs me, I can see it from the menu bar item, and if I click on
  it we open a larger pop-out window that allows me to see that terminal session and I can respond to it." Clicking a
  session first went through the cds TUI; Claude Desktop sessions should just go to Claude Desktop's window.

## Cause
Design, not a fault. Facts that shaped the implementation:

- The shell's per-plugin hot reload re-registered `rolo.pointer` but kept serving the cached component (no load error
  in the Quickshell log); `omarchy restart shell` was needed for each QML change to show.
- Local Claude Code CLI sessions run in plain Alacritty windows. Each writes `~/.claude/sessions/<pid>.json` with its
  pid, session id, cwd and `status` (`busy`/`waiting`/`idle`), so the window is found by walking the pid's parents
  to a Hyprland client. Alacritty has no API to read its screen or inject input: the conversation comes from the
  session's transcript (`~/.claude/projects/*/<id>.jsonl`), and a reply needs keyboard focus (`wtype`).
- Herdr terminals (here and on the Studio) can be read and typed into with `hc read`, `hc send`, `hc keys`.
- Claude Desktop and profile sessions have no input path from this machine; cds can read their transcripts on the
  machine that has them (`hc exec --on <machine> -i python3 -` with cds's own source).

## Fix
1. **Pointer panel** (`~/.config/omarchy/plugins/rolo.pointer/Panel.qml`, rewritten): Omarchy `PanelHero` header with the
   macOS/Custom profile switch on its trailing edge (the long profile note moved to the option's tooltip); a centered
   Trackpad / Mouse & cursor tab row; section headers (Scrolling, Tracking, Clicking & gestures; Tracking, Scrolling,
   Cursor); one inline `SliderRow` component for every slider, whose value turns the accent colour when it differs from the
   profile default, with a per-slider reset arrow and right-click reset; compact `SwitchRow` rows instead of `Toggle`
   cards; cursor size as a notched slider; footer hint plus a "Reset all" button that greys out at defaults.
   `apply-pointer.py` returns the active profile's defaults with `--read` (one line). The modified-count badge first
   added to the header was removed at Rolando's request.
2. **cds as an app**: `rolo.cds` removed from `bar.layout.right` in `~/.config/omarchy/shell.json` (plugin files kept).
   New launcher `~/.local/share/applications/cds.desktop` (`omarchy launch or focus tui --app-id=cds cds`, with Colony and
   Vault desktop actions) and icon `~/.local/share/icons/hicolor/256x256/apps/cds.png` (ImageMagick: the Nerd Font
   terminal glyph on a rounded square).
3. **Pointer and KM Link** moved into `bar.layout.tray` (the tray drawer). Later the same day other sessions changed the
   bar again (Pointer back in `right`, KM Link removed by its own Quit menu, `omarchy.audio` replaced by `rolo.audio`);
   that layout is theirs and is not documented here.
4. **My Agents, live sessions** (`~/.config/omarchy/plugins/rolo.agents/`):
   - `scripts/live_sessions.py` (new): `list` merges local Claude Code windows (registry + window lookup; skipped when a
     Herdr client is in the parent chain), Herdr terminals (`hc ls/get --json`) and the remaining busy/waiting rows of
     `cds --list` (Desktop, profiles), de-duplicated against Herdr titles. `read` returns a Herdr screen (`hc read`), a
     local conversation (transcript tail; runs of tool calls folded into one line; an unanswered tool call marked
     pending; slash-command wrappers shown as `/name args`), or a Desktop/profile conversation through cds's
     `read_preview` on the owning machine. `send`/`keys` use `hc send`/`hc keys` for Herdr, and for a local window
     focus it (`hl.dsp.focus`) then `wtype` the text and Return. `focus` raises a local window, attaches a Herdr
     terminal in its own Alacritty (`omarchy-launch-or-focus-tui --app-id=herdr-<addr> hc attach <addr>`), or for a
     Claude Desktop row runs `omarchy-launch-or-focus com.anthropic.Claude "uwsm-app -- claude-desktop --disable-gpu"`
     (the GPU flag stays, see tracker #36). Every argument goes as an argv entry, never through a shell; addresses,
     pids, keys and session ids are pattern-checked.
   - `Panel.qml`: an "Active now" section above the providers (up to 6 rows, waiting first, pulsing dot while working,
     "needs you" in the accent colour, machine or workspace number, hover button to go to the terminal, "+N more in
     cds"); the bar icon lights while any session is live and shows the number waiting; a cds button in the hero; the
     list refreshes every 30 s and on opening; IPC `omarchy-shell omarchy.agents openWaiting` opens the session that
     needs you. Clicking a row opens the pop-out, except Claude Desktop rows, which go to Claude Desktop's window.
   - `SessionWindow.qml` (new): an `OverlayWindow` with a scrim and a centred card (fade + scale from 0.96, 180 ms in,
     120 ms out, `Style.duration`). Header with state, provider, machine/workspace and folder, "Go to terminal" (or "Open
     in cds"), close. Body: the Herdr screen (polled every 1.5 s) or the conversation as chat (2.5 s local, 8 s remote),
     kept scrolled to the end unless scrolled up. Footer: answer keys (1 Yes, 2 Always, 3 No, Esc, Enter) when the
     session is waiting or is a Herdr screen, and a reply field. A local reply closes the pop-out first, since the window
     must hold the keyboard. Desktop/profile sessions are read-only with a note saying where to answer.
   - `i18n/en.json`: the new strings.
5. `omarchy restart shell` after each QML change (see Cause).

## Files changed
Copies and diffs are in [`files/2026-11-19-agents-live-sessions/`](files/2026-11-19-agents-live-sessions/):

- `~/.config/omarchy/plugins/rolo.pointer/Panel.qml` -> rewritten, `rolo.pointer-Panel.qml.diff` (from the
  `.pre-ui-refresh` backup; it also contains the G502 X tab added afterwards, documented in `2026-11-19-g502-hidpp.md`)
- `~/.config/omarchy/plugins/rolo.pointer/apply-pointer.py` -> `rolo.pointer-apply-pointer.py.diff`
- `~/.config/omarchy/plugins/rolo.agents/Panel.qml` -> `rolo.agents-Panel.qml.diff` (from `.pre-cds-sessions`)
- `~/.config/omarchy/plugins/rolo.agents/i18n/en.json` -> `rolo.agents-i18n-en.json.diff`
- `~/.config/omarchy/plugins/rolo.agents/SessionWindow.qml` (new) -> `SessionWindow.qml`
- `~/.config/omarchy/plugins/rolo.agents/scripts/live_sessions.py` (new) -> `live_sessions.py`
- `~/.local/share/applications/cds.desktop` (new) -> `cds.desktop`
- `~/.config/omarchy/shell.json` -> `bar.layout.right` without `rolo.cds` (backup `shell.json.pre-cds-app`)

## Verified
- Pointer panel: screenshots of both tabs after a shell restart; changed values shown in the accent colour; Quickshell
  log clean. Rolando reviewed it ("this looks great") and asked for the change-count badge to go, which was done.
- Bar: cds icon gone after the `shell.json` edit (hot reload); launcher entry and icon installed; not launched from the
  launcher.
- My Agents: screenshot with "Active now" listing 1 waiting and 4 working sessions across this machine and the Studio, and
  the bar badge showing 1.
- Pop-out, opened with `omarchy-shell omarchy.agents openWaiting`: a local session's conversation rendered as chat; a
  Claude Desktop session on the Studio read through cds in about 1 s.
- Local reply path: `type_into` on a scratch Alacritty running `cat > file` wrote "hello from agents" plus Enter to
  the file. Nothing was sent to a real session or the Studio.
- Claude Desktop row: `live_sessions.py focus other ...` moved focus to the Claude Desktop window on workspace 1.
- Not checked by hand: clicking rows with the mouse, Herdr replies, the tray drawer.

## Rollback
```bash
P=~/.config/omarchy/plugins
cp -a $P/rolo.pointer/Panel.qml.pre-ui-refresh $P/rolo.pointer/Panel.qml      # also drops the later G502 X tab
cp -a $P/rolo.pointer/apply-pointer.py.pre-ui-refresh $P/rolo.pointer/apply-pointer.py
cp -a $P/rolo.agents/Panel.qml.pre-cds-sessions $P/rolo.agents/Panel.qml
cp -a $P/rolo.agents/i18n/en.json.pre-cds-sessions $P/rolo.agents/i18n/en.json
rm $P/rolo.agents/SessionWindow.qml $P/rolo.agents/scripts/live_sessions.py
rm ~/.local/share/applications/cds.desktop ~/.local/share/icons/hicolor/256x256/apps/cds.png
omarchy bar put rolo.cds --section right      # put cds back on the bar
omarchy restart shell
```
