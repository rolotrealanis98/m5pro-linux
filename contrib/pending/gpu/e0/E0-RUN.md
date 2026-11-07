# E0 on the J716s: PMP and GPU power-state readback

Step E0 of the GPU plan (`contrib/pending/gpu/hwdata/ANALYSIS.md`, section 4). Read-only. No GPU node, no
Rust, no new kernel. One script: `e0-readback.sh` (extends `contrib/pending/integration/r1/pmp-readback.sh`,
which is untouched). It has run only against a mock reader on the Studio (syntax, dry-run and the verdict
paths); it has never touched the MacBook.

## Run it

As root on the normally booted daily kernel, from wherever the script was copied (the ESP root works,
next to `r1-local.sh`):

```
bash e0-readback.sh --dry-run     # validates the plan, prints every address, reads nothing
bash e0-readback.sh               # stages 1, 1b, 1c
```

Optional, off by default:

- `--with-asc` adds stage 2, ASC `CPU_CONTROL` / `CPU_STATUS` (0x284e00000 + 0x44 / 0x48). Only worth it on the
  m1n1 that opens the dart-pmp0 DAPF (`PMP-READBACK.md`); the script skips it by itself if the running
  m1n1 is not that build. Gives the "PMP stopped" half of "stopped + cold".
- `--extra-ps` adds stage 1d, five more GFX-adjacent PS words (0x2380600108/110/118/128/198, names from
  `PMP-J716S.md`). That block is not otherwise touched by our DT; run it as a second pass, after the main
  run came back clean.
- `--reader busybox|python`, `--force-sram`, `--force-asc`, `--out DIR` as in the script header.

Logs go to `/boot/r1-logs/e0-<UTC time>/` (`README.md` with the plan, `readback.log`, `values.tsv`,
`system.txt`, `dmesg-after.txt`). The last line of `readback.log` is `VERDICT: ...`. Bring back `values.tsv`,
`readback.log` and `system.txt`; `system.txt` already holds the genpd summary the plan asks for.

## Can /dev/mem read these on our kernel?

Both configs (`wt-series-out` 7.3.0-g4f630b11270d and `wt-betizzel-out` 7.3.0-gf080637018df) have
`CONFIG_DEVMEM=y`, `CONFIG_STRICT_DEVMEM=y`, `# CONFIG_IO_STRICT_DEVMEM is not set`,
`# CONFIG_SECURITY_LOCKDOWN_LSM is not set`, 16K pages, `CONFIG_IKCONFIG=y` (so `/proc/config.gz` exists
and `system.txt` records it).

What `STRICT_DEVMEM=y` means here (checked in `lib/devmem_is_allowed.c` of the series tree, which arm64
uses): a page is refused only if it is "System RAM" or an iomem resource claimed `IORESOURCE_EXCLUSIVE`.
Every address in the plan is above 0x2_0000_0000 (arm-io), is not RAM, and no DT node of ours claims it
exclusively, so `mmap` of `/dev/mem` works for all of them. `read()`/`dd` on `/dev/mem` does not work for
MMIO on arm64 (it goes through the linear map); the script uses `mmap` only. arm64 maps a non-RAM page
Device-nGnRnE, so each read is one real 32-bit bus load.

If a read is still refused (EPERM / "Operation not permitted" shows as ERR in `readback.log`):

1. `/proc/iomem` shows an exclusive claim over that window: check `system.txt`, section "iomem around the
   windows read". Nothing to do but pick another reader path.
