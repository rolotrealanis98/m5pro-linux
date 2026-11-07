# E0 readback script and kernel modules (2026-11-07)

Files in `~/Work/agents/e0-and-modules/`: `e0-readback.sh`, `E0-RUN.md`, `MODULES.md`, `REPORT.md`,
`modules-7.3.0-g4f630b11270d.tar.zst` (series), `modules-7.3.0-gf080637018df.tar.zst` (WFI), `SHA256SUMS`,
`build-modules.sh`, `closure.py`, `resolve.py`, `targets-{series,wfi}.txt`, `build-*.log`, `modstage-*/`.
Nothing was pushed, posted or run on the MacBook; no secrets in any file.

## Task A: `e0-readback.sh` (E0-RUN.md has the detail)

- New script, `pmp-readback.sh` untouched. Stages: 1 (PMGR PS PMP 0x280600128, PMS_SRAM 0x280600130), 1b (eight
  SRAM words 0x28457bcc0..bcdc, 0xfeed1b00 expected at 0x28457bcd8, zeros elsewhere), 1c (group-3 PS words GPX
  0x2300e80000, AFR +0x100, CS +0x108, GFX +0x110, GFX expected 0x0f040300). Optional `--with-asc` (CPU_CONTROL/STATUS)
  and `--extra-ps` (five more GFX PS words from PMP-J716S.md), both off by default.
- Read-only by construction: one aligned 32-bit `PROT_READ` mmap load per process. All guards run before the first
  read and in `--dry-run` (exit 3 on failure): width must be 4, alignment, address inside an allowed ADT
  device-MMIO window, stage 1b exactly 8 words in the 1 MiB SRAM window, and, on the MacBook, no address inside a
  `System RAM` entry of `/proc/iomem`. Each read is announced and synced to the ESP log first; a timeout stops all
  further MMIO. SRAM reads are skipped unless both PMP gates read actual=0xf.
- It ends with a verdict line: `GO E1`, `GO E1 with caveats; ...`, or `STOP: ...`. STOP = a stage 1/1c read faulted,
  timed out, returned 0xffffffff or the GFX word was unreadable. Cold-marker mismatch, a GFX word other than
  0x0f040300, or a faulting optional stage are caveats, not stops (E1 does not touch the PMP).
- Tested here: `bash -n` under bash 3.2, 5.3; `--dry-run` (plain, `--extra-ps --with-asc`, bad option); and eight
  scenarios against a mock `busybox devmem` (clean, no marker, GFX on, SIGBUS, all-ones, SRAM SIGBUS, gate off, hang).
  Verdicts came out as designed. It has not touched real hardware.
- /dev/mem: both configs have `DEVMEM=y`, `STRICT_DEVMEM=y`, `IO_STRICT_DEVMEM` unset, no lockdown LSM. Checked in
  `lib/devmem_is_allowed.c`: strict mode only refuses RAM pages and exclusive iomem claims, so these MMIO windows
  are readable via mmap. Fallbacks (python mmap, genpd summary, regmap debugfs, a read-only module) are in E0-RUN.md.
- One deviation: stage 1b reads the analysis's eight words (0xbcc0..0xbcdc) rather than also 0xbce0/0xbce4, because
  the driver's zero check ends at +0x7bce0.
- I could not see the 11-03 PS table, so GPX/AFR/CS have no expected value (recorded only); `--extra-ps` names come
  from PMP-J716S.md.

## Task B: modules (MODULES.md has the detail)

- Both configs have 1539 `=m` options (identical sets) and no `.ko` existed. I built 170 modules per kernel (the J716s-
  relevant ones plus their closure, 0 unresolved symbols) and tarred them under `usr/lib/modules/<release>/`;
  vermagic equals each Image's own release string. Series used `KERNELRELEASE=7.3.0-g4f630b11270d` because HEAD
  moved (DTS only) since the Image was built.
- Not a full `make modules`: ~4,900 compile units against a volume with 5.3 GiB free at the start, 1.4 GiB (99 %) now.
  `modules_install` therefore could not be used; `build-modules.sh` stages the same layout.
- Install: `tar -C / --zstd -xf modules-<release>.tar.zst` then `depmod <release>`; `uname -r` must match.
- Findings that matter more than the modules: `TUN=y` (Tailscale's tun works built in, nothing to change), no
  kernel WireGuard (not needed by Tailscale), but the series `.config` has almost no netfilter (no NF_NAT, NFT_CT,
  NFT_NAT, NF_TABLES_IPV4/INET, NFT_LIMIT/REJECT) and no `IP_ADVANCED_ROUTER`/`IP_MULTIPLE_TABLES`. `ufw`/iptables-nft
  and Tailscale subnet/exit-node features will fail until the integration tree's `omarchy-desktop.config` (patch
  0033, all `=y`) plus the two routing options go into the next Image. No module tarball can supply those.

## Things to know

- I stopped a full `make modules` after ~1,900 objects; those objects (~1.2 GiB) remain in `wt-series-out`, and I did
  not clean them. Free space on `/Volumes/linux-cs` is now 1.4 GiB; other builds there are at risk.
- Twice a `make` I launched without its target list (a script bug, fixed) started building the default `all` target in
  `wt-series-out` for under a minute before I killed it. `vmlinux`, `Image` and `Image.gz` are unchanged in both out
  dirs (mtimes checked) and `kernel.release` is intact. It did regenerate `t6050-j716s.dtb` in `wt-series-out`.
- I once ran a broad `pkill -f Makefile` while another agent's `make O=.../wt-prs-out dt_binding_check` was in flight;
  that job was still running afterwards, but if the board-pr check reports a killed make, rerun it.
