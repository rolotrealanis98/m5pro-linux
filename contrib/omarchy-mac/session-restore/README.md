# Login Items & Restore

A searchable app (type "login" or "restore" in Walker) that does two jobs on the MacBook's Omarchy desktop:

1. **Login items**: one list of everything that starts with the session, each with a switch, marked **App** or **Background**.
2. **Restore after a reboot**: every window comes back on its workspace (floating windows at their old position and size) and
   every terminal AI agent is resumed into its exact previous session. Hyprland has no session management, and Omarchy
   starts nothing but its own shell at login, so this is a small user-level service pair plus the app.

Hyprland 0.57.1 (Lua config), no uwsm: the desktop starts from the tty2 autologin (`hypr-session`) and `graphical-session.target`
is active, so the units hang off that target like the other `m5pro-*` services.

## What it does

**Saver** (`m5pro-session-save`, user service `m5pro-session-save.service`): every 60 s, and once more at session stop or shutdown
(`ExecStop`), it writes `~/.local/state/m5pro-session/latest.json` (atomic rename) plus the last five history files (a new history
file only when the layout changed). Per window: class, title, workspace id and name, monitor, floating, position and size,
fullscreen, launch command, cwd, and for terminals the agent and session id. It never replaces a good snapshot with a bad one:

- nothing is written while a restore runs, nor until the login restore has run (while automatic restore is on);
- an empty desktop is never saved;
- in the first 10 minutes after login or a restore, and for the final save at shutdown, a snapshot with far fewer windows
  (under 60 %) than the last good one is refused (the compositor tearing down looks exactly like that).

**Restorer** (`m5pro-session-restore`, user service `m5pro-session-restore.service`, runs once per login): waits for the
compositor and the Omarchy shell, then starts each app silently on its saved workspace
(`hl.dsp.exec_cmd(cmd, { workspace = "N silent" })`) and fixes floating geometry and fullscreen once the window exists
(`hl.dsp.window.float/resize/move/fullscreen`, `hl.dsp.window.move({ workspace, follow = false })`). A single-instance or
multi-window app (Chrome, Electron) is launched once; every further window is placed as its `openwindow` event arrives on the
Hyprland event socket, matched by class and title, then by order. Apps that a login item already starts are not launched
again, but their windows are put on their saved workspaces when they show up (it waits up to 150 s for a slow app). Apps that are already open are left alone, so
"Restore now" on a live desktop only starts what is missing. Terminals: `alacritty --working-directory DIR -e bash -lc '<agent
resume>; exec bash'`, so the shell stays if the agent exits; a terminal without an agent reopens its shell in the same cwd.
Terminals with their own class (Omarchy's `org.omarchy.agent`) keep it, a TUI the terminal was started for (`-e btop`) is
started again.

**VM windows are skipped.** Windows hosted by the muvm VM (Steam, its web helper, games: class `steam`, `steam_app_*`, `muvm`, or a launch command or process ancestry running `muvm`, `m5pro-muvm-gpu` or `m5pro-steam`) are neither saved nor replayed, including from snapshots saved before this rule: a relaunched VM holds `/boot` open and blocks test boots.

`m5pro-session-restore --dry-run` prints the plan, `--dry-run --fresh` prints what a reboot would do. Automatic restore has a switch
in the app (default on); off means the login service does nothing.

**How each agent's session is found** (terminal window pid, then its process tree under /proc, then the agent's own store):

| Agent | Session id from | Resume | Tested on the Mac |
|---|---|---|---|
| Claude Code | `~/.claude/sessions/<pid>.json` (`sessionId`, `cwd`) of the running `claude`; falls back to `--resume <id>` on its command line. An empty session (no transcript yet) restarts fresh in the same folder | `claude --resume <id>` | yes: running ones read, a resumed old session round-tripped |
| Codex | `~/.codex/logs_2.sqlite`: the newest `thread_id` logged by the TUI pid or its `app-server` child (`process_uuid` is `pid:<pid>:...`); else `resume <id>` on the command line; else the newest thread for the cwd in `state_5.sqlite` | `codex resume <id>` | yes: a resumed thread round-tripped |
| Antigravity CLI (`agy`) | the running CLI holds `~/.gemini/antigravity-cli/presence/<id>.lock` and `conversations/<id>.db` open: read from `/proc/<pid>/fd`; else `--conversation <id>`; else the newest `history.jsonl` entry for the cwd | `agy --conversation <id>` | yes: a resumed conversation round-tripped |
| OpenCode | `-s/--session <id>` on its command line; else the newest top-level, non-archived session for the cwd in `~/.local/share/opencode/opencode.db` (`session_v2`) | `opencode --session <id>` | no: the Mac has no OpenCode sessions yet (code and queries written against the real schema) |
| Gemini CLI | no per-process mapping exists | `gemini --resume latest` (the latest session of that folder) | no: not installed (this Mac has Antigravity, which writes under `~/.gemini`) |

