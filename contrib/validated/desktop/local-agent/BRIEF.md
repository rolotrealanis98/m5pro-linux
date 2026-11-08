# J716s local-agent brief

For a Claude Code agent that starts cold on the MacBook itself. Read all of it, the HARD RULES first. Source of truth:
`contrib/validated/desktop/local-agent/BRIEF.md` in `rolotrealanis98/m5pro-linux` (installed copy:
`~/.claude/skills/m5pro/BRIEF.md`; if the two differ, the repo wins). Facts below are as of 2026-11-08; verify anything
that matters with the live machine (`uname -r`, `pacman -Q`, `systemctl`) before relying on it.

## HARD RULES

These hold for every session on this machine, including crash diagnoses started from the "Process crashed" toast.
If a task seems to need breaking one, stop and ask Rolando in chat. Do not look for a way around it.

1. **Never touch the boot chain.** Nothing under `/boot` (the ESP, mounted by systemd automount), no `boot.bin*`, no
   m1n1, no Limine, no U-Boot, no stage-1, no initramfs, no kernel or kernel-module packages, no device tree, no
   firmware (`/usr/lib/firmware`, `linux-firmware*`, the Apple firmware under `/usr/lib/firmware/apple`).
2. **Never touch the GPU/session plumbing**, even to "fix" it:
   - `/etc/mesa-aurora/session.env` and its siblings (`session.env.zink`, `session.env.native-*`), `/opt/mesa-aurora*`
     (`mesa-aurora`, `mesa-aurora-gl`, `mesa-aurora-gl2`)
   - the two-card Hyprland launcher files: `~/.local/bin/hypr-session` (+ `.pre-dcp`), `/usr/local/bin/hypr-gpu-session`
     (+ `.pre-dcp`), `/usr/local/lib/hypr-cards.sh`, `/usr/local/bin/hypr-dcp-precheck`, `/usr/local/bin/hypr-dcp-verify`,
     `~/.config/hypr/m5pro.lua`, `~/.config/hypr/m5pro-dcp.lua`, the `require("hypr.m5pro")` / trackpad `dofile` lines at
     the end of `~/.config/hypr/hyprland.lua`, `~/.bash_profile` (tty2 autostart), the `getty@tty2` and `autovt@tty2`
     drop-ins under `/etc/systemd/system/`
   - the switch files `/etc/hypr-gpu-disable`, `/etc/hypr-dcp-disable`, `/etc/hypr-dcp-modifiers`, `/run/hypr-gpu`,
     `/run/hypr-dcp-trace` (do not create or remove them)
3. **Never touch the speaker safety chain:** the kernel's -30 dB speaker ceiling, `speakersafetyd` and its config
   (`/usr/share/speakersafetyd/apple/j716.conf`), the staged profile under `/usr/share/asahi-audio/j716/`, the J716
   WirePlumber fragments (`~/.config/wireplumber/wireplumber.conf.d/99-asahi-j716*.conf`), the UCM files. Do not raise
   any volume past what the user set, and never play audio through the speakers (even a test tone) unless Rolando is
   at the machine and said yes in chat.
4. **Never touch the systemd runtime watchdog:** `/etc/systemd/system.conf.d/m5pro-watchdog.conf` (and no other
   `system.conf.d` drop-in). With it, a stalled PID 1 resets the machine within 60 s: do not `SIGSTOP`/ptrace PID 1,
   and do not run `systemctl daemon-reexec`.
5. **Never touch the pacman guards:** `IgnorePkg` in `/etc/pacman.conf`, `/etc/pacman.d/hooks/00-m5pro-boot-guard.hook`,
   `/usr/local/sbin/m5pro-boot-guard`, Omarchy's `00-omarchy-update-guard.hook`. Never set `M5PRO_ALLOW_BOOT_PKGS=1`
   or `OMARCHY_ALLOW_DIRECT_PACMAN=1`.
6. **Never read, print, copy or commit NetworkManager's system connections** (`/etc/NetworkManager/system-connections/`:
   they hold the Wi-Fi passphrase), `~/.config/gh/`, `~/.claude/.credentials.json`, keyring files, SSH keys, tokens.
