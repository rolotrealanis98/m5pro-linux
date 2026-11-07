# NVRAM from Linux on the J716s (T6050): next boot = macOS, without touching the Mac

2026-11-07. Studio only, no MacBook, nothing pushed, nothing written to any flash. Patches and tools are committed in
`m5pro-linux` under `contrib/pending/nvram/` (author and Signed-off-by Rolando Trevino).

## Result

- **Reads work with a DT change only.** `spi-apple-qspi` is already in the kernel (module) and matches the T6050 through the
  `apple,t8140-qspi` fallback. Patch 0001 enables the node and describes the one NVRAM partition.
- **Writes needed the "driver board row"** the notes mention: `apple_qspi_boards[]` in `spi-apple-qspi.c` is the write gate
  (controller compatible + machine + aperture + exact partition + JEDEC ID). Patch 0002 adds the J716s row.
- **The flash ID is known now**: macOS reports `JEDEC-ID = 0xc88317` on the J716s boot NOR (GigaDevice, 8 MiB; the J700's
  GD25UF16E is `c88315`). That was the missing value, so the row is real, not a placeholder. The one value still unknown
  is which block-protect bits iBoot leaves set; the row takes the strict answer (none) and fails closed.
- **Linux-to-macOS-once is `alt-boot-volume`**, written by `asahi-bless --set-boot-macos --next`. The macOS-to-Linux leg needs
  no NVRAM write if iBoot consumes the one-shot variable; that is unverified on M5 and the plan tests it first.

## Facts used (all from files on the Studio, node names and values only)

| Item | Value | Source |
|---|---|---|
| Controller | `/arm-io/qspi`, `qspi,qspimc`; P `0x305118000`, C `+0x800`; IRQ 1373; clock-ids 440 (405 MHz); clock-gates 208 | `adt-runtime-j716s.bin` |
| DT address | `spi@505118000` (ADT + `0x200000000`); node, clock `clk_405m`, `ps_spi_p` 0x308 and `ps_qspi` 0x350 already in `t6050-die0.dtsi` | series tree; ADT pmgr ids 199/208, offsets 0x308/0x350 agree |
| Flash | `spinor` reg `<0x0 0x19 ...>`: CS0. JEDEC `c88317`, `block-erase-supported` | macOS ioreg of the MacBook (`m5-ioreg-l.txt`) |
| Layout | firmware `0x20000..0x6dc000` (two slots), syscfg `0x6dc000` and `0x6e0000`, **anvram `0x700000` size `0xc0000`**, NOR >= 8 MiB | ADT |
| NVRAM | 12 banks of 64 KiB (`nvram-bank-count 12`, `nvram-bank-size 0x10000`), format v3 (`3VVN`) | ADT `/chosen` |
| m1n1 | `dt_set_nvram()` only fills `/arm-io/spi1/spinor/anvram`; on T6050 it prints "ADT: nvram partition not found", harmless, so the partition reg is static in the DT | `plan/m1n1/src/kboot.c:967` |
| Variable | `alt-boot-volume` is in macOS's own known-NVRAM-variable table (`kc.macho`); `bless --nextonly` exists on Apple silicon | macOS 27.3 kernel collection, `/usr/sbin/bless` |

## What Aurora's tree has

(`aurora/integration/aurora` and `omacom/integration/aurora`; our series already carries all of it.)

- `drivers/spi/spi-apple-qspi.c` + `spi-apple-qspi-policy.h` (+ KUnit test): command-FIFO QSPIMC driver, PIO spi-mem. Read-only at
  start; `read_only` module parameter (0644) can only be cleared by root after probe, never from the command line or insmod.
  Admits a write only if: board row matches (compatible, `of_machine_is_compatible`, aperture base), DT partition equals the
  row's partition exactly, JEDEC ID matches, status registers clean (no WIP/WEL/SUS/CMP, no BP bit not named in `bp_ok`), opcode is
  PP (single page, 3-byte address, inside the partition) or 4 KiB SE (aligned, inside), program only clears bits, then
  read-back verify; any failure latches read-only until the module is reloaded.
- Rows today: J613 (t8122), J713 (t8132), J616s (t6041, Macronix `c22b27` or W25Q64), J700 (t8140, W25Q16 or GD25UF16E). None for T6050.
- `Documentation/soc/apple/t8132-nvram.rst` (J713): the intended flow, `modprobe`, `asahi-bless --get-boot`,
  `printf N > /sys/module/spi_apple_qspi/parameters/read_only`, `asahi-bless --set-boot-macos --next --yes`, `printf Y > ...`.
