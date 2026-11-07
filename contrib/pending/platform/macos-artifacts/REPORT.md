# macOS 27.3 artifact pull: report

2026-11-07. No MacBook access, no pushes, no posts. Files in `~/Work/agents/macos-artifacts/`:

- `pull-macos-27.3.sh`: `bash -n` clean, shellcheck clean (two info-level notes). Dry-run tested end to end against the Studio's own
  macOS 27.2 tree through a local stand-in for ssh (full copy 459 MiB, 563 files, manifest written; `--list`, size abort,
  repo-path refusal, no-HOST, unreachable-host and "host is Linux" paths all checked). The test output held Studio serials and was
  deleted. It has never talked to the MacBook.
- `EXTRACT.md`: what each artifact is for, kext carving without root, the first RE step.
- `ASAHI-BLESS.md`: feasibility of selecting the boot volume from Linux, and a proposed (unapplied) DT fragment.

## Run

```
HOST=rolo@<macbook-tailscale-ip> bash ~/Work/agents/macos-artifacts/pull-macos-27.3.sh --list      # inventory and sizes only
HOST=rolo@<macbook-tailscale-ip> bash ~/Work/agents/macos-artifacts/pull-macos-27.3.sh ~/Work/studio-artifacts/macos-27.3/
```

Needs the MacBook booted into macOS (it stops if `uname -s` is not Darwin and warns if `sw_vers` is not 27.3).
SSH uses BatchMode (no password prompt); `SSH_OPTS` adds options. Refuses an output directory under `~/Documents/GitHub`,
under `~/Work/agents` or inside a git work tree; writes a `*` `.gitignore` in the output directory.

## Findings that changed the plan (from reading the Studio's macOS 27.2 tree)

1. **The G17 kexts in `/System/Library/Extensions` are Info.plist stubs** (12 KiB, no executable). The AGX code is only in
   the kernel collection. The kernelcache is the primary artifact, not the kext bundles.
2. **Kernelcache locations that exist** (the brief's `maxdepth 6` find would miss the booted one, depth 8): booted
   `Preboot/<UUID>/boot/<hash>/System/Library/Caches/com.apple.kernelcaches/kernelcache` (IMG4) and `kernelcache.auxkc.<hash>`;
   restore flavour `Preboot/<UUID>/restore/kernelcache.release.<board>` (bare IM4P, easiest for `ipsw`) and a `restore-staged/`
   twin. The script uses a depth-10 search and copies whole `restore/` and `restore-staged/`, which covers
   `Firmware/agx`, `dcp`, `pmp`, `AOP`, `all_flash` and `t2026macG1/Release` if present (tens of MiB).
3. **`kmutil inspect -z --no-variant-extension -B <kernelcache>` works without root** and lists every kext. There is no
   `kmutil` extract; use `ipsw kernel extract` (`brew install ipsw`, core formula) or `pyimg4` + a Mach-O fileset tool.
4. **The Studio is not a G17X baseline**: its collection holds only AGXG14X. The MacBook pull is the only local source for
   `com.apple.AGXG17X`. An older baseline would need Apple's IPSW for the same board.
5. `/System/Library/Kernels/kernel.release.t6050` (plain kernel) exists and is copied for cross-reference.

## ASAHI-BLESS summary

- Real J716s numbers from `adt-runtime-j716s.bin`: `/arm-io/qspi/spinor/anvram` reg 0x700000 / 0xc0000 (12 banks of 64 KiB),
  `/chosen/nvram-proxy-data` 64 KiB v3 blob (`3VVN`).
- Our m1n1 `dt_set_nvram` only looks under `/arm-io/spi1`, so the partition is never filled on T6050.
- `spi-apple-qspi` + DT enable would expose a read-only `/dev/mtd0`. The driver's write gate (`apple_qspi_boards[]`) has no
  t6050/j716s row (nor on J775D), so Linux cannot write NVRAM here until a row with the part's JEDEC ID and block-protect bits
  exists. `asahi-bless`/`asahi-nvram` open the device read+write even for reads, default to `/dev/mtd/by-name/nvram`, and need a
  build that handles 12 NVRAM banks (upstream commit of 2026-05-22). Packaged for Debian, Ubuntu, Fedora, Gentoo; no Arch/AUR
  package found by web search (not checked on the AUR itself).
- No unattended round trip: macOS-side `bless --setBoot`, `systemsetup -setstartupdisk` and `nvram` writes need admin/root.
  Best loop: Linux writes a next-boot-only flag (`alt-boot-volume`), a human restarts out of macOS, the Mac returns to the
  Linux stub. One-shot consumption on M5 is unverified.
- DT patch for `&qspi` + `nvram` partition (static `<0x700000 0xc0000>`, 25 MHz, single-wire, J775D sibling) is in
  `ASAHI-BLESS.md` section 6 as a proposal; not written as a file.

## Not done / unverified

- `ipsw` and `pyimg4` are not installed here; their exact subcommands were taken from docs (`ipsw kernel kexts|extract`
  confirmed in the project README; `pyimg4` and `ipsw kernel dec` verbs flagged as unchecked in EXTRACT.md).
- Which of the AGX kexts in the MacBook's kernelcache and which `restore/` layout the 27.3 stub volume has are unknown until `--list`
  runs on the real machine.
- Whether the kernelcache IMG4 on the stub's Preboot UUID differs from the macOS volume's: the script takes every UUID.
