---
name: m5pro
description: >
  Use for ANY Omarchy, Hyprland, desktop, audio, network, display or app task on this MacBook (the J716s, MacBook Pro 16-inch
  M5 Pro running Omarchy on Arch ARM with a hand-built boot chain), and for EVERY crash diagnosis here: a "Process crashed"
  notification, omarchy agent crash, coredumpctl, segfault, SIGSEGV, SIGABRT, core dump, Hyprland or quickshell crashed,
  safe-mode screen, black or missing window, no sound, no wallpaper, Wi-Fi or Bluetooth problem, a package to install. Loads
  the machine brief with the hard rules (never touch /boot, kernel, firmware, the GPU session files, the speaker ceiling;
  no reboot or `omarchy update` without asking Rolando) and the workflow that lands every fix in the shared repos and tracker.
  Use together with the omarchy and diagnose-crash skills, never instead of the brief.
---

# m5pro: working on the J716s

This machine is not stock Omarchy: the GPU, display, audio and boot paths are custom and fragile. Stock advice (update
Omarchy, reinstall configs, rebuild the initramfs, switch GL drivers, restart the session) can brick the boot or cost Rolando
his running work.

## Step 0: load the brief (always, before any change)

Read `~/.claude/skills/m5pro/BRIEF.md` in full (it sits next to this file). Its **HARD RULES** and "One owner at a time"
sections bind this whole session. If a task needs one broken, stop and ask Rolando in chat.

## Fix workflow

1. **Preflight.** `uname -r`; `ls /run/m5pro-studio-busy` (if present, the Studio session is mid-run: stop, tell Rolando);
   `git -C ~/Work/m5pro-linux pull --rebase`; `git -C ~/Work/m4-m5-linux pull --rebase`.
2. **Check the tracker and the notes for the topic first.**
   `gh issue list -R rolotrealanis98/m4-m5-linux --state all --search "<keywords>" --limit 20`, then
   `rg -n -i "<keywords>" ~/Work/m5pro-linux/contrib/validated/desktop ~/Work/m5pro-linux/contrib/validated/integration/RESULTS.md ~/Work/m4-m5-linux/machines/j716s`.
   An open issue: comment on it and work under it. A closed one: read its fix doc; this may be a regression, say so.
3. **Open an issue** if there is none (`machine:j716s` + `in-flight`; command patterns in the brief).
4. **Look at the real thing before deciding.** Read the actual config, logs and process command lines
   (`journalctl --user -b`, `dmesg --time-format iso`, `coredumpctl`, `hyprctl`, `nmcli`, `wpctl`); do not reason from stock
   Omarchy defaults. For `~/.config` edits follow the `omarchy` skill's guides (Hyprland, theming, hooks). Back up each file
   first: `cp -a <file> <file>.pre-<slug>`.
5. **Fix the smallest thing that explains the evidence**, at user level where possible (`~/.config/...`, an app's flags
   file). Packages: `sudo pacman -S --needed <pkg>` only after reading the transaction (brief, "Packages"). Anything that
   needs root: hand Rolando the exact command. Anything in rules 1-9: stop and ask.
6. **Verify.** Re-run the thing that failed and look for new errors afterwards (`journalctl --user -b -p warning`,
   `dmesg --time-format iso | tail`). What only a person can judge (picture, sound, feel) is verified by asking Rolando;
   write "seen by Rolando" only when he said so. Never play audio on the speakers without his yes.
7. **Document.** `contrib/validated/desktop/omarchy-fixes/<date>-<slug>.md` in `~/Work/m5pro-linux` with the sections and
   the diff of every changed file (brief, "How results land" part 1). Run
   `python3 ~/Work/m4-m5-linux/tools/privacy_scan.py <files>` first.
8. **Commit and push to `main`** (identity Rolando Trevino, **no AI trailers**, no force push), then copy the full commit
   sha into the issue.
9. **Tracker.** Close the issue with the fix-doc link, or relabel it (`attended`, `blocked`, `upstream`, `help-wanted`). Only
   if a feature's status actually changed because you ran it here today: result file + `machine.yaml` cell, `python3 tools/gen.py`,
   `make check`, push (brief, part 3).
