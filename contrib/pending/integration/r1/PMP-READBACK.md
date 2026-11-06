# pmp-favour: J716s PMP facts, dart-pmp0 DAPF m1n1, Linux readback (2026-11-06)

For omacom/linux-aurora #293 (edimoldovan's J714c PMP findings, joshuaswarren's PMP-window ask).
Nothing here has run on hardware, and nothing has been posted.

| file | what |
|---|---|
| `PMP-J716S.md` | J716s ADT PMP facts side by side with edimoldovan's J714c values. Postable |
| `REPLY-DRAFT.md` | 200-word draft reply for #293 (not posted) |
| `pmp-readback.sh` | read-only `/dev/mem` readback to run as root on the MacBook after booting R2-C |
| `adt-pmp-extract.py` | prints every ADT value used in `PMP-J716S.md` (offline, m1n1 `adt.py`) |

The m1n1 work is in `~/Work/agents/m1n1-r2/` (patch `patches/0019-...`, `BUILD.md`, `TEST-NOTES.md`).
Payloads `R2-C-usbhost-battery-pmpdapf.bin` and `R2-D-olddtb-battery-pmpdapf.bin`, plus
`SHA256SUMS-r2cd`, are in iCloud `m5pro-r1/`.

## Can Linux read MMIO through /dev/mem on our kernel?

Yes, through `mmap` only. From `integration/r1/config.before-desktop` (kernel 7.2.2):
`CONFIG_DEVMEM=y`, `CONFIG_STRICT_DEVMEM=y`, `# CONFIG_IO_STRICT_DEVMEM is not set`,
`# CONFIG_SECURITY_LOCKDOWN_LSM is not set`, 16K pages.

- With `STRICT_DEVMEM` and no `IO_STRICT_DEVMEM`, the generic `devmem_is_allowed()` refuses RAM. It
  allows any non-RAM page unless a driver claimed it with `IORESOURCE_EXCLUSIVE`. The PMP window
  `0x284e00000` has no driver in our DT. The PMGR block `0x280600000` is used by the pmgr-pwrstate
  syscon (busy at most, not exclusive). Both are readable.
- arm64 maps a non-RAM `/dev/mem` page as Device-nGnRnE, so each load is one real 32-bit bus read.
- `dd`/`read()` on `/dev/mem` cannot do it: `read_mem()` translates through the linear map, which
  has no MMIO. debugfs has no generic MMIO peek either. The pmgr regmap's `registers` file would read
  the whole PMGR range, so the script does not touch it.
- Readers: `busybox devmem ADDR 32` (a volatile 32-bit load) if a busybox with the `devmem` applet is
  installed. Arch's `/usr/lib/initcpio/busybox` is tried too. Otherwise python3: `mmap` of
  `/dev/mem` read-only, then `memoryview.cast("I")[0]`, a fixed 4-byte copy that compiles to one
  `LDR`. Each read runs in its own process.

## Readback order and risk (`pmp-readback.sh`)

1. Stage 0, no MMIO: kernel, `asahi,m1n1-stage2-version` (must be `v2.0.0-71-gd5b29b03`),
   firmware versions, devmem config, `/proc/iomem`, the genpd summary.
2. Stage 1, safest: PMGR PS registers PMP `0x280600128` and PMS_SRAM `0x280600130`. The kernel's
   pmgr driver reads these anyway. `--gates-only` stops here.
3. Stage 2: ASC `CPU_CONTROL` `+0x44` and `CPU_STATUS` `+0x48`. Runs only if both gates read
   actual = 0xf and the 0019 m1n1 is running (`--force-asc` overrides).
4. Stage 3: mailbox control words `+0x8110` and `+0x8114`. The message registers `+0x8800..0x883f`
   are never read: reading the outbox pops its FIFO.
5. Stage 4, riskiest: hexdump of ASC `+0x0..+0xfc` in 4-byte reads, stopping at the first failure
   (`--hexdump-bytes` up to 0x1000, `--no-hexdump` to skip).

What can go wrong, plainly:

- If the DAPF did not open the window, the read takes a synchronous external abort. From EL0
  that is a SIGBUS to the reader process: logged, and the run stops reading the ASC.
- If the block is power- or clock-gated, or a register does not exist, Apple SoCs often answer
  with an asynchronous SError. The DAPF entry does not help with that. Without the RAS extension, arm64
  Linux panics on an SError, and the machine stops (our cmdline has no `panic=`, so hold power). Some
  accesses just hang the fabric with no error at all; edimoldovan saw this with bulk PTD reads and
  the cpu-impl window.
- The gate check before stage 2 lowers this risk but does not remove it. The hexdump touches
  registers nobody has documented; some may be read-to-clear.
- After a hang, `readback.log` on the ESP ends with `about to read <addr>`; each line is synced
  before the load. That line is the answer.
- This is the after-Linux-boot point. The handover point (stage-1 proxy, untouched) needs the
  tether and `integration/r1/pmp-dump.py`.

Run, as root, from wherever the script was copied:

```
bash pmp-readback.sh --dry-run
bash pmp-readback.sh --gates-only
bash pmp-readback.sh
```

Logs: `/boot/r1-logs/pmp-<UTC time>/` (`README.md` with the offsets, `readback.log`, `values.tsv`,
`hexdump.txt`, `system.txt`, `dmesg-after.txt`).
