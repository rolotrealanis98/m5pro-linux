# m5pro-boot: the update/recover CLI for the J716s (gap-map row `dist.aurora-cli`)

Status: written and unit-tested offline on the Studio (41 tests, fake root + fake ESP directory, `python3 -I -B tests/test_m5pro_boot.py`).
**Never run on the Mac.** First run: `/Volumes/m5pro/bench/requests/dist-cli-1.md` (read-only `status`, then dry runs).

It packages the hand tools: `mk-daily.py` (build), `esp-put.sh` (the flush protocol), the deploy plan in `mk-daily.py` (A/B swap),
`m5-selftest` (self-revert), `host/macos/r1-deploy.sh restore` (rollback) and the stub-refresh ceremony notes. Policy it enforces:
`contrib/validated/aurora/tools/ESP-POLICY.md`. Stdlib Python, one file.

## Commands

| Command | Writes | Does |
|---|---|---|
| `status [--json]` | nothing | slot booted (`/proc/device-tree/chosen/m5pro,boot-slot`: `primary`, `fallback`, `...-after-failure`), which ESP file that means, every `boot.bin*` (sha, size, kernel, loader, test/daily), strays, free space, staged payloads, stale-vs-installed kernel. Exit 1 if there is a PROBLEM line |
| `build --daily` / `build --test --label L` | `/var/lib/m5pro-boot/payloads/` only | loader + `chosen.bootargs` + `show-notch` + `Image.gz` + DTB + gzip initramfs from the **installed kernel package** (`/usr/lib/modules/<kver>/vmlinuz` and `dtbs/t6050-<board>.dtb`, board from the device tree), parsed back and compared part by part, recipe `.json` and `SHA256SUMS` beside it. Test = `m5.selftest=1`, daily = without. Command line: `--cmdline`, else `/etc/m5pro/cmdline`, else the running `/proc/cmdline` minus `BOOT_IMAGE` and `m5.selftest` |
| `verify FILE\|prev\|boot\|b2\|known-good` | nothing | re-parses a payload: loader size/STACKBOT, one gzip kernel, DTB totalsize and `apple,<board>`, one-member gzip cpio initramfs |
| `install [PAYLOAD\|latest]` | dry run | prints the plan; `--apply` runs it (below) |
| `promote` | dry run | the running payload is a test that reached the network: rebuild the same ingredients as a daily (refuses if an ingredient changed) and install it |
| `rollback [--to prev\|b2\|known-good]` | dry run | copies that slot over `boot.bin` through `.new`, sha-verified; the slot stays; the bad `boot.bin` is saved under `/var/lib/m5pro-boot/failed/` (never on the ESP) |
| `confirm [--wait S]` | `/var/lib/m5pro-boot/running.json` | records which payload this boot loaded (by slot) and whether the network is up; run at boot by `m5pro-boot-confirm.service` |
| `selftest-watch` | ESP on failure | body of `m5pro-boot-selftest.service` (`ConditionKernelCommandLine=m5.selftest=1`): 90 s after network-online, route + ping; failure saves logs to `failed/selftest-*/`, copies `boot.bin.prev` over `boot.bin`, reboots; a `reverted-once` guard stops a second revert (no loop) |
| `hook` | staging (ESP only with `AUTO_INSTALL=test`) | the pacman hook body, below |
| `stub-checklist [--json]` | nothing | the stub-refresh procedure after a macOS update, with the facts Linux can read (`/chosen/firmware-version` = stub mBoot, `/chosen/system-firmware-version` = LLB, supported table, slot) |

## `install --apply`, step by step (ESP-POLICY.md, esp-put.sh)

1. Preflight: ESP mounted (it mounts `ESP_DEV` if not), no name outside `boot.bin{,.prev,.b2,.known-good}` (a stray `boot.bin.r3q` refuses), free space >= 2 payloads + 20 MB, stale `boot.bin.new` / `boot.bin.prev.new` removed.
2. Payload parsed (as above), board must match this machine, **mode rules**: a test payload must carry `m5.selftest=1`, a daily must not (`--force` overrides).
3. `boot.bin.new` written, fsync, sha256 read back. Nothing replaced yet.
4. **prev rotation, only from a running daily that reached the network**: prev := the payload that is *running* (not whatever sits in `boot.bin`: that may be an installed-but-unbooted payload). Running = recorded at boot by `confirm`, else derived from the slot with the ESP file older than the boot. Prev stays when: running is a test, running is the new payload, prev already is the running payload (fallback boot), the network was not seen, or the running payload cannot be told.
5. `mv` into place with fsync of file and directory; then the esp-put flush: unmount, device FLUSH, drop caches, remount **read-only**, cold re-read of every written file, settle (60 s).
6. Reboot is never done by the tool.