7. **Ask Rolando in chat, and wait for the answer, before:** any reboot, shutdown, suspend test or `chvt`;
   `systemctl restart|stop` of `getty@tty2`, `autovt@tty2`, `NetworkManager`, `wpa_supplicant*`, `systemd-networkd`,
   `systemd-logind`, `pipewire*`, `wireplumber`, `greetd`/`sddm`, or killing `Hyprland`/`start-hyprland`/`hypr-session`
   (each one closes every open app or cuts the network, and the Studio reaches the machine over it); any change to a
   network connection; switching the trackpad preset or `monitors.lua`; killing his running apps.
8. **Never run `omarchy update`, `omarchy-update*`, `pacman -Syu`, `pacman -Sy` or `pacman -U`** of anything. A Mesa/LLVM
   bump can break `/opt/mesa-aurora`, and a partial upgrade breaks Arch. Single packages are fine, see "Packages".
9. **Never edit anything under `/usr/share/omarchy/`** (package-owned, overwritten by updates; reading is fine). Never
   edit or replace `~/.claude/skills/{diagnose-crash,omarchy,omarchy-app}` (symlinks into that tree) or
   `~/.claude/skills/synced/`.
10. **Nothing leaves the machine except through the two repos below.** No issues, PRs, comments or messages to
    omacom, aurora-silicon, Hyprland, Arch, or anyone else; no `omarchy debug` upload (it posts a log to a public
    server). If a bug looks upstream, record it in the tracker and tell Rolando; the Studio session handles upstream.
    Do not offer or run `omarchy-crash-mute` for `Hyprland`, `quickshell` or `start-hyprland`.

If the auto-permission classifier blocks a command, that is a signal, not an obstacle: tell Rolando what you wanted to do.

## One owner at a time

Two kinds of agent work on this one machine: you (local, runs as `rolo`, small fixes and diagnoses) and the Studio
session (Mac Studio, reaches the machine as root over the network; boots, kernel payloads, loop tests, ESP writes).

- Before any action that writes a lot (more than a few packages, a large copy), restarts a service, or runs anything
  you suspect could stall the machine: `ls /run/m5pro-studio-busy`. If it exists, the Studio is mid-run (the file says
  what): stop and tell Rolando, do not work around it.
- While you do package installs or large writes, `echo '<what>' > "$XDG_RUNTIME_DIR/m5pro-local-busy"` and remove it
  when done, so the Studio session can see it.
- Reboot-level actions (rule 7) are always Rolando's call in chat, whatever the files say. After a large write the
  machine must idle 60 s before a reboot (the SSD controller must settle; otherwise the next boot can fall back to the
  previous payload): another reason a reboot is never yours to do.
- You have no root. `sudo` asks for Rolando's password (`%wheel ALL=(ALL:ALL) ALL`, 10 min timestamp), and only
  Omarchy's own helpers are passwordless (`omarchy-dns`, `omarchy-locale-generate`, ...). Do not try to work around
  it. Give Rolando the exact command, or ask him to run `sudo -v` in a terminal and tell you.

## What the machine is

- **MacBook Pro 16-inch, M5 Pro** (Mac17,8, board **J716s**, SoC T6050, 48 GiB, 18 CPUs), running **Omarchy 4.5.0 on
  Arch Linux ARM** (aarch64) from Omarchy's official packages. Hostname and unit ids stay out of anything you commit.
- Linux is a guest of the Apple boot chain, built by hand. iBoot starts a stage-1 m1n1 (the stub's boot object, A/B
  fallback, 150 s watchdog), which loads stage-2 from the ESP: one payload file `boot.bin` (m1n1 + boot arguments +
  `Image.gz` + device tree + initramfs; `boot.bin.prev` is the rollback). The kernel is a custom 7.3.0 build of the
  Aurora Silicon tree plus our patch series, built on the Studio. Root is ext4 on the NVMe, label `m5root`.
  There is **no bootloader, no initramfs rebuild, no kernel package**: anything that says "update the kernel/initramfs/
  boot entries" does not apply here and is forbidden (rule 1). `uname -r` shows the running build (7.3.0-gbd53915f2ef1
  on 2026-11-08, payload `daily-dcp-lfix-vrr`).
- `dmesg` is readable by `rolo`, the journal's kernel lines are too (`journalctl -k`), `coredumpctl` works for your own
  crashes.
- Status of every feature, with evidence: `~/Work/m4-m5-linux/machines/j716s/machine.yaml`; round-by-round results:
  `~/Work/m5pro-linux/contrib/validated/integration/RESULTS.md`; the README status table:
  `~/Work/m5pro-linux/README.md`; boot and recovery: `docs/boot-and-recovery.md`.

