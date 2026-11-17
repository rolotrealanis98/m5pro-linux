# Second Claude desktop profile for a work account (2026-11-17)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/48     Kernel: 7.3.0-gec5f49f167be

## What broke
Not a breakage, a setup request: run a second Claude desktop (`claude-desktop` 5.11492.5-1) signed into a different
(work) account next to the personal one.

- Launching `claude-desktop` again only hands off to the running instance (Electron single-instance lock in the profile
  folder) and focuses its window.
- `CLAUDE_USER_DATA_DIR=<dir>` is ignored: the app logs "CLAUDE_USER_DATA_DIR is set and signed builds ignore it" and
  nothing was created in `<dir>`.

## Cause
- The profile (cookies, sign-in, settings) and the single-instance lock both live in Electron's `userData` folder
  (`~/.config/Claude`). Chromium's `--user-data-dir=<dir>` switch moves both: tested, a second process came up with its
  own window and its own `SingletonLock`/`config.json` in `~/.config/Claude-Work`.
- Sign-in with Google or a magic link returns to the app through a `claude://` deep link (`claude://.../login/...`). By
  default the handler is `com.anthropic.Claude.desktop`, which forwards the link to the personal instance, and the app
  drops a Google callback "that does not answer a sign-in this app started". So the work instance needs the link routed
  to it, or sign-in never completes.
- Chromium rewrites its process title, so `/proc/<pid>/cmdline` is one space-joined string, not NUL-separated argv
  (first router draft matched with `grep -x` per argument and picked the wrong profile; fixed before use).

## Fix
1. `~/.local/bin/claude-work`: wrapper that runs `/usr/bin/claude-desktop --disable-gpu
   --user-data-dir="$HOME/.config/Claude-Work" "$@"`. `--disable-gpu` is the GPU-recovery stopgap for Electron apps
   (issue #36); the user flags file `~/.config/claude-desktop-flags.conf` is empty, so the flag is passed explicitly.
2. `~/.local/share/applications/claude-work.desktop`: launcher entry "Claude (Work)" with the New Chat / New Claude Code
   Session actions, no `MimeType` (it must not claim `claude://`).
3. `~/.local/bin/claude-url-router` + `~/.local/share/applications/claude-url-router.desktop` (`NoDisplay`): handler for
   `x-scheme-handler/claude`. It asks Hyprland for the `com.anthropic.Claude` window with the lowest `focusHistoryID`,
   reads that pid's command line, and opens the link in the work profile if it carries
   `--user-data-dir=~/.config/Claude-Work`, otherwise in the personal one (with `--disable-gpu`).
4. `xdg-mime default claude-url-router.desktop x-scheme-handler/claude`; `update-desktop-database ~/.local/share/applications`.
   `~/.config/mimeapps.list` backed up to `mimeapps.list.pre-claude-work` first.
5. `mkdir -m 700 ~/.config/Claude-Work`.

Not changed: the package's desktop entry, the personal profile, `~/.claude` (the work instance's Claude Code sessions use
the same `~/.claude` config, skills and plugins as the personal one, so this machine's CLAUDE.md rules still apply there;
the account/token is the work instance's own).

## Files changed
New files, copies under [`files/2026-11-17-claude-work-profile/`](files/2026-11-17-claude-work-profile/) (home path
written as `~`):

- `~/.local/bin/claude-work` -> [`claude-work`](files/2026-11-17-claude-work-profile/claude-work)
- `~/.local/bin/claude-url-router` -> [`claude-url-router`](files/2026-11-17-claude-work-profile/claude-url-router)
- `~/.local/share/applications/claude-work.desktop` -> [`claude-work.desktop`](files/2026-11-17-claude-work-profile/claude-work.desktop)
- `~/.local/share/applications/claude-url-router.desktop` -> [`claude-url-router.desktop`](files/2026-11-17-claude-work-profile/claude-url-router.desktop)

`~/.config/mimeapps.list`:

```diff
--- ~/.config/mimeapps.list.pre-claude-work
+++ ~/.config/mimeapps.list
@@ -19,3 +19,4 @@
 x-scheme-handler/claude-cli=claude-code-url-handler.desktop
 x-scheme-handler/superwhisper=superwhisper-url.desktop
 x-scheme-handler/codex=chatgpt.desktop
+x-scheme-handler/claude=claude-url-router.desktop
```

## Verified
- Second instance launched with `--user-data-dir`: separate process and window (`hyprctl clients` shows two
  `com.anthropic.Claude` clients, different pids), profile files created in `~/.config/Claude-Work`, personal instance
  untouched.
- No `aurora: GPU work of a client failed` lines in `dmesg` after the launch.
- `xdg-mime query default x-scheme-handler/claude` -> `claude-url-router.desktop`; `desktop-file-validate` passes (one
  hint about two main categories, same as the package entry).
- Router decision dry-run against both live pids: work pid -> WORK, personal pid -> PERSONAL.
- Not yet verified: an actual work-account sign-in through the router (Rolando to do).

## Rollback
```bash
rm ~/.local/bin/claude-work ~/.local/bin/claude-url-router \
   ~/.local/share/applications/claude-work.desktop ~/.local/share/applications/claude-url-router.desktop
cp -a ~/.config/mimeapps.list.pre-claude-work ~/.config/mimeapps.list
update-desktop-database ~/.local/share/applications
rm -rf ~/.config/Claude-Work        # deletes the work sign-in and its local data
```
