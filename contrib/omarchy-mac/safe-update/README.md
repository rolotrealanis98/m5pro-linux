# safe-update: `m5pro-safe-update`, the update path for an Omarchy MacBook that carries its own kernel, Mesa and Touch ID

Scope `t6050` (holds and pins are the J716s's), status `installed`, native `omarchy update` guards in place (2026-11-19), upstream target below.
Closes gap-map row `desktop.update-path` once it has had its attended first run (`/Volumes/m5pro/bench/requests/safe-update-1.md`).

`omarchy update`, `omarchy apply system`, `omarchy-refresh-*`, `omarchy-apply-hardware` and a bare `pacman -Syu` are all unsafe on this Mac
(see "Clobber map"). `m5pro-safe-update` replaces them: it snapshots state, upgrades with holds, runs Omarchy's migrations under a policy,
puts our files back where an update clobbered them, and prints a report. It never reboots and never touches the kernel, `/boot` or `/opt/mesa-aurora*`.

## Use

```sh
sudo contrib/omarchy-mac/install-item.sh safe-update      # lays /usr/local/sbin/m5pro-safe-update and /etc/m5pro/safe-update/*
m5pro-safe-update --dry-run            # read-only: what would change, what it would clobber, what is blocked (uses sudo to refresh a PRIVATE copy of the sync DBs)
m5pro-safe-update --dry-run --deep     # also downloads the packages to the cache and scans their file lists against every tracked path + the migrations they bring
m5pro-safe-update --run                # asks, then: preconditions -> snapshot -> plan -> keys -> pacman -Syu with holds -> migrations -> validation -> report
m5pro-safe-update --check              # validate only (also: the report after any manual pacman change)
m5pro-safe-update --restore [PATH...]  # put tracked files back from the last snapshot
m5pro-safe-update --undefer NAME       # release a deferred migration
m5pro-safe-update --classify DIR       # classify migrations of any Omarchy checkout (works on the Studio: DIR=upstream/omarchy/migrations)
```

Options: `--yes` (no prompt, `--noconfirm`; only after a dry run), `--repo DIR` (m5pro-linux checkout, enables item-vs-repo checks),
`--with-mise`, `--allow-boot-change` (downgrade an ESP change from FAIL to WARN), `--force-hazards`. Exit 0 clean, 1 warnings, 2 failures, 3 refused (nothing changed).
Needs bash 4.4+ (the Mac has 5.x); `--classify` and `--gen-tracked` also run on the Studio with Homebrew bash.

## What a run does

1. **Preconditions** (refuses, changes nothing): `/etc/pacman.conf` `IgnorePkg` still holds every word in `holds.conf` `ignore-required`; the boot-guard and Touch ID guard hooks exist; pins match.
2. **Snapshot** to `/var/lib/m5pro-safe-update/<stamp>/` (`latest` points at it): `pacman -Q`, explicit/foreign/orphan lists, `pacman -Qii` MODIFIED backup list (the `/etc` diffs), `pacman.conf`,
   sha256 of every tracked path (`tracked-paths.txt`, generated from `INVENTORY.md`) and a copy of each (up to 1 MiB), file owner map, `/boot` hash manifest, `/opt/mesa-aurora*` unresolved-library baseline,
   tracked unit enable states, failed units, `.pacnew` list, migration markers, item-vs-repo drift. Plus `omarchy-snapshot create` when snapper exists.
3. **Plan**: a private copy of the sync DBs, `pacman -Qu`, then `pacman -Su --print` with our holds. If pacman cannot build that transaction (held package needed by a newer dependent) it refuses with pacman's own message. Hazard scan of the incoming
   packages' `Replaces` / `Conflicts With` / `Provides` against everything we protect (refuses unless `--force-hazards`).
4. **Upgrade**: `omarchy-update-keyring`, then `pacman -Syu --ignore <holds> --overwrite '/usr/share/omarchy/*'` (the overwrite is Omarchy's own, for its takeover of unowned files under its own tree). The boot guard and Touch ID guard hooks still run.
5. **Migrations**: each pending `/usr/share/omarchy/migrations/*.sh` is classified by `migration-policy.tsv`. DEFER ones are not run: copied to `/var/lib/m5pro-safe-update/deferred/`, logged in `deferred.tsv`, marked done. REVIEW/INFO/SAFE run as the desktop user exactly as `omarchy-migrate` would (`bash -euo pipefail`), marker on success; a failure stops the loop.
6. **Validation**: pins, protected packages (still installed, version change reported), `/boot` unchanged (FAIL if not), `/opt/mesa-aurora*` still resolves its libraries (FAIL on a new unresolved one), tracked files (below), unit states, new failed units, drop-in ordering lint, sysctl runtime vs our files, item files vs repo, new `.pacnew`.
   Files: changed **system** files that no package owns, or that were locally modified before (`pacman -Qii`), are put back automatically from the snapshot. Changed **home** files (migrations) are reported with the diff command, never reverted (a new shell may need the edit). Stock files of a package that the package rewrote are INFO.
7. **Report**; never reboots. Orphan removal, `yay -Sua`, cache pruning, `mise update` (without `--with-mise`), `omarchy-update-boot` and the shell restart of `omarchy update` are not run (reasons below).

## Uniform `--check` contract (proposal, implemented here)

Every item installer would answer `install.sh --check`: read-only, exit 0 = installed state matches the repo, 1 = drift (one line per finding on stdout), 2 = cannot tell; no sudo needed for the user-level part.
`m5pro-safe-update` runs any script under `contrib/` that carries the line `# m5pro-check: yes` with `--check` (only when `--repo`/a checkout is found) and reports a non-zero exit as drift; scripts without the marker are **never** run
(none of the existing installers has a check mode today, and `install-item.sh` items are covered anyway: every `files/` and `home/` file of every `contrib/omarchy-mac/*/` item is compared with the live file, `@USER@` substituted). Items still to get `--check`:
`power-profiles/install.sh`, `camera-v4l2-bridge/install.sh`, `auto-brightness/install.sh`, `startup-disk/install.sh`, `macos-feel/install.sh`, `pending/desktop-defaults/apply.sh`, `pending/touchid-omarchy/install.sh`, `validated/desktop/audio/install.sh`
(their owners add the flag and the marker; this item does not edit them).

## Clobber map (file by file against `INVENTORY.md`)

Sources read: basecamp/omarchy `bin/omarchy-update*`, `omarchy-migrate`, `omarchy-apply-*`, `omarchy-refresh-*`, `install/`, `etc/` and `migrations/` at 3437cfb (v4.5.0 plus 2221 files) and the package recipes of omacom/omarchy-pkgs (`omarchy`, `omarchy-settings`, `omarchy-mac`, `omarchy-mac-boot`).
Full detail with the 79 migrations added since v4.5.0: `/Volumes/m5pro/bench/requests/safe-update-1.md`.

| Step | What it does | Hits | Handled by |
|---|---|---|---|
| `omarchy-update-system-pkgs` | `pacman -Syu --noconfirm --overwrite '/usr/share/omarchy/*'`; `--noconfirm` takes the default **yes** on "replace X with Y?" | any `Replaces`/`Conflicts` against our hand-built packages (`alsa-ucm-conf-asahi`, `speakersafetyd`, `speakerguardd-v2`, `libfprint-git`, `omarchy-power-profiles-daemon`, `libva-v4l2-request-avd`, `hyprland-m5pro`) | `holds.conf` `hold`, hazard scan, simulate; no `--noconfirm` unless `--yes` |
| the same, repo order | Omarchy templates (`default/pacman/aarch64-apple/`) list `[omarchy]` **first**, ahead of `[alarm]`; migration 1791403252 moves it first | Omarchy's builds of `mesa`, `pipewire`, `alsa-ucm-conf`, `speakersafetyd`, `asahi-audio` win over Aurora's | IgnorePkg + extra holds (a held package is skipped whichever repo is first) |
| `omarchy-update-system-pkgs` (deps) | `omarchy` -> `omarchy-mac` (held) -> speaker stack, audio, GPU driver | newer `omarchy` needs a newer held package: pacman refuses ("breaks dependency") | simulate refuses before anything runs |
| libraries | `llvm-libs`, `libdrm`, `libglvnd`, `wayland`, ... | `/opt/mesa-aurora*` loads them from the system (stock `mesa` is only the software fallback) | `watch` list, `--deep` soname check, post-run `ldd` baseline compare |
| hypr libs | `aquamarine`, `hyprutils`, `hyprlang`, ... in lockstep with held `hyprland` 0.57.1 | ABI break of the patched Hyprland | held together |
| `omarchy-settings` `post_upgrade` | `cp -f` over `/etc/security/faillock.conf`, `/etc/nsswitch.conf`, `/etc/plymouth/plymouthd.conf`, `/etc/cups/cups-*.conf`, `/etc/skel/.bashrc`; removes `/etc/sudoers.d/99-omarchy-nopasswd-*` | not ours (INVENTORY lists none); would reset hand edits | noted; no hold needed |
| `omarchy-settings` payload | `/etc/sysctl.d/99-omarchy-sysctl.conf` (`vm.swappiness=150`, watermark, page-cluster), `/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf`, `logind.conf.d/10-ignore-power-button.conf`, `system.conf.d/*` | sort **after** our `/etc/sysctl.d/50-m5pro.conf` (swappiness 180, RT clamp), `zram-generator.conf.d/50-m5pro.conf`, `logind.conf.d/*m5pro*`: Omarchy's value wins | drop-in ordering lint + `sysctl` runtime check |
| `omarchy-update-pkg-prune` | `paccache -rk2` | older cached builds of our packages = the rollback | not run |
| `omarchy-update-orphan-pkgs -y` | removes every orphan without asking | hand-installed leaf packages (`libva-utils`, `wtype`, ...) | not run; orphans reported, protected ones FAIL |
| `omarchy-update-aur-pkgs` | `yay -Sua --noconfirm` on all foreign packages | `libfprint-git`, `apfs-fuse-git`, locally built ones | not run |
| `omarchy-update-boot` | `omarchy-lifecycle-dispatch update-verify` -> `omarchy-apple-silicon-boot-check`, rebuilds initramfs/m1n1/Limine on a snapshot restore | `omarchy-mac-boot` is held and absent: only a warning today; if installed it would rebuild the ESP; `/etc/omarchy-mac-boot/owner-boot-chain` is the documented opt-out | not run; own `/boot` manifest compare instead |
| `omarchy-migrate` | runs every unmarked migration, as the user, with `sudo` | see policy below | `migration-policy.tsv` |
| `omarchy-apply-system` / `-hardware` | `install/hardware/network.sh` disables systemd-networkd and moves stock `20-*.network` away; `platform-setup.sh` -> `setup-boot` (limine, `update-m1n1`, `/boot`); `config/*.sh`: `/etc/pam.d/system-auth`, `lockscreen-pam.sh` (`/etc/pam.d/omarchy-lock-*`), `firewall.sh` (`/etc/ufw/*`), `enable-services.sh` (enables `sddm`, `NetworkManager`, `power-profiles-daemon`), `snapper.sh`; `post-install/pacman.sh` rewrites `/etc/pacman.conf` + mirrorlist | the owner's tty2 autologin, network, PAM/Touch ID rows, ufw rules, `pacman.conf` holds | never run (README rule); not part of an update |
| `omarchy-refresh-pacman` / `-apply-pacman` / channel switch | overwrite `/etc/pacman.conf` and mirrorlist, then `pacman -Syyuu` | drops IgnorePkg, `[m5pro]`/`[aur]`; the boot-guard hook covers only the boot packages | `ignore-required` precondition; migrations touching it are DEFER |
| `omarchy-refresh-config/hyprland/shell/applications/...` | copy the packaged default over `~/.config/...` (backup `.bak.<ts>`) | `~/.config/hypr/*.lua`, `~/.config/omarchy/shell.json`, `extensions/omarchy-menu.jsonc` (Hyprland profile, plugin menu rows, auto-brightness rows, 1Password/Startup Disk rows) | never run; migrations calling them are REVIEW |
| `omarchy-refresh-limine`, `omarchy-kernel` | rewrite `/boot/limine.conf`, `limine-update` | the hand-built ESP | never run; DEFER |

Migrations: the policy classes are BOOT, PACCONF, FULL-UPGRADE, PAM, LOGIN-NET, OUR-PKGS (DEFER); USER-CONFIG, SYSTEM-CONFIG, POWER, PKG-REMOVE (REVIEW); PKG-ADD (INFO).
Of the 79 migrations added since v4.5.0: 25 DEFER (24 BOOT, 1 PACCONF, almost all Snapdragon/other-hardware and no-ops here), 14 REVIEW, 16 INFO, 24 SAFE.
`omarchy-migrate-notify` only nags at login; nothing runs migrations behind your back.

## Files

| Path (repo `files/` -> Mac) | Role |
|---|---|
| `usr/local/sbin/m5pro-safe-update` | the tool |
| `etc/m5pro/safe-update/holds.conf` | extra holds, `ignore-required`, pins, protect, watch, required hooks. Edit this to change what is held |
| `etc/m5pro/safe-update/migration-policy.tsv` | migration classes (regex, severity, reason) |
| `etc/m5pro/safe-update/tracked-paths.txt` | generated: `m5pro-safe-update --gen-tracked contrib/omarchy-mac/INVENTORY.md > tracked-paths.txt`. Regenerate when `INVENTORY.md` changes (PRIVATE data and big trees are excluded) |
| `/var/lib/m5pro-safe-update/` | snapshots, `latest`, `deferred.tsv`, `deferred/` (created at run time, PRIVATE to the Mac: hashes and config copies) |

## Native `omarchy update` (2026-11-19)

`omarchy update` (terminal, menu or bar) is now safe to run as is; `m5pro-safe-update --run` stays as the stricter path.
- Holds live in `/etc/pacman.conf` itself: a third `IgnorePkg` line (`# m5pro-local-builds`, also in
  `pacman-conf/pacman.conf.m5pro-snippet`) carries `holds.conf` `hold`, so pacman and `yay -Sua` skip the hypr libraries and
  our own builds. Backup of the old file on the Mac: `/etc/pacman.conf.pre-local-holds`.
- Packages Omarchy's orphan step must keep are marked explicit (`mkinitcpio`, the `protect` list, speaker and UCM builds).
- `files/etc/pacman.d/hooks/10-m5pro-pre-update-snapshot.hook`: `--pre-update` snapshot before any package change
  (reused when under 30 min old, so one update has one baseline).
- `files/etc/pacman.d/hooks/95-m5pro-defer-migrations.hook`: when `omarchy` upgrades, `--defer-pending` marks DEFER-class
  migrations done before `omarchy-migrate` runs them (ledger `deferred.tsv`, `--undefer NAME`).
- `home/.config/omarchy/hooks/post-update.d/90-m5pro-safe-update`: Omarchy's post-update hook runs `--post-update`
  (validation against the snapshot, clobbered system files put back) inside the update's sudo.
- Not covered: the AUR step and the boot verify run after the post-update hook (IgnorePkg protects the AUR step; `/boot`
  is held). The end prompt "Linux kernel has been updated. Reboot?" is always shown here (our kernel's modules are not
  package-owned); answer no unless something asks for a reboot.
- First native run 2026-11-19: 43 upgrades + 2 AUR rebuilds, `/boot` unchanged, 0 failures. Found and fixed: `/boot` is an
  automount, so the snapshot's ESP manifest listed 4 of 495 files (`ESP_CMD` now lists `/boot/` first).

## Undo and repair

- **Package rollback**: the cache is kept. `pacman -Q` vs `/var/lib/m5pro-safe-update/latest/pkgs.txt` shows what moved; `sudo pacman -U /var/cache/pacman/pkg/<old>.pkg.tar.zst` per package (touch `/run/m5pro-touchid-allow-libfprint` first for libfprint; `/etc/m5pro/allow-boot-package-change` for boot packages). Add the package to `holds.conf` so the next run keeps it.
- **Files**: `m5pro-safe-update --restore` (all changed) or `--restore /etc/x.conf`; copies live under `latest/files/<abs path>`. `daemon-reload`/restart units yourself.
- **`pacman.conf` lost its holds**: `/etc/pacman.conf.bak` (Omarchy writes it) or `latest/pacman.conf`; the line is in `contrib/omarchy-mac/pacman-conf/pacman.conf.m5pro-snippet`. The run refuses until `IgnorePkg` is whole again.
- **Deferred migration you want**: `m5pro-safe-update --undefer 1794xxxxxx` then `omarchy-migrate`.
- **Remove the tool**: `sudo contrib/omarchy-mac/install-item.sh --remove safe-update`; `sudo rm -r /var/lib/m5pro-safe-update`. Nothing else was installed; no unit, hook or timer.

## Limits (own them)

- Written offline against Omarchy master 3437cfb and the pkgs repo; the Mac's installed Omarchy is 4.5.0-3, so the first `--dry-run --deep` there is the real test of the file-level scan and of `pacman -Su --print` with the holds.
- Holds are by name. A new Aurora/Omarchy package name for one of our pieces is not held until added to `holds.conf`.
- Deferral decides by regex on the script text; a migration that calls a helper which edits PAM is not seen (the `omarchy-setup-security*`/`omarchy-apply-lock` names are in the PAM class). Review `deferred.tsv` and the REVIEW lines after every run.
- `omarchy-mac` and `omarchy-mac-boot` stay held, so Omarchy features that need a newer `omarchy-mac` (new platform files in `/usr/share/omarchy-platform`) wait for the owner's decision on moving those packages (`desktop.update-path` row, upstream #413/#21/#27).
- Hyprland 0.57.1 stays held; when Omarchy's config needs a newer Hyprland the simulate step says so and the patch has to be re-based first.

## Upstream target

`omacom/omarchy` (proposal only, nothing sent): a `update-holds` lifecycle operation so a platform package can name packages an update must skip, and a documented per-machine list of migrations an update must not run
(today: `/etc/omarchy-mac-boot/owner-boot-chain` for the boot check only; `omarchy-update-orphan-pkgs -y` and `yay -Sua --noconfirm` have no opt-out).
`omacom/omarchy-mac-pkgs`: nothing; this is a Mac-owner policy layer. Everything specific to the J716s stays `none/personal`.