- `tools/asahi/qspi-nvram-tests.py`: host C model of the driver's admission code, with changed-guard controls.
- DTs: J613/J873 `*-qspi.dtsi`, J616s `t604x-j614-j616.dtsi:1750`, J775D (same T6050 family) `t6050-j775d.dts:331`. All describe
  `flash@0` (`jedec,spi-nor`) with a `fixed-partitions` child labelled `nvram`, alias `nvram`, single-wire.
- Userspace: `WhatAmISupposedToPutHere/asahi-nvram` (workspace: `apple-nvram`, `asahi-nvram`, `asahi-bless`). Both tools open the
  device read+write even to read, which is harmless here because the driver refuses until armed.

## Patches (`contrib/pending/nvram/patches/`, apply cleanly on `j716s-series` `a0f2f30c967b` and on the `dtprep-stack` tip `eb9d77674727`)

| Patch | sha256 | What |
|---|---|---|
| `0001-arm64-dts-apple-j716s-Enable-the-boot-NOR-and-its-NV.patch` | `b904827a...` | `t6050-j716s.dts`: `&qspi` okay, `flash@0` (25 MHz, single-wire), `nvram: partition@700000 reg <0x700000 0xc0000>`, alias `nvram`. Appended at the end of the file so it does not collide with the other DT patches |
| `0002-spi-apple-qspi-admit-verified-NVRAM-writes-on-the-J7.patch` | `926c73c7...` | board row `{ "apple,t6050-qspi", "apple,j716s", 0x505118000, 0x700000, 0xc0000, c88317, bp_ok 0 }`, explicit `apple,t6050-qspi` match entry, and the harness extended |
| `0003-spi-apple-qspi-log-the-flash-ID-and-status-when-a-wr.patch` | `622ec6e8...` | logs the flash ID (mismatch was silent `-ENODEV`) and the three status registers plus `bp_ok` (status refusal) so a refusal says what to change |

Compatible: the DT keeps `"apple,t6050-qspi", "apple,t8140-qspi"` (binding patch 0008 already allows it). The row names the T6050
compatible, so the **J775D, with the same controller and aperture, stays read-only** (asserted in the harness).

Validation done here:
- DT: new DTB `build/t6050-j716s-nvram.dtb` (sha256 `a62ec79f...`) vs the base DTB `659af884...` (= the next-daily DTB, rebuilt bit for bit
  with host clang + dtc): semantic diff is exactly the alias, the status flip and the flash/partition nodes
  (`contrib/pending/nvram/dt/nvram.vs-base.txt`). No dtc warning on the new nodes at `-W1`.
- Driver: `tools/asahi/qspi-nvram-tests.py` on the Studio's clang (ASan+UBSan), 32 PASS lines including the new J716s phase
  (board/controller/aperture matrix 270 combinations; both partition ends; every status bit iBoot could leave set; other boards' IDs;
  read-only startup) and four new changed-guard controls (aperture, partition size, JEDEC ID, bp_ok) that must fail
  (`tests/qspi-nvram-tests.out`). The harness needed `-Wno-macro-redefined` on macOS (its `EOPNOTSUPP`).
- The patched `spi-apple-qspi.c` compiles with zero warnings using the exact flags from `wt-series-out/drivers/spi/.spi-apple-qspi.o.cmd`.
- Not built as a module and not booted: no MacBook.

## Config options

None to add. The daily kernel config (`next-daily/images/config-7.3.0-ga0f2f30c967b`) already has `MTD=y`, `MTD_SPI_NOR=y`,
`MTD_OF_PARTS=y` (the `fixed-partitions` parser), `MTD_SPI_NOR_USE_4K_SECTORS=y` (**required**: the driver only admits 4 KiB `0x20` erases
and `mtd` must report erasesize 4096), `SPI_MEM=y`, `SPI_APPLE_QSPI=m`, `PM_GENERIC_DOMAINS_OF=y`, `APPLE_PMGR_PWRSTATE=y`, `MODULES=y`.
`mtdchar` is part of MTD core (`drivers/mtd/Makefile`), so `/dev/mtdN` exists without another symbol. `MTD_PARTITIONED_MASTER` stays
off so only the partition has a device node (the rest of the NOR, iBoot included, has none).
Optional hardening for the next kernel build: `CONFIG_MTD_SPI_NOR_SWP_KEEP=y` (spi-nor never tries a status-register write at probe;
today the driver would refuse it and log). Not needed for this test and it would force a kernel rebuild.
`spi-apple-qspi.ko` is already in `modules-next2/modules-7.3.0-ga0f2f30c967b.tar.zst`; the module autoloads from the DT alias.

