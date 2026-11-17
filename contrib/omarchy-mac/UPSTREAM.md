# Upstream candidates

Grouped by target. "Ready" means: could go as a proposal after the listed work, not that anything is ready to send today. **Nothing outward-facing
has been done**: no pull requests, issues, pushes or comments. Conventions below were read from the target repositories on 2026-11-17 (public
API, read-only): `omacom/omarchy-mac-pkgs` (CONTRIBUTING.md, tree), `aurora-silicon/alarm-aurora` (README, `packages/`, `tests/`, `docs/`),
`aurora-silicon/omarchy-aurora` (AGENTS.md), `omacom/omarchy` (AGENTS.md), `aurora-silicon/linux` (CONTRIBUTING.md). Row names refer to
`INVENTORY.md`.

Common to every target: only the J716s has run any of this, so each proposal needs either a second Mac's result or an honest "J716s only"
label; every personal detail (the `rolo.` plugin ids, the `rolo` account, addresses, the owner's taste in layout) has to go first; and
**no per-machine firmware or calibration is ever part of a proposal** (INVENTORY section H).

## 1. omacom/omarchy-mac-pkgs (the Mac's Omarchy packages)

Layout: `omarchy-mac/` (`bin`, `entrypoints`, `share`, `lib`, `test`, `vendor`), `omarchy-mac-boot/`, `mac-manual/`, `test/integration/`, `tools/`.
Rules from its CONTRIBUTING.md: pull requests against `main`, approval by someone other than the author, one change per PR; a new package needs an
issue first; anything the runtime reads from a package (platform root, entrypoints, setup commands) needs an integration test in `test/integration/`;
everything Apple-specific stays behind `omarchy-hw-aarch64-apple`; boot-critical changes need cold-boot evidence; hardware reports go to omarchy-m-testing.org.

| Candidate | Ready? | Needs first |
|---|---|---|
| Battery charge limit (`m5pro-charge-limit`) | Do not propose: `omarchy-battery-charge-limit` already exists there and uses the same `/etc/udev/macsmc-battery.conf` | Diff behaviours: ours has `full` (100 % until unplugged or reboot) and restore-on-unplug through udev. If upstream lacks them, propose only that delta, with a `test/integration/` case; otherwise drop ours and use upstream |
| Wireplumber A2DP auto-connect (`wireplumber-user-tweaks`) | Maybe | Check Omarchy's default Bluetooth config for the same key first; if absent, goes in `omarchy-mac/share/wireplumber/` as a system file (ours is a user file), with a test. The USB-speaker file is personal and stays out |
| Startup-disk menu row (`omarchy-startup-disk`) | Not yet | Needs the NVRAM kernel patches (`contrib/pending/nvram/`) and `aurora-bless` to be proven attended on a second Mac; rewrite to Omarchy's style; the macOS-boot row belongs behind the platform detector |
| Touch ID setup (the `enable-fingerprint` / `disable-fingerprint` entrypoints exist) | Not by us alone | The Touch ID agent's plugin and PAM changes have to meet those entrypoints; the SEP driver must be in the kernel Macs update to first (CONTRIBUTING: a prompt is released only after everything it leads to is published) |
| pacman platform guard / `IgnorePkg` (`pacman-conf`, `m5pro-boot` guard) | No | Upstream lists the guard as an Omarchy plug-in point implemented by `omarchy-mac-boot`; our guard protects a hand-built boot chain that upstream does not have. Offer the 17-case test as a fixture only if asked |

## 2. aurora-silicon/alarm-aurora (and the repos it builds from)

Layout: `packages/<name>/PKGBUILD` plus files, `sources.json` and `tracking.json` pin shared revisions, `docs/`, `tests/` (Python, one `test_*.py`
per feature: pins, kernel config, modprobe, PAM, first boot...), `scripts/build-package`. AGENTS.md of the sibling `omarchy-aurora`: reuse the signed
ALARM hardware repository, never commit private keys or device firmware, preserve package versions, run pure tests locally.
Aurora's `aurora-system-fixes` already carries numbered udev/sysctl/systemd drop-ins (`50-after-swapfile.conf`, `60-` to `64-aurora-*.rules`,
`90-aurora-reboot-watchdog.conf`): that is the natural home for the small system items.