Carried flags (whitelist): permission/model/effort flags such as `--dangerously-skip-permissions`, `--permission-mode`,
`--model`, `--effort`, `--full-auto`, `--sandbox`.

**Login items** (page 2): the app lists and switches

- XDG autostart: `~/.config/autostart/*.desktop` and `/etc/xdg/autostart/*.desktop`. A system entry is never edited: switching it
  off writes `~/.config/autostart/<same name>.desktop` with `Hidden=true` (marked `X-M5PRO-Override=true`); switching it on removes that copy.
  A user entry gets `Hidden=true` set or removed in place. Entries made for other desktops (GNOME-only) sit in a collapsed group.
- `o.launch_on_start("...")` lines in `~/.config/hypr/autostart.lua`: off prefixes that one line with `-- m5pro-disabled: `, on removes
  the prefix. Nothing else in the file is touched. `m5pro-lock-at-login` is shown **locked** (Touch ID and lock-screen security:
  the lock screen is the only gate at boot).
- The owner's systemd user services: units in `~/.config/systemd/user/` and the ones enabled from there, plus `m5pro-*` and
  `aurora-*` units from `/usr/lib/systemd/user`, never stock systemd/Omarchy units. Off is `systemctl --user disable` (the running
  service keeps running until logout), on is `enable`. A switched-off unit keeps its row (its unit path is remembered in
  `~/.config/m5pro-session/login-units.json`). The two units of this item show as locked.
- **Add** (+ in the header) lists the installed apps; picking one writes a user autostart entry (marked `X-M5PRO-Added=true`, so the
  app can remove it again).

## Files

| Path in the repo (`home/` is the desktop user's home) | Installed as |
|---|---|
| `home/.local/lib/m5pro-session/m5pro_session.py` | `~/.local/lib/m5pro-session/m5pro_session.py`: all logic (snapshot, agent detection, plan, restore engine, login items) |
| `home/.local/bin/m5pro-session-save` | `~/.local/bin/m5pro-session-save` (`run`, `--once`, `--final`, `--print`) |
| `home/.local/bin/m5pro-session-restore` | `~/.local/bin/m5pro-session-restore` (`--auto`, `--dry-run`, `--fresh`, `--snapshot FILE`) |
| `home/.local/bin/m5pro-session-app` | `~/.local/bin/m5pro-session-app`: GTK4 + libadwaita (Omarchy's GTK theme applies) |
| `home/.config/systemd/user/m5pro-session-{save,restore}.service` | `~/.config/systemd/user/`, both `WantedBy=graphical-session.target` |
| `home/.local/share/applications/org.m5pro.SessionRestore.desktop`, `home/.local/share/icons/.../org.m5pro.SessionRestore.svg` | what Walker finds |
| `tests/test_core.py` | offline unit tests: `python3 -m unittest discover -s tests` |

State stays on the Mac and never goes in the repo: `~/.local/state/m5pro-session/` (snapshots with window titles, paths and
session ids, mode 0600) and `~/.config/m5pro-session/` (`config.json`: `auto_restore`, `excluded`).

## Install and undo

```
sudo bash install.sh rolo                  # as root, with the desktop user; --no-start installs without starting the saver
sudo bash install.sh --uninstall rolo      # removes the app, both services and the scripts; settings and snapshots stay
```

The saver starts at once; the restore service runs at the next login (starting it at install time would relaunch apps). Without
the install script: delete the files in the table, `systemctl --user disable --now m5pro-session-save m5pro-session-restore`.

## Limits

- Tiled windows come back in saved order on the saved workspace, but split ratios and the exact tile positions are not restored.
- Window-to-saved-window matching for apps that open several windows is by class, then title, then order; if an app changes
  its class after start, those windows stay where Hyprland puts them. Apps that never produce a window within 25 s are given up on.
- The per-app excludes are keyed by class for apps, by agent for terminals (`agent:claude` skips every Claude Code terminal,
  `terminal:shell` every plain terminal); there is no per-session switch.
- One terminal process with several windows (kitty/foot server mode) cannot be mapped to its agents and restores as plain shells.
- Chrome's own session restore decides which tabs come back; this only puts its windows on their workspaces.
- Closing a restored Codex terminal leaves Codex's own `app-server` helper running (Codex's behavior, not ours).
- Tested live on workspace 5 (launch, placement, adoption, agent round trips) and once on a real boot: the login service ran by
  itself, resumed the saved Claude Code sessions and put windows on their workspaces. At that shutdown the final save found the
  compositor already gone and correctly kept the last good snapshot (the saver cannot rely on `ExecStop` seeing a live desktop,
  hence the every-60-s saves).
- Debug: `M5PRO_SESSION_SCREENSHOT=/path.png [M5PRO_SESSION_PAGE=login] m5pro-session-app` renders the window to a PNG and exits.