Failure model: every step before the final `mv boot.bin.new boot.bin` leaves `boot.bin` and `boot.bin.prev` as they were; a mismatch anywhere refuses with nothing replaced. Verified by the tests (corrupted copy, stray file, low space, truncated payload, wrong board, running test, fallback boot, no network, unbooted boot.bin).

## The pacman hook (`hooks/96-m5pro-boot.hook`)

After `90-mkinitcpio-install.hook`, when `usr/lib/modules/*/vmlinuz`, the aura-j716s loader or `/usr/lib/asahi-boot/m1n1.bin` changes: builds a **test** payload `pkg-<kver>` and prints the install plan, **dry run** (the ESP is not touched). `AUTO_INSTALL=test` in `/etc/m5pro/boot.conf` also installs it as the self-reverting test `boot.bin`. A daily is never installed by a hook: boot the test, `m5pro-boot status`, `m5pro-boot promote --apply`. The hook exits 0 whatever happens (a PostTransaction hook cannot undo the upgrade) and says `NOT updated` plus that `boot.bin` still boots the old kernel. Off the Mac (no `apple,t6050` root) it is a no-op.

## What it replaces, and what it does not touch

| Asahi / Aurora | Here |
|---|---|
| `update-m1n1` (cat m1n1 + vars + DTBs + kernel + initramfs into `boot.bin`) | `build` + `install` (A/B, hash-checked, one DTB for this board) |
| `aura recover`, `asahi-diagnose` | `status`, `rollback`; stage-1 level recovery is macOS-side (`host/macos/r1-deploy.sh restore prev`), see checklist |
| `asahi-fwupdate` | not here: `m5pro-firmware` / the macOS-side extraction; `stub-checklist` says when it is needed |
| `asahi-bless` / Startup Disk | `aurora-bless` and `omarchy-mac/startup-disk` (unchanged) |
| `m5-selftest.service` (hand-installed) | `m5pro-boot-selftest.service` (`Conflicts=` the old one; disable it first) |

Does **not** touch: stage 1 (only macOS in the paired 1TR can), NVRAM, the stub, firmware, `boot.bin.b2`, `boot.bin.known-good` (read for rollback, never written), the initramfs-side installer of the old test payloads (the watchdog lives in the root now, so a payload built from a package kernel needs no special initramfs; limit unchanged: it exists only once the root has mounted, a payload that never mounts the root is not reverted, the stage-1 PMU A/B fallback and macOS recovery cover that).

## Needs from the other packages

- A kernel package that installs `/usr/lib/modules/<kver>/{vmlinuz,pkgbase,dtbs/t6050-j716s.dtb}` and a mkinitcpio preset writing a **gzip** image to `/var/lib/m5pro-boot/initramfs-<pkgbase>.img` (`packages/linux-aurora-j716s`). A stock `linux-aurora` has the DTB only if it carries the J716s board (it does at 7.3.0-1: the file exists, see packages/README.md) but the preset writes zstd to `/boot`: `build --initramfs` can point at a gzip image.
- A stage-2 loader image at `/usr/lib/aura-j716s/aura-stage2.bin` (`packages/aura-j716s`) or `/usr/lib/asahi-boot/m1n1.bin`. Plain stage 2 (not `ESP_STAGE2=1`) is what the J716s runs today: see `contrib/pending/boot-aura/PORT.md`.

## Known limits (honest list)

- The stub-refresh table (`SUPPORTED_FW`) holds the two mBoot builds this repo has seen (`20457.41.*` = 27.2, `20457.60.*` = 27.3 beta 1). Anything else is "not known to the loader/kernel": add it only after aura's firmware table and the kernel's `hw/t6050.rs` learned it.
- The running-payload record is per boot. If `confirm` did not run and `boot.bin` was rewritten since boot, prev is simply not rotated (safe, but then prev can be older than you expect: the status line says so).
- Real-ESP behaviour (`mount`, `umount`, device `fsync`, `drop_caches`) follows `esp-put.sh` but is exercised only by the fake-ESP tests' file-level half. First use on the Mac is a dry run.
- The derived running-payload fallback compares the ESP file's mtime with the boot time; FAT stores local time without a zone, so mount the ESP with `tz=UTC` (or rely on `confirm`, which records it at boot). A wrong guess only ever keeps prev.
- Boot guard (refusing a transaction that swaps the boot packages for another repo's) is not carried; it stays in `contrib/distro/pkg/m5pro-boot`.