10. **Tell Rolando**, result first, a few lines: what was wrong, what changed (file paths), what he must do or check.
   Say plainly what is unverified.

## Crash diagnosis checklist (the "Process crashed" toast, `omarchy agent crash <pid>`, or "why did X die")

The prompt arrives from Omarchy and names the `diagnose-crash` skill. Use it for the method (it is read-only: a diagnosis
does not fix or tidy) and use this checklist for what is specific to this machine. Both apply. Do not change the system
during the diagnosis; fixes follow the fix workflow above, after Rolando agrees.

1. **Facts.** `coredumpctl info <pid>` (command line, signal, time, backtrace), `coredumpctl list --no-pager | tail -20`
   (a cluster of Hyprland SIGABRT, quickshell/hyprland-dialog SEGV within minutes is one event, not several), `uptime`,
   `free -h`.
2. **First, the known crash class.** Before looking at any config:
   ```bash
   dmesg --time-format iso | grep -E "GPU work of a client failed|recovery fault" | tail -30
   journalctl -k -b -1 --no-pager 2>/dev/null | grep -E "GPU work of a client failed|recovery fault" | tail -10   # previous boot
   ```
   Compare each line's timestamp (same clock as `coredumpctl`, UTC on this machine; check `date`) with the crash time. A hit
   within about a minute before the crash means the class applies. Read the `client <name>[pid]` in those lines: that is the
   app that faulted the GPU.
3. **The class signature** (any two of these, plus the dmesg lines, settle it): clients named `chromium`, `chrome`,
   `claude-desktop` or another Electron app; a Hyprland line `ENODATA` in the same dmesg group; the coredump of a zink process
   (Hyprland, `hyprland-dialog`) with `dri_create_fence_fd` in the backtrace; Hyprland aborting right after, then the
   respawned Hyprland failing EGL initialisation (`~/.cache/hyprland-tty2.log`, `$XDG_RUNTIME_DIR/hypr/*/hyprland.log`) or
   the safe-mode screen; quickshell dying with it.
4. **If it matches:** say so first; this is the GPU driver's recovery taking the compositor down, not Omarchy or the user's
   config, so do **not** edit Hyprland or Omarchy config. Then check the stopgap for the faulting app: its running command
   line (`ps -o pid,args -C <comm>`) and flags file (`~/.config/chromium-flags.conf`; Electron apps read their own, e.g.
   `~/.config/claude-desktop-flags.conf`) must contain `--disable-gpu`. A faulting client without it is the finding; the fix
   (adding the flag to that app's own flags file, user level) is allowed but follows the fix workflow, and restarting the app
   is Rolando's call. Do **not** restart the session (`getty@tty2`) yourself, even from the safe-mode screen: tell Rolando.
5. **Record it.** `gh issue list -R rolotrealanis98/m4-m5-linux --state all --search "GPU recovery"`; add a scrubbed comment
   (time, client name, which stopgap was missing) to the existing issue instead of opening a new one. A new signature (a
   different faulting client class, a crash without the dmesg lines, a different backtrace) gets its own issue.
6. **If it does not match**, continue with the `diagnose-crash` method (memory, journal timeline, package updates, thread
   stacks, debuginfod symbolisation) and then look at the config; check `~/Work/m4-m5-linux/machines/j716s/machine.yaml`
   for a feature that is known broken or untested around the crashing component (for example `gpu.gl-native`, the DCP,
   Thunderbolt) before blaming anything else. Never invent symbol names for unsymbolised frames.
7. **Report** the four things `diagnose-crash` asks for, plus: class matched or not, the faulting client, and whether it
   will recur. Delete the core you extracted (it is process memory; never commit it or paste more than the trimmed backtrace
   lines, and run the privacy scan on anything written to the repos). Do not offer `omarchy-crash-mute` for Hyprland,
   quickshell or start-hyprland, and never file anything upstream (rule 10).