| Candidate | Ready? | Needs first |
|---|---|---|
| RT clamp sysctl (`sched_util_clamp_min_rt_default=128`) | Best first candidate | Idle A/B numbers exist (3.5 to 3.2 W, two runs, panel off). Needs: a run on another Apple SoC so it is not T6050-only, a drop-in named like the others (`NN-aurora-*.conf`) in `aurora-system-fixes`, a `tests/test_*.py` that the file ships, and the kernel option dependency stated (`UCLAMP_TASK`; not in every kernel, see `contrib/pending/next/HANDOFF.md`) |
| xhci wake-up udev rule | Only until the DT fix | The rule's own comment says the device tree should carry it: propose the `wakeup-source` property to `aurora-silicon/linux`; the udev rule is a stopgap in `aurora-system-fixes` if the DT change takes long |
| libinput quirks for the Apple MTP trackpad (`local-overrides*.quirks`) | After the kernel patches | Two variants exist (with and without `j716s-trackpad` patches); keep one, matched to the kernel Aurora ships; evidence is `contrib/pending/platform/trackpad-feel/PALM-REJECTION.md`. `aurora-system-fixes` already has `64-aurora-trackpad-clicks.rules` (host-driven clicks), so coordinate with that |
| Trackpad kernel patches (hover filter, palm tool, contact ids) | Needs a second MTP trackpad | Rebase on Aurora's tree; `aurora-silicon/linux` CONTRIBUTING.md is a reporting guide (one issue per Mac, with board and build details), so open an issue with evidence before a patch |
| Crash log (`m5-netconsole`, `m5-pstore-collect`) | After de-personalising | Move the target address out of the script into a documented, empty-by-default config; no address in any shipped file; becomes a new `aurora-crashlog` package (none exists) or part of `aurora-platform`; needs a PKGBUILD, a test and a run on a second Mac |
| Speaker protection and speaker upgrade (J716s drop-ins, `speakerguardd-v2`) | Wait | Owned by the speaker agent; `alarm-aurora` already has `speakerguardd-v2`, `aurora-speaker-upgrade` and `speakersafetyd-aurora-profiles`. Ours add the J716s profile and the auto drop-in; hold until the sense-binding work lands and a listening test (`LISTENING-TEST.md`) is signed off |
| UCM profiles and voicing for the J716 (`alsa-ucm-conf-asahi`, `asahi-audio`) | After a listening test | Repos exist in the org with J616s/J700 notes as the pattern; add J716 entries in the same layout |
| Touch ID stack (`libfprint-aurora` revision, `fprintd`, re-arm) | Wait | Owned by the Touch ID agent; Aurora already has `libfprint-aurora`, `fprintd-aurora`, `aurora-touchid-rearm`, `aurora-sep*`, and tests (`test_touchid_pam.py`, `test_sep_modprobe.py`). Ours is the J716s revision (eleven patches); rebase onto their recipe and extend their tests |
| Regulatory-domain service (`m5pro-regdom`) | No (kernel config) | cfg80211 built in is a kernel-config choice; ask in `aurora-silicon/linux` for the module or a `regulatory.db` firmware built in |
| Watchdog drop-in | Drop ours | `aurora-system-fixes` already sets `RebootWatchdogSec=2min` (the SoC watchdog cannot count to our 5 min); keep only `RuntimeWatchdogSec=60` if wanted |
| Kernel, device tree, loader | Separate flow | Patches and DT (`contrib/pending/*`, `pending/aurora/t6050-j716s.dts`) go to `aurora-silicon/linux` and `aurora-silicon/aura` through their own process (aura has AGENTS.md/CLAUDE.md: read them first); not covered here |
| `aurora-diag` | Nothing to propose | The Mac runs a copy under `/usr/local`; replace it with the `aurora-diag` package from `alarm-aurora` |

## 3. Omarchy itself (omacom/omarchy)

Rules: AGENTS.md points to task guides in `agents/skills/`: bash 5 style (`#!/bin/bash`, `[[ ]]`, `(( ))`, two-space indent), `# omarchy:summary=` command
metadata, the Quickshell desktop under `shell/` (with motion and visual-verification guides), migrations, acceptance and qemu tests. Apple Silicon desktop
work goes there now (omacom/omarchy#14431 merged).

| Candidate | Ready? | Needs first |
|---|---|---|
| Image picker software-render fix | Good candidate | The change is a diff to the stock picker (`contrib/validated/desktop/omarchy-fixes/files/2026-11-16-image-picker-software/ImagePicker.qml.diff`): re-make it against the current stock `omarchy.image-picker`, show it on a software-rendered VM (not Mac-only), follow `shell-dev.md` and `visual-verification.md` |
| Mission Control plugin | Possible | Optional plugin: new id without `rolo.`, i18n, `motion.md` rules, a screenshot test; the 3-finger gesture binding lives in the Mac profile, not the plugin |
| Tray widget (`rolo.tray`) | Possible | The bar has none; generic QML but 35 KB with the owner's styling: split model from view, tests under `test/acceptance.d/` |
| Pointer panel (`rolo.pointer`) | After kernel and quirks | Writes Hyprland device settings for `apple-mtp-multi-touch`: Mac-only, so it has to be gated by `omarchy-hw-aarch64-apple`; the Python helper becomes a bash `omarchy-*` command with metadata, or stays personal |
| Battery menu rows | Yes, with the charge-limit command | Rows call `omarchy battery charge limit` (omarchy-mac), not our script; menu IDs follow the extension format |
| Lock screen without the installer step | Idea | When `omarchy-lock-password` is missing the shell logs `lock-denied: missing-pam`; our `apply.sh` writes the file. A shell-side self-heal or a clearer message might be wanted: raise as an issue first, with the log line |
| Hyprland config (monitors, gestures, profile switch) | No | Personal; any generic bind or gesture fix goes upstream per omarchy-mac-pkgs CONTRIBUTING |

## 4. none / personal (stays here)

`dmesg-unrestricted`, `tty2-autologin`, `boot-selftest`, `m5w-windows`, `bringup-debug-tools`, `omarchy-lite-fallback`, `omarchy-shell-config`, journald cap, zram
(Omarchy ships its own zswap), lid-lock default, `omarchy-extras`, Tailscale, the KM Link plugin until it has a repository, the `hyprland-m5pro` package
(its home is hyprwm/Hyprland, which is not one of the three targets: the direct-scanout patch needs to go there with a reproduction), the aquamarine patch (obsolete),
the Codex agent context, and every kernel experiment that has not booted.

## Order I would take

1. Clean up first: delete stale files on the Mac, bring the Mac up to the repo's newer versions (INVENTORY section I), drop the redundant watchdog and charge-limit pieces.
2. RT clamp to `aurora-system-fixes` (smallest, measured, one file, one test).
3. Image picker fix to Omarchy (generic, testable in a VM).
4. After the Touch ID and speaker agents finish: their packages against the existing Aurora recipes.
5. Kernel items through `aurora-silicon/linux` issues with evidence, one per area.