2. Alternatives, in the order I would try them. None needs a kernel rebuild except the last.
   - `--reader python` (the script's default when no busybox with the `devmem` applet exists): `mmap` of
     `/dev/mem` read-only, `memoryview.cast("I")`. Same kernel path as busybox `devmem`, so it only helps
     when the failure is the tool, not the kernel.
   - `/sys/kernel/debug/pm_genpd/pm_genpd_summary` (debugfs is `=y`): the kernel's cached power state,
     no MMIO. Does not exist yet for gpx/afr/cs/gfx (no DT nodes), so it only covers the PMP/PMS domains.
   - `/sys/kernel/debug/regmap/<pmgr>/registers`: only for the pmgr syscon that the DT declares, and it
     dumps the whole range, which `PMP-READBACK.md` deliberately avoids. Not a replacement for stage 1c.
   - There is no generic debugfs MMIO peek, and `iomem=relaxed` is x86-only. The last resort is a build with
     `CONFIG_STRICT_DEVMEM=n`, or a ten-line read-only module doing `ioremap` + `readl`.

## What the script reads, and why it cannot hurt (as far as userspace can tell)

All reads are one aligned 32-bit load, `PROT_READ`, one short-lived process each. The script never writes a
device register. Before the first read it validates the whole plan and aborts with exit 3 on anything
unexpected (also in `--dry-run`): width other than 4, misaligned address, an address outside the allowed ADT
device-MMIO windows (listed by `--dry-run`), a stage-1b plan that is not exactly the eight words
0x2_8457_bcc0..bcdc, or, when `/proc/iomem` is readable, any address inside a "System RAM" entry. Before every
read, `about to read <addr>` is written and synced, so after a hang the last such line on the ESP names the
register. A read that times out (5 s) makes the script stop touching MMIO.

Not catchable from userspace: an asynchronous SError (arm64 Linux panics without RAS) or a fabric hang. The
A/B stage-1 watchdog resets a hang after 150 s. Order of reads, safest first: stage 1 (PMGR block the kernel
already reads), 1b (SRAM, only if both PMP gates read actual=0xf, else skipped), 1c (group-3 PMGR, a block
no driver of ours touches yet), then the optional 1d / 2.

## Values and what they mean

PS word layout (as in `pmp-readback.sh`): bits 3:0 target, 7:4 actual (0xf on, 0x4 clock-gated, 0x0 off),
8 was-pwrgated, 9 was-clkgated, 10 dev-disable, 11 parent-off, 27:24 auto, 28 auto-enable, 31 reset. The
script prints this decode under each PS word. Bit 18 in the expected GFX word is not in that layout; it is
compared as part of the exact value.

| stage | address | what | expect | reading it |
|---|---|---|---|---|
| 1 | 0x2_8060_0128 | PMGR PS PMP (ADT gate 27) | actual 0xf (ADT critical) | `actual != 0xf` makes stage 1b skip: the SRAM may be unpowered |
| 1 | 0x2_8060_0130 | PMGR PS PMS_SRAM (gate 28) | actual 0xf | same |
| 1b | 0x2_8457_bcc0, bcc4, bcc8, bccc, bcd0, bcd4, bcdc | PMP SRAM, cold-marker zeros | 0x00000000 each | the t6050/pmp driver wants zeros at +0x7bcc0..+0x7bce0 |
| 1b | 0x2_8457_bcd8 (SRAM +0x7bcd8) | PMP SRAM cold marker | 0xfeed1b00 | marker present: image is in SRAM, never started |
| 1c | 0x23_00e8_0000 | PS GPX (group 3 +0x0, ADT critical) | none recorded | recorded; parent of GFX |
| 1c | 0x23_00e8_0100 | PS AFR (+0x100, ADT critical) | none recorded | recorded; parent of CS and GFX |
| 1c | 0x23_00e8_0108 | PS CS (+0x108, parent AFR) | none recorded | recorded |
| 1c | 0x23_00e8_0110 | PS GFX (+0x110, parents AFR, GPX; notify_pmp, id1 16) | `0x0f040300` (off, auto) | actual nibble 0 = GFX is off, which is what E1's genpd power-on expects |
| 2 (opt.) | 0x2_84e0_0044 / 48 | ASC CPU_CONTROL / CPU_STATUS | RUN = 0 (bit 4) | RUN = 1 means the PMP was started by someone |

ANALYSIS gives one expectation for the GPU group (GFX) and the PMP; GPX/AFR/CS are recorded without a
verdict because nobody has an expected value for them. Stage 1b deviates from "..bce4" in the prompt only
in using the analysis's own eight-load range (0xbcc0..0xbcdc; the driver's zero check ends at +0x7bce0).

## Result: E1 or stop

The script ends with one verdict line; this is the rule behind it.

**GO E1** (the verdict says `GO E1`) when all of these hold:
- stage 1 and stage 1c all read `ok` (no SIGBUS, no timeout, no ERR, no 0xffffffff),
- the GFX word is readable with actual nibble 0 (off). Exactly 0x0f040300 is the clean case.

**GO E1 with caveats** (verdict lists each deviation; still go, but write them down, they change E3/the notes, not E1):
- stage 1b not all-match (marker absent or other words non-zero): the t6050/pmp driver would refuse the PMP
  as cold on our stub. E1 does not touch the PMP, so it proceeds; the "iBoot loads the PMP and leaves it
  stopped" claim in ANALYSIS section 3 needs revisiting. If `--with-asc` showed RUN = 1, the PMP is already
  running: E3 must not run with it in that state (ANALYSIS risk list).
- stage 1b skipped because a PMP gate was not actual 0xf: cold state unknown; rerun after the PMP/PMS_SRAM
  domains are on, or with `--force-sram` if you accept reading possibly unpowered SRAM.
- GFX word is not exactly 0x0f040300 but actual nibble is 0: other bits differ (was-gated, auto field).
  Record it; E1 proceeds.
- GFX already on (actual nibble not 0): something (iBoot or m1n1) powered it. E1's power-on is then a no-op;
  proceed, and keep the genpd state check before the driver binds.
- a stage 1b / 1d / 2 read faulted: that window is not readable the way we assumed; E1 does not depend on it.

**STOP, do not go to E1** (the verdict says `STOP`) on any of:
- a stage 1 or stage 1c read gave SIGBUS, TIMEOUT or ERR, or returned 0xffffffff, or the GFX word was not
  read at all. E1 makes the driver touch `sgx` with GFX powered through exactly these registers; if the
  power-state registers themselves fault or hang, the address model (group 3 at 0x23_00e8_0000, offsets
  0x0/0x100/0x108/0x110) or the fabric access is wrong and E1 would risk an SError on the first `sgx` read.
  Fix the model first (re-read `pmgr` reg[51] and ps group 3 in the ADT, try the second PMGR instance via
  `--extra-ps`), then repeat E0.
- the machine hangs or panics during the run: the last `about to read` line in `readback.log` on the ESP is
  the offender; do not rerun that stage.

Exit codes: 0 finished (read the verdict), 1 not root / no `/dev/mem` / no reader, 2 bad option, 3 plan
validation failed (nothing was read).