## Userspace

Build (not done here: building the external repo was refused by the sandbox classifier): `git clone
https://github.com/WhatAmISupposedToPutHere/asahi-nvram`, commit `3df52c9` (2026-09-15, has `70b16a2` "arbitrary number of nvram
partitions", needed for 12 banks; `Cargo.lock` present), then on aarch64 Linux (the Fedora 43 kernel-build container works):
`cargo build --release --locked -p asahi-nvram -p asahi-bless`. Debian/Ubuntu/Fedora/Gentoo package it; no Arch package found.
Find the device by name (`/proc/mtd`, line `"nvram"`), usually `/dev/mtd0`; pass it with `-d` (the by-name symlink needs a udev rule).

```
# read-only (safe at any time)
asahi-nvram -d /dev/mtdN read                      # prints values: private, do not paste
asahi-bless -d /dev/mtdN --list-volumes
asahi-bless -d /dev/mtdN --get-boot [--next]
# next boot = macOS, once (writes system:alt-boot-volume only; boot-volume untouched)
printf N > /sys/module/spi_apple_qspi/parameters/read_only
asahi-bless -d /dev/mtdN --set-boot-macos --next --yes     # or --set-boot "<volume name or index>" --next
printf Y > /sys/module/spi_apple_qspi/parameters/read_only
# back / undo
asahi-bless -d /dev/mtdN --clear-next              # also needs the arm/disarm pair
```
`--set-boot-macos` needs exactly one volume group whose first volume name starts with "Macintosh"; otherwise use `--set-boot` with the
name or the index from `--list-volumes`. Candidates come from `/dev/nvme0n1` (4096-byte GPT, APFS type `7C3457EF-...`). **Never run
`--set-boot` without `--next`** (that rewrites `boot-volume`, the default; the stub stays the default) and never `asahi-nvram write/delete`.
**Wrappers** (the part to actually run): `tools/nvram-probe.sh` (read-only, writes `probe.pass`) and `tools/nvram-next-boot.sh
status|to-macos|clear-next` (refuses without the marker, requires the NVRAM to be byte-identical to the probe's dump, arms for the
one call, disarms on exit/error/signal, then requires that the only change is the one variable and that it was a bit-clearing
in-place program). `tools/v3-nvram.py` is the read-only v3 parser both use (names and sizes, never values). All three tested on the
Studio against fake sysfs/mtd trees and stub tools (happy path, refusal without marker, refusal after the NVRAM changed, bless failure,
armed driver at probe time); `shellcheck` clean. Never run on hardware.
macOS side, if ever needed: `bless --info --getBoot`, `nvram -p | cut -f1` (read-only); writes need admin: `sudo bless --mount
/Volumes/<stub> --setBoot`.

### Dry run on real data

I modelled apple-nvram's v3 insert/serialize in Python (`v3-nvram.py`) and ran it on the 64 KiB bank iBoot passed in the ADT
(`/chosen/nvram-proxy-data`, `3VVN`, generation 185, 39 variables, 7295 of 65536 bytes used; CRCs all valid, re-serialises
byte-identically). Setting `alt-boot-volume` is **in place in the active bank, a pure bit-clearing program of 2 pages of 256 bytes**
(the driver's "never turn a zero into a one" rule passes), and clearing it is 1 page. No erase, no bank rotation. Names-only
comparison with the macOS `options` node (25 names): 22 present in the bank; absent: `boot-breadcrumbs`, `boot-command`,
`panicmedic-telemetry` (written or synthesised by macOS, not in the older Linux-boot snapshot). `upgrade-boot-volume` is identical in both
captures; `boot-volume` differs, consistent with the default having been switched between them. The ADT blob dates from an earlier
boot (`nvram-current-bank` 4 there, 10 in the macOS capture of Nov 7), so the flash's active bank will differ from it: the on-box probe is the
real comparison.

## Safety analysis

Layers, outermost first:
1. **DT exposes only 0x700000..0x7c0000.** No device node for iBoot (0x20000..0x6dc000) or syscfg. SecureROM (mask ROM) and DFU are
   untouchable from here.
2. **Driver gate** (above): read-only until root arms it after probe; row; JEDEC; clean status; opcode, range and page rules; verify;
   latch. A boot argument or `insmod` cannot arm it.
3. **Tool**: `asahi-bless --next` touches one variable; v3 writes are append-only inside the bank (state bytes and a new entry).
4. **Wrapper**: marker (read-only test must pass), unchanged-NVRAM check, disarm trap, post-write diff.

What a bad NVRAM write can do on this machine:
- Wrong or stale `alt-boot-volume` (bad UUID): iBoot cannot resolve the volume. Expected to ignore it or show the picker; not verified.
  Escape: hold the power button into iBoot's picker (independent of NVRAM), choose the stub, then `clear-next`.
- One-shot variable not consumed: the next restarts keep going to macOS. Same escape; or Startup Disk in macOS. This is the main thing the
  attended test exists to learn.
- Torn write (power loss or crash in the 1-2 page program): can leave an entry whose CRC fails. `apple-nvram` (and my parser) then call
  the bank invalid. iBoot's behaviour here is not verified; Apple documents that Apple-silicon Macs reset NVRAM automatically when it
  needs it (no key combo), so the worst expected outcome is losing boot-volume/auto-boot and the other variables, and booting by policy;
  user data is not in this partition. Mitigations: AC connected, battery above 50 %, the dump taken before the write kept on the Studio.
- Cannot: touch firmware or syscfg, change the boot policy, brick the machine. Last resort if the NOR content ever stops booting: DFU revive
  or restore from the Studio (Apple Configurator, `~/Work/macvdmtool` for the VDM), which rewrites NOR and NVRAM.
- Driver fault: a failed verify latches read-only and logs `NVRAM write fault`; do not retry, reboot.
- First read of the controller with its power domains off takes an SError (Aurora's note in `t8152-j873-qspi.dtsi`). The DT has `ps_qspi`
  (parent `ps_spi_p`, whose own parent SIO is undescribed): if that fails, the boot panics and the A/B stage-1 watchdog (150 s) reverts.
- Restoring from a dump is possible only while Linux boots, with the driver armed (`flash_erase` in 4 KiB steps then `dd`); untested, and a
  reason to keep the dump off-box.

Rule enforced mechanically: **no write before the read-only test passes.** Stage 2 runs the stock module, which has no J716s row, so
a write is impossible by construction; the row only exists after the read results are in.

## Loop-safe test plan

Pass/fail needs a person only at stages 5-6. The default DTB and the daily payload are never changed; the node lives only in the test DTB.

0. **Done on the Studio**: items under Validation and Dry run.
1. **Build (Studio)**: asahi-nvram/asahi-bless as above; test payload = the current next-daily test payload with
   `build/t6050-j716s-nvram.dtb` as its DTB (in `mk-next-daily-variants.py`, point `DD` and its `PINS` entry at it; `m5.selftest=1` keeps the self-revert; ESP
   rules in `ESP-POLICY.md`). Binaries and `tools/*` go to the box with the usual scp.
2. **Boot with the node (unattended, self-revert)**. Pass: boots, network up (self-test passes), no `SError`/`Oops`; `dmesg` shows
   `spi-nor spi0.0: ... (8192 Kbytes)` and an `nvram` mtd partition (the module should autoload from the DT alias; if not, `modprobe spi-apple-qspi` in stage 3), and no `NVRAM write fault`.
   Fail (SError, hang, no network): the watchdog reverts; collect `r1-logs/selftest-*`; next try `spi-max-frequency = <10000000>`.
3. **Read-only test (attended, ssh)**: `sudo tools/nvram-probe.sh --macos-names names.txt`, with `names.txt` from macOS `nvram -p | cut -f1 | sort`.
   Pass = the script's "READ-ONLY TEST PASSED": 505118000.spi bound, `read_only=Y`, JEDEC `c88317` from both `flash_status` and spi-nor,
   status idle, `/proc/mtd` nvram 786432 / 4096, DT alias, two identical 768 KiB dumps, valid 3VVN parse, `asahi-nvram read` and the dump
   agree on names, `boot-volume` present, `asahi-bless --list-volumes/--get-boot` work and the starred default is the stub. It also prints
   `sr1`: **if block-protect bits (`sr1 & 0x7c`) are set, stop here**: patch 0002's row refuses (bp_ok 0, logged by patch 0003);
   decide from the GD25UF64 datasheet whether the protected range excludes 0x700000..0x7c0000 and only then change `bp_ok`.
   Copy `probe-*/a.bin` to the Studio (mode 600, outside any repo) and compare names with `v3-nvram.py names` against the macOS list.
4. **Rebuild the module with the row** (0002+0003, plus a changed `bp_ok` if stage 3 required it) in the kernel-build container against
   `wt-series-out`: copy the patched `spi-apple-qspi.c`/`-policy.h` to a scratch dir with `obj-m += spi-apple-qspi.o`, then
   `make LLVM=1 ARCH=arm64 -C /Volumes/linux-cs/wt-series-out M=<dir> modules` (vermagic `7.3.0-ga0f2f30c967b` comes from that out dir; **untested**,
   the Studio never built an external module). Install over `/lib/modules/7.3.0-ga0f2f30c967b/kernel/drivers/spi/spi-apple-qspi.ko`, `depmod`,
   `rmmod spi_apple_qspi; modprobe spi-apple-qspi`. Rerun stage 3 (new marker, `read_only` still `Y`). No reboot, no new payload.
5. **One attended write test** (AC connected, battery above 50 %, someone at the Mac, ssh from the Studio):
   `sudo tools/nvram-next-boot.sh to-macos`. Pass: it prints the plan (in place, bit-clear only, 2 pages), the `after:` block shows
   `default:` unchanged and `next:` = the macOS volume, the compare shows only `added system:alt-boot-volume`, `read_only` back to `Y`,
   no `NVRAM denied/write fault` in dmesg. Any other result: do not reboot; keep the run directory and dumps.
6. **Reboot into macOS, confirm, reboot back**: `sudo reboot` (the payload stays in place). Pass: the Mac comes up in macOS (ssh: `sw_vers`,
   `uname -s`, `nvram -p | cut -f1` with or without `alt-boot-volume`: records whether iBoot consumed it). Then a person chooses Restart in the
   Apple menu (or power button; `osascript` restart over ssh is an untested option). Pass: it returns to Linux on its own and
   `nvram-next-boot.sh status` says `alt-boot-volume is not set`. If macOS restarts into macOS again, the variable was not consumed:
   hold the power button into the picker, pick the stub, then `nvram-next-boot.sh clear-next` and record it. Either result closes the test.
   Afterwards run `nvram-probe.sh` once more and compare the dump with stage 3's: only the expected variable churn.

Abort rules: stop at the first FAIL, never re-arm after a logged write fault, never edit `read_only` by hand outside the wrapper, never
use `asahi-nvram write/delete`, `--set-boot` without `--next`, or `bless --setBoot` during this test.

## Open items and what is not verified

- BP bits at boot and the GD25UF64 register layout are assumed equal to the GD25UF16E's the driver's GigaDevice checks were written for;
  the status logic fails closed on anything unexpected, and stage 3 shows the real `sr1/sr2/sr3`.
- One-shot consumption of `alt-boot-volume` by iBoot on the M5 (the name is Apple's, the semantics are asahi-bless's).
- 25 MHz on this part (J775D value); fall back to 10 MHz.
- iBoot behaviour on a torn or invalid NVRAM bank (Apple documents automatic reset).
- External module build recipe, `asahi-*` binaries and the test payload are not built; nothing ran on hardware.
- m1n1 could fill the partition itself with a `/arm-io/qspi/spinor/anvram` lookup; not needed with the static reg.

## Files

`~/Documents/GitHub/m5pro-linux/contrib/pending/nvram/` (committed): `patches/0001-0003`, `tools/{nvram-probe.sh,nvram-next-boot.sh,v3-nvram.py}`,
`dt/nvram.vs-base.txt`, `tests/qspi-nvram-tests.out`, `README.md`.
`~/Work/agents/nvram-t6050/build/`: `t6050-j716s-nvram.dtb`, `base-next-daily.dtb`. Scratch worktree used for the patches was removed.
