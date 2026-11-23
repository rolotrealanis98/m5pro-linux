# Packages for a stranger's J716s (gap-map row `dist.packages`)

Written 2026-11-23, offline on the Studio. **Nothing here has been built under makepkg or run on the Mac.** The recipes are in omarchy-pkgs' style
(read: `pkgbuilds/linux-aurora`, `m1n1-aurora`, `aura`, `mesa-aurora`, `aurora-audio` at omarchy-pkgs master `5c1116585c93`) and syntax-checked with `bash -n` and a
`source`-and-print pass. The CLI that installs payloads built from them is `../aurora-cli/`.

## What upstream looks like today (read-only `gh`, 2026-11-23): the gap-map row is stale in three places

| Gap-map says | Now |
|---|---|
| "omarchy-pkgs linux-aurora is 7.2.11 without T6050 DTBs" | linux-aurora is **7.3.0** (`aurora-7.3.0-1`, omacom/linux-aurora commit `3058cc5cccb9`). Its tree already has 43 `t6050-*` files incl. `t6050-j716s.dts` and the Makefile line. It has no `j716s.config` and none of our GPU/DCP/ANE/camera/N1/sleep work |
| "m1n1-aurora lacks #30-#37" | omacom/m1n1: **#31 and #32 merged**; #30, #33, #34, #35, #36, #37 open. On edge, **`aura` replaces m1n1-aurora** (omarchy-pkgs `aura` 1.0.0b13, `703a0a92`), with the 7.3 kernel; aura carries most of that list natively (`boot-aura/PORT.md`) |
| "mesa-aurora has no G17" | G17 (aurora-silicon/mesa #194, merged 2026-11-10) and the M5 Pro admission (#348) are both in the pinned Mesa. See `mesa-aurora/README.md` |
| "aurora-audio has no J716 graph" | still true: upstream has J616s only. Our J716 UCM/jack/mic profile is `aurora-audio-j716` |

## Status

| Package | What | State | Waits for |
|---|---|---|---|
| `linux-aurora-j716s/` | 7.3 kernel from `rolotrealanis98/linux` `j716s-ane2293` (`0c6bb36ed14a`), `defconfig asahi.config j716s.config j716s-gpu.config` + a distro fragment, DTBs flat in `dtbs/` (incl. `t6050-j716s.dtb`), gzip mkinitcpio preset into `/var/lib/m5pro-boot/`, headers split | **recipe written, unbuilt**. Toolchain asked for is the Studio's (rustc 1.99.1 + the tree's `aurora-bindgen`, `LLVM=1`), not omarchy-pkgs' clang18 + rust 1.85 [unverified in an Arch container] | (1) the branch pushed: `j716s-ane2293` is not on origin (`j716s`, `j716s-next` are); (2) omacom/linux-aurora **#413** (J716s board, open) plus follow-ups, after which this shrinks to a pin bump + `j716s.config` on omarchy-pkgs' own `linux-aurora`; (3) one Arch-container `makepkg` run and one boot of the result |
| `aura-j716s/` | plain aura stage 2 (`j716s-s2r-ext-cam2` `bfb36556`, on `rolotrealanis98/aura`): `aura-stage2.bin` (no host window, the daily's variant) and `aura-stage2-hostwait.bin`; links `/usr/lib/asahi-boot/m1n1.bin`; provides `m1n1`/`aura`, conflicts with them | **recipe written, unbuilt**; the Studio builds the same tree family (`build-stage2.sh j716s`); aura stage 2 is the daily loader (COMMON.md 2026-11-22). Which exact aura commit the daily runs was not checked: confirm `_commit` against the loader's version string before building | aurora-silicon/aura **#274** and its split (J716s 27.3 DCP/GPU rows, wdt-keep, RVBAR, dapf, display) merging; then depend on `aura` and delete this. For m1n1-aurora users the same list is omacom/m1n1 #30, #33-#37 |
| `mesa-aurora/` | no recipe: use omarchy-pkgs' | n/a | one hardware run of the packaged Mesa (`e705eca833f3`) on the J716s |
| `aurora-audio-j716/` | J716 UCM (`AppleJ716`: speakers/jack), mic-array UCM + WirePlumber + `mic.json` (`AppleJ716HPAI`), jack and Bluetooth routing, in aurora-audio's file-addition style. Speaker voicing is **not** in it | **recipe written, unbuilt**; files are the ones in use on the Mac | upstream taking J716 entries (aurora-silicon/asahi-audio, alarm-aurora `alsa-ucm-conf-asahi`); the listening-test sign-off; speaker side belongs to `speakerguardd-v2` + `aurora-speaker-upgrade` (speaker agent, `distro/pkg/`) |
| `omarchy-mac-t6050/` | five static settings: s2idle lid sleep, xhci wake-up rule, `dmesg_restrict=0`, thunderbolt_net load, PipeWire RT limits | **recipe written, unbuilt**; files verbatim from `contrib/omarchy-mac/*/files` | nothing to build; upstream homes are `aurora-system-fixes` (alarm-aurora) and omacom/omarchy-mac-pkgs; the xhci rule dies with the DT `wakeup-source` fix |
| `../aurora-cli/` | `m5pro-boot-cli` (`m5pro-boot`, pacman hook, confirm and selftest units) | **written, 41 unit tests pass; never run on the Mac** | `dist-cli-1` (read-only + dry runs), then `dist-cli-2` (`--apply` of a test payload) |

Also relevant and not mine: `distro/pkg/{m5pro-boot (0.2.0, older layout and the boot guard), linux-m5pro, m1n1-m5pro, m5pro-firmware, avd-fw, mesa-aurora, speakerguardd-v2, aurora-speaker-upgrade}`. The new `m5pro-boot-cli` conflicts with `m5pro-boot`; the guard hooks need splitting into their own package before the old one retires.
`aurora-bless` (startup disk) and `libfprint-aurora`/Touch ID stay as they are (omarchy-pkgs has `aurora-bless`; libfprint is the Touch ID agent's).

## Not packaged, and why

`safe-update` (an `omarchy update` guard for a hand-built system; obsolete once these are packages), `boot-selftest` (replaced by `m5pro-boot-selftest.service`), `usb-pd-rebind` (stopgap until the tipd fix; `/usr/local/bin` path), `tty2-autologin`, `lock-at-login`, `startup-disk`, `touch-id` and the plugins (user accounts, other agents), `rescue` (default user `rolo`), `camera-*` (stage staged/experimental), `widevine`.

## Building

On an Arch Linux ARM aarch64 box or container (the Studio's `container` has no Arch image yet):

```sh
cd contrib/distro/packages
./mk-source.sh omarchy-mac-t6050 && ./mk-source.sh aurora-audio-j716    # tarballs of the exact repo files; paste the printed sha256 into each PKGBUILD
(cd omarchy-mac-t6050 && makepkg -f)
(cd aurora-audio-j716 && makepkg -f)
(cd aura-j716s && makepkg -f)                  # after the aura branch is pushed
(cd linux-aurora-j716s && makepkg -f)          # after the kernel branch is pushed; ~1 h, 16 GB
(cd ../aurora-cli && updpkgsums && makepkg -f) # runs the unit tests in check()
```

Do not build the kernel on the Studio while other agents need its build container: the `pr-verify` scripts remain the way to build and test a kernel there.
Order on a fresh Mac: `aura-j716s`, `linux-aurora-j716s`, `m5pro-boot-cli` (the hook then prepares a test payload, dry run), `aurora-audio-j716`, `omarchy-mac-t6050`.

## Upstream merges each piece is waiting for (one list)

1. omacom/linux-aurora #413 (J716s board) and the follow-up PRs for the rest of our branch.
2. aurora-silicon/aura #274 (+ split) -> then `aura-j716s` disappears.
3. omacom/m1n1 #30, #33-#37 (only if m1n1-aurora stays the loader on edge).
4. alarm-aurora / asahi-audio J716 entries, then the speaker side after the listening test.
5. omacom/omarchy-pkgs: a PR adding the J716s items (`linux-aurora` pin + `j716s.config`, `aura` pin) once 1 and 2 are in; Omarchy's CI builds aarch64 there.