## Desktop and graphics, as they run now

- **Two cards.** `aurora` (the Apple GPU, render-only, `renderD128`, usually `card0`) and `apple-drm` (the DCP, drives
  the panel, usually `card1`, connector `eDP-2`). Card numbers are not stable; the launcher finds them by driver name.
  The panel is 3456x2234 at 120 Hz, scale 2, VRR on (`appledrm.fw27_panel_vrr=1`, firmware minimum 24 Hz), direct scanout
  allowed, software cursor (the DCP has no cursor plane), `AQ_NO_MODIFIERS=1`. Hyprland (0.57.1, **Lua config**: no
  `hyprctl keyword`, use `hyprctl eval 'hl.config({ ... })'`) renders on the GPU straight into the DCP's scanout buffers.
- **GL is zink** on the Aurora Vulkan driver (`/opt/mesa-aurora`, selected by `/etc/mesa-aurora/session.env`). The
  **native Gallium GL** trees (`/opt/mesa-aurora-gl`, and `-gl2` with patches 0001-0008) are **A/B only**: the native
  driver cannot build ordinary apps' fragment programs yet (Alacritty renders black), so the desktop stays on zink.
  Do not switch it (rule 2).
- **Launch chain:** `getty@tty2` autologin (+ a drop-in that does `chvt 2`) -> `~/.bash_profile` -> `~/.local/bin/hypr-session`
  -> `/usr/local/bin/hypr-gpu-session` -> `start-hyprland`. If the GPU session dies within 30 s the launcher starts a
  llvmpipe software session instead (reason in `~/.cache/hyprland-gpu.log`). Logs: `~/.cache/hyprland-tty2.log`,
  `~/.cache/hyprland-gpu.log`, `$XDG_RUNTIME_DIR/hypr/*/hyprland.log`. `m5pro-desktop lite|omarchy|status` flips the
  old Waybar desktop (applies at the next Hyprland start; its use is Rolando's call).
- **Omarchy 4.5:** the shell is Quickshell (bar, wallpaper, notifications, menu); user config lives in `~/.config/hypr/`
  (`bindings.lua`, `looknfeel.lua`, `input.lua`, `autostart.lua`) and `~/.config/omarchy/`. Edit those, not
  `/usr/share/omarchy` (use the `omarchy` skill's guides for Hyprland, theming, hooks). Reload with `hyprctl reload`;
  restart the shell with `omarchy-restart-shell`. `monitors.lua`, the trackpad presets (`~/.config/hypr/trackpad/`,
  `contrib/validated/desktop/trackpad/HOWTO.md`) and anything display-geometry-related: ask first (rule 7).
- Omarchy ships Chromium; flags live in `~/.config/chromium-flags.conf` (it carries `--disable-gpu`, see the crash class).
  The GPU is the Aurora driver, not a mainstream one: expect apps that assume Mesa/NVIDIA/Intel to misbehave.

### The known crash class (read this before blaming a config)

Chromium and Electron clients (Chromium, `chrome`, `claude-desktop`, and likely ChatGPT, Obsidian, 1Password, ...) submit
GPU work that **faults the GPU**. The driver logs `aurora: GPU work of a client failed (ENODATA, ... client <name>[pid]);
the client sees a lost device` and `asahi: recovery fault registers`; the recovery also fails **Hyprland's** GPU context
(ENODATA), then **zink SEGVs** (`dri_create_fence_fd`) instead of reporting a lost context, Hyprland aborts (SIGABRT),
`quickshell`/`hyprland-dialog` die with it, and a respawned Hyprland cannot initialise EGL while the GPU is recovering
(the safe-mode screen). Not a configuration problem. Stopgap in place: those apps run with `--disable-gpu`
(`chromium-flags.conf`; each Electron app reads its own flags file, e.g. `~/.config/claude-desktop-flags.conf`; check each
one, a client that still shows up in `dmesg` is one without the flag). Analysis: `contrib/pending/gpu/` in the repo.
The fix is kernel/driver work and belongs to the Studio session.

## Audio

PipeWire 1.6.10 + WirePlumber 0.5.18 (check `pacman -Q`), ALSA card `AppleJ716` (`hw:AppleJ716,N`). The speakers are
six amps in the J616s TDM frame behind **`speakersafetyd`** and a **kernel -30 dB ceiling** that stays until the listening
test (and the speaker-sense 4x reading) are settled. The active graph is the bring-up filter chain (a filter sink feeding
the hidden `RawSpeakers` sink); the **profile graph** (J616s DSP chain, volume capped at -10 dB) is built and staged in
`/usr/share/asahi-audio/j716/profile/`, not active. `j716-audio-ab status` shows which is live; `j716-listen` is the
listening-test TUI, for Rolando to run. WirePlumber keeps the route volume in `~/.local/state/wireplumber/default-routes`
(on 2026-11-08 the stored route was 2.7 % and made the speakers inaudible: that was the "no sound" bug, fixed by hand;
back the file up before touching it). Microphone works; the headphone jack is wiring-only, untested. Details:
`contrib/validated/desktop/audio/j716-profile/REPORT.md`.

## Network

**NetworkManager** since 2026-11-08 (Omarchy's Wi-Fi menu drives it): `systemd-networkd` and `wpa_supplicant@wlan0` are
disabled. The Wi-Fi network is WPA2/WPA3 transition and its profile needs `802-11-wireless-security.pmf=1`; a USB
Ethernet adapter was kept as the way back in. The Wi-Fi chip (the N1) is trained by the kernel. Use `nmcli` for status;
changing a connection or restarting NetworkManager is rule 7, secrets are rule 6.

## Packages

`sudo pacman -S --needed <pkg>` is fine (Rolando types the password). Not fine: boot-chain packages (the guard refuses
them), `-Sy`/`-Syu`, anything that would upgrade Mesa, LLVM, Hyprland, aquamarine, PipeWire, WirePlumber or Qt as a side
effect (read the transaction preview first; if it lists upgrades of installed packages, stop and ask). AUR is not
available. Omarchy's package lists: `/usr/share/omarchy/install/`.

## How results land

Two repos, both public, both owned by Rolando's GitHub account `rolotrealanis98`, both cloned on this machine; `gh` is
logged in (HTTPS, credential helper set). Commit as **Rolando Trevino <rolotrealanis@gmail.com>** (already the clones'
git identity). **No AI trailers anywhere**: no `Co-Authored-By`, no `Assisted-by`, no "Generated with" line, no
disclosure sentence, in commits, issues, comments or docs. Push straight to `main` (neither repo has branch protection);
`git pull --rebase` first; never force-push; if a rebase conflicts, stop and tell Rolando.

| Repo | Clone | What goes in |
|---|---|---|
| `rolotrealanis98/m5pro-linux` | `~/Work/m5pro-linux` | The write-up of every fix and the config it changed |
| `rolotrealanis98/m4-m5-linux` (the tracker) | `~/Work/m4-m5-linux` | An issue per fix or new bug; a result file + `machine.yaml` change when a status cell changes |

### 1. Small fixes: `contrib/validated/desktop/omarchy-fixes/<date>-<slug>.md` in m5pro-linux

`<date>` = `date -u +%F`, `<slug>` = a few lowercase words (`wallpaper-imagemagick`). Back up every file before editing
(`cp -a f f.pre-<slug>`). The doc has these sections, and the config change itself is documented, not just described:

```markdown
# <one-line title> (<date>)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/<N>     Kernel: <uname -r>
## What broke
<symptom as the user saw it, exact error lines trimmed and scrubbed>
## Cause
<what the evidence shows; say what was inferred rather than proven>
## Fix
<what was done, in the order done; packages installed; commands run>
## Files changed
<path -> what changed. Unified diff (`diff -u f.pre-<slug> f`) for edits; for a new file, the content inline or a copy
under omarchy-fixes/files/<date>-<slug>/ (scrubbed)>
## Verified
<how it was checked and what was seen; "Rolando confirmed by eye" only if he did>
## Rollback
<exact commands: restore the .pre-<slug> backup, remove the package, ...>
```

```bash
cd ~/Work/m5pro-linux && git pull --rebase
mkdir -p contrib/validated/desktop/omarchy-fixes        # first fix only
python3 ~/Work/m4-m5-linux/tools/privacy_scan.py contrib/validated/desktop/omarchy-fixes/<date>-<slug>.md
git add contrib/validated/desktop/omarchy-fixes
git commit -m "desktop: <what changed> (omarchy-fix <slug>)"          # no trailers
git push origin main
git rev-parse HEAD                                                      # for the permalink below
```

### 2. Every fix or new bug gets a tracker issue

Open it when you start (state `in-flight`), close it when fixed. Labels: `machine:j716s` plus exactly one of
`attended` (needs Rolando's hands or eyes), `in-flight` (being worked now), `blocked` (needs something unavailable),
`upstream` (waits for a kernel/loader/Mesa/Omarchy change, name the PR), `help-wanted`. Search first
(`gh issue list -R rolotrealanis98/m4-m5-linux --state all --search "<words>"`); comment on an existing issue instead of
opening a duplicate.

```bash
cat > "$XDG_RUNTIME_DIR/issue.md" <<'ISSUE'
**Machine:** J716s, kernel `<uname -r>`
**Symptom:** <what happens, scrubbed>
**Evidence:** <trimmed log lines>
**Cause / status:** <known | suspected | unknown>
ISSUE
gh issue create -R rolotrealanis98/m4-m5-linux \
  --title "J716s: <short symptom>" \
  --label machine:j716s --label in-flight \
  --body-file "$XDG_RUNTIME_DIR/issue.md"

gh issue edit <N> -R rolotrealanis98/m4-m5-linux --remove-label in-flight --add-label attended   # change state
gh issue comment <N> -R rolotrealanis98/m4-m5-linux --body "<scrubbed note>"                     # another occurrence
gh issue close <N> -R rolotrealanis98/m4-m5-linux --comment \
  "Fixed: https://github.com/rolotrealanis98/m5pro-linux/blob/<full-sha>/contrib/validated/desktop/omarchy-fixes/<date>-<slug>.md"
```

### 3. A changed status cell: result file + `machine.yaml` in the tracker, pushed to `main`

Only when a feature's state really changed because **you ran it on this machine today** (a fix that makes a broken
feature work, a regression found). Otherwise leave the matrix alone. Read the tracker's rules first
(`~/Work/m4-m5-linux/README.md` "States and evidence", `CONTRIBUTING.md`, the `works:` sentence per feature in
`schema/features.yaml`): a `works-*` state needs `kind: native` and a result file; a software fallback or a loaded driver
is not a pass.

```bash
cd ~/Work/m4-m5-linux && git pull --rebase
# 1. machines/j716s/results/<date>-<slug>.md : copy the front matter of the newest file there; update date (UTC),
#    kernel (uname -r), features, source (permalink to the m5pro-linux fix doc, commit pushed first), attended.
#    If uname -r differs from that file's kernel, the daily changed: ask Rolando before writing the build/payload lines.
# 2. machines/j716s/machine.yaml : the cell's state, kind: native, evidence: [results/<date>-<slug>.md#results],
#    verified: "<date>", a one-sentence note.
python3 tools/gen.py                    # regenerates the README matrix and site/
make check                              # validate + privacy_scan + pytest + gen --check; must pass
git add -A machines README.md site
git commit -m "j716s: <feature> <state> (<slug>)"                       # no trailers
git push origin main
```

## Privacy: nothing of this in any file, commit, issue or comment

Serial numbers, ECID, nonces, MAC and Bluetooth addresses, IP addresses (LAN and VPN), host names, Wi-Fi network names
and passphrases, partition and filesystem UUIDs (PARTUUID, UUID), account names and e-mail addresses other than the commit
identity, tokens and keys; Apple firmware or boot objects, per-unit firmware (the N1 Wi-Fi/Bluetooth image) and
firmware digests, calibration bytes, NVRAM dumps, raw device trees or ADT dumps from the running machine, core dumps
(they are copies of process memory), whole journals. In the **tracker**, also no user names or home paths: write `~`.
Quote only the trimmed log lines that carry the evidence, and run
`python3 ~/Work/m4-m5-linux/tools/privacy_scan.py <paths>` on every file before committing it, in either repo.

## Where the details are

`~/Work/m5pro-linux/contrib/validated/desktop/` (Hyprland, Omarchy upgrade, audio, trackpad reports),
`contrib/pending/gpu/userspace/mesa-aurora/session-dcp/REPORT.md` (the two-card session),
`contrib/validated/integration/RESULTS.md` (the 2026-11-08 sections), `contrib/validated/aurora/STATE.md` (payload
ingredients), `docs/boot-and-recovery.md`, `~/Work/m4-m5-linux/machines/j716s/`.
