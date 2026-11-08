# daily-dcp first boot: why both twins fell back, and the bisect (2026-11-08)

Studio-only analysis of the two failed boots recorded in `contrib/validated/integration/RESULTS.md`
("2026-11-08 03:03 UTC: DAILY-DCP first boots"). Nothing was run on the MacBook. No console exists for the failed boots,
so the cause is not proven. This note ranks the candidates from the code and the boot timing, and gives the payloads
that separate them. Private inputs (the m1n1 logs with the board serial, the ADT) stay on the Studio.

**ROOT CAUSE FOUND (section 9).** m1n1's T6050 display hand-off needs a phandle on every display node it edits,
and bails if one has none (`kboot.c:2290-2296`). The in-tree DTB has no phandle on `dcp@48ae00000` or
`display-subsystem`; dcp9d has `0xd3`/`0xd4`. So `kboot_prepare_dt()` fails, stage 2 drops into the proxy with no host,
nothing feeds the watchdog, and stage 1 resets after 150 s.

That accounts for every result:
- every in-tree DTB with the hand-off armed fell back (twin, B2, B6, B10, B12);
- every boot without the hand-off (B1, B3) or with dcp9d (B5) booted.

The fix payloads are in section 9.

**Update (round 1):**
- B2 fell back the same way as the twin (stage-1 watchdog), so **H1 is out**.
- B3 booted, so the kernel build is fine as a plain daily (H4 is out).
- Section 7 has the results and the round-2 payloads B5, B6 and B7.

Failed payloads: `daily-dcp-test-20261107-dfe0c6cc` and `daily-dcp-test-vrr-20261107-3606884e`. Kernel `7.3.0-gbd53915f2ef1`,
DTB `t6050-j716s-daily-dcp.dtb` (in-tree), loader `m1n1-plain-n1-dt-gpu-dcp`, variables `chosen.m5pro,gpu=1` and
`chosen.m5,t6050-display=1`, no `n1` variable.

## 1. Correction: this was the stage-1 watchdog, not a panic reset

RESULTS.md calls it "an early kernel panic (PANIC_TIMEOUT=10) rather than a hang". The timing says otherwise.

- Runner log: `reboot->ssh 214 s`, then the fallback kernel reported `up 11 s`, so it started about **203 s** after the
  reboot command. The clean restore in the same run: 103 s to ssh at `up 59 s`, so its kernel started about 44 s after
  the command (this includes the 20 s shutdown settle hook).
- `contrib/pending/boot-ab/firstboot/firstboot-probe.sh:9-16` classifies fallbacks by that delta, calibrated without the
  settle hook (clean reboot 21-29 s): 55-74 s = Linux panic in its first seconds + `PANIC_TIMEOUT=10`; 75-169 s = Linux
  froze after `apple_wdt` probed (30 s bite); **>= 170 s = the stage-1 watchdog, a hang before Linux took it over**.
  Even after taking 20 s off for the settle hook, 203 s is in the last band.
- Model: about 28 s from the command to the stage-1 start, the 150 s stage-1 watchdog, then 22-26 s from reset to the
  next kernel (`REPORT.md` calibration) gives 200-204 s. A panic with a working restart would have given about 90 s.
- Error stage `0x30` does not prove the kernel ran: `firstboot-probe.sh:19-21` says 30 means iBoot, m1n1 or Linux
  was running (31/32 exist only with stage-1 0017 and `chainload.stage-mark=1`, which is not installed).
- Not the SSD-busy restart: that failure gives a delta of +33 to +41 s (`firstboot/REPORT.md` table). Here `esp-put`
  waited 60 s, both twins failed the same way, and the restore was clean.

So the failed boot died **before any Linux restart handler existed**. One of these happened:
(a) the stage-2 m1n1 never reached Linux, (b) Linux hung before `apple_wdt` probed, or (c) Linux panicked before
`macsmc-reboot` and `apple_wdt` registered their restart handlers. With no handler, arm64 `machine_restart()` prints
"Reboot failed -- System halted" and spins, so the stage-1 watchdog resets the machine 150 s after stage 1 started.

## 2. What runs in that window (read from the code and the logs)

Device initcall order in the twin kernel (`~/Work/agents/daily-dcp/kbuild/System.map`, the `__initcall*` entries
sorted by address): `simpledrm` (1488) -> **`__aurora_initcall`** (1489, the GPU) -> **`appledrm_register`** (1490,
the DCP) -> `macsmc` (1500) -> ... -> `macsmc_reboot` (1710) -> `apple_wdt` (1751). The same order is in
`drivers/Makefile` (`gpu/` :68, `mfd/` :76, `power/` :120, `watchdog/` :123) and `drivers/gpu/drm/Makefile`
(`asahi/` :223, `apple/` :232).

- **The DCP probes synchronously in that window.** Stage C journal (`~/Work/agents/dcp/stagec/logs/stagec-journal.txt`):
  `apple-dcp ... negotiating RTKit with the running DCP` at line 456, `bound 48ae00000.dcp` at 461, first hotplug at
  471, all before `macsmc ... RTKit: Initializing` at line 1010.
- **The GPU also boots in that window.** E2b daily dmesg (`~/Work/agents/gpu-e2/logs/e2b/.../dmesg.txt`):
  `aurora 2300000000.gpu: Probing...` at 0.4785 s, GPU RTKit at 0.4944 s, `macsmc-reboot: Handling reboot` at 0.5296 s.
- **Kernel-side N1 training does not run in that window.** `pcie-apple` waits for the N1 power line
  (`pwren-gpios` = the SMC GPIO, an MFD child that appears only when `macsmc` probes; `pcie-apple.c:2341`, `:2507`). In the
  kernel-train boots, `port 0: trained by Linux` is at 1.004-1.037 s (`~/Work/agents/n1-kernel/loop/run-k1k2.log`,
  `~/Work/agents/daily-n1k/loop/run-daily-n1k.log`), after `/init` started (0.674 s in E2b). By then `macsmc-reboot`
  and `apple_wdt` are up. A failure there would land in the panic or `apple_wdt` band, or never reset.
- The NVRAM NOR is inert at boot: `CONFIG_SPI_APPLE=m`.

Inside the window, the twin is the first boot to run both the GPU driver and the DCP takeover. Stage C and dcp120
had `DRM_ASAHI=y` too (their config is identical to the twin's: `scripts/diffconfig` stagec-dcp120 vs daily-dcp prints
nothing), but no `gpu=1`, so the GPU node stayed disabled and aurora never probed. The daily has the GPU but
`DRM_APPLE=n`.

## 3. Ranked causes

### H1 (most likely): GPU driver and DCP takeover together, before any restart handler
New in this boot: aurora boots the GPU firmware, and in the very next initcall apple-drm takes the running DCP over by
RTKit. If either probe faults or blocks there, the result is exactly what was seen: no restart handler and a
stage-1 watchdog reset.

What was checked and ruled out:
- **m1n1 memory carve-outs do not overlap.** GPU regions in the E2b m1n1 log: fw-text, fw-data and the four UAT
  regions, at 0x1000102.., 0x1000252.. and 0x10bfff20000-0x10bfffac000. Stage C display: vram 0x10bd15f4000+0x72c4000;
  DART roots 0x10bffe20000, 0x10bffea0000, 0x10bffed0000; `__OS_LOG` reservations 0x100049ec000-0x10004b08000.
  These ranges are disjoint, and all but the OS logs are above the 0x10bc8a00000 RAM top.
- **The two hand-offs share no DT state.** `dt_set_display()` runs before `dt_set_gpu()` (`kboot.c:3237-3240`). Each
  re-finds its nodes by phandle after editing the tree (`kboot.c:2289-2320`, `kboot_gpu.c:955-997`).
- **No reg or IRQ overlap between GPU and display nodes** in the twin DTB (overlap scan of the decompiled DTB).
  The only overlap with an enabled node, `power-management@286806000` "voters" over `pmc-metadata` and `disp-4`, has no
  driver: `pmc.c:1393` matches `apple,t6041-pmc` only.

What remains: runtime interaction between the GPU firmware boot and the DCP takeover. The GPU firmware maps a PMGR
page for itself (`MMU: IO map: 0x280414000`), and the CLPC/PMP and fabric state are shared. Not readable from code;
B2 and B2b test it.

### H2: the DCP on the daily-n1k base, without the GPU
The twin's DCP code and display nodes equal stage C's:
- `dtchk/vs-dcp9d.txt` has no display-node lines.
- The driver diff 22ec57f56b27..bd53915f2ef1 in `drivers/gpu/drm/apple` touches no probe path. It is the constant
  timestamp (as ct0), the brightness refusal after a crash, and fewer promotion modes.

What else differs from stage C is the daily base: kernel N1 training (shown above to run after the restart handlers),
F6, NVRAM (module, inert), the in-tree DTB's GPU, PCIe and power-controller nodes (proven by the daily), and loader
0028. Less likely than H1. B2 tests it.

### H3: stage-2 m1n1 with both hand-offs plus 0028
If `kboot_prepare_dt()` fails, `payload.c:345-347` returns -1, `main.c:131` runs the proxy with no host, and
`wdt_kick()` is called only per proxy request (`proxy.c:41`, `wdt.c:19-23`). The stage-1 watchdog bites, which fits
the timing.

Against it:
- Every display and GPU check failure returns 0 and boots on (`kboot.c:2238-2287`, `kboot_gpu.c:1019-1031`). Only
  libfdt write errors bail.
- The FDT buffer has 96 KiB of headroom (`kboot.c:3174`) against a 46 KiB DTB plus a few KiB of edits.
- Each hand-off has run before, with 0028 or without it.

Low. B2b tells H1b and H3 apart from H1a. B1 and B3 cover the loader.

### H4: the daily-dcp kernel build itself
Low. The config is identical to stage C's, the Image size is the same within 3 KiB, and the DT is the daily's
plus display nodes. B3 tests it.

## 4. pstore/ramoops: not added, it cannot survive this path
The twin DT has no ramoops node; `/reserved-memory` holds only the six GPU placeholders. Adding one would not help:
- **CRASHLOG-T0..T3:** ordinary DRAM is empty after a warm reset. **CRASHLOG-PRAM:** iBoot consumes and clears
  `/pram` on every boot, after a reboot and after a `sysrq-c` panic alike. Both are in RESULTS.md.
- The J716s DRAM is ECC, and iBoot initialises it on every boot.
- README.md:47 already says "RAM-backed pstore is not viable".
- A watchdog reset into stage 1 is the same iBoot path, so nothing would survive.
- Risk with no gain: T1, the ramoops node with mem-type 1, did not boot.

The bisect DTBs are therefore unchanged.
Evidence has to come from outside:
- the panel: `earlycon=efifb keep_bootcon console=tty0 loglevel=8` is already in the bootargs, and the boot framebuffer
  stays on screen until apple-drm's first commit;
- netconsole on the Studio's LAN, which needs an attended re-plug;
- `initcall_debug` on a hunt payload.

## 5. Bisect payloads (`~/Work/agents/daily-dcp/bisect/`, 0600, SHA256SUMS)

Built by `mk-bisect.py` (copy next to this file). It loads `contrib/validated/aurora/tools/mk-daily.py` unchanged as a
module, with `M1N1_SIZE=0x410000`, as `mk-daily-dcp.py` does. It first rebuilds the twin into a temporary directory and
stops unless that reproduces `dfe0c6cc` byte for byte (it did).

Every payload keeps the twin's settings: kernel `bd53915f2ef1`, self-test ON, battery ON, initramfs `initramfs-ftab`
(cffbbaf1), bootargs = the twin's (`... m5.selftest=1 log_buf_len=16M`), no watchdog bootargs. Each layout check
passed. The parts were re-parsed against the twin: only the listed part differs.

| Payload | sha256 | Differs from the twin | Tests |
|---|---|---|---|
| B1 `dcpbis-b1-gpuloader-20261107-583dce9f.bin` | 583dce9f… | loader `m1n1-plain-n1-dt-gpu.bin` (1d05a506, the daily's); variables `gpu=1` only (the display variable is inert without the display code) | the DCP kernel and twin DTB as a GPU daily, with no display hand-off and no `__OS_LOG` reservations |
| B2 `dcpbis-b2-nogpu-20261107-b6298d9c.bin` | b6298d9c… | no `chosen.m5pro,gpu=1` | H1 against H2: the DCP with kernel N1 training on the daily base, no GPU |
| B3 `dcpbis-b3-n1kdtb-20261107-b62bf9e5.bin` | b62bf9e5… | DTB `t6050-j716s-daily-n1k.dtb` (2612e67c); no display variable (inert without a dcp node) | H4: the DCP kernel as a plain GPU daily; the twin loader's display code only reads and logs |
| B2b `dcpbis-b2b-noaurora-20261107-6a8f0df6.bin` (optional) | 6a8f0df6… | bootarg `initcall_blacklist=__aurora_init` (`System.map`: `__aurora_init`, `__aurora_initcall`) | after B2 boots: the GPU driver (H1a) against the m1n1 GPU hand-off state (H1b/H3) |

**B1: can the DCP driver drive the panel without the hand-off? No, and it will not try.**
- The dcp, its mailbox, both display DARTs and the display subsystem are `status = "disabled"` in the DTB. Only
  `dt_set_display_t6050()` enables them (`kboot.c:2316-2320`), and the n1-dt-gpu loader does not have it.
- Even if they were enabled, there would be no `memory-region` (vram) and no `apple,firmware-version`/`-compat`. The
  driver returns -ENODEV for an unknown compat (`dcp.c:5996`).
- B1 is therefore expected to boot on simpledrm + aurora (card0 simple-framebuffer, card1 aurora), like the daily.

Expected outcomes:

| Hypothesis | B2 | B2b | B3 | B1 |
|---|---|---|---|---|
| H1a GPU driver + DCP | boots, card0 = apple, no aurora | boots | boots | boots |
| H1b/H3 combined m1n1 hand-off state | boots | falls back | boots | boots |
| H2 DCP on the daily-n1k base | falls back | falls back | boots | boots |
| H4 kernel build | falls back | falls back | falls back | falls back |

## 6. Boot order (fewest boots)
0. **If someone can be at the machine: boot the twin once and film the panel.** This needs no new payload. The last
   lines name the probe that hung or panicked, which may end the hunt in one boot.
1. Unattended: **B2**.
   - It boots: H1. Then run **B2b**: if it boots, H1a; if it falls back, H1b/H3. Two boots in total.
   - It falls back: run **B3**. If B3 falls back, H4 (the kernel build); stop, B1 adds nothing. If B3 boots, H2 is
     indicated; **B1** then confirms the twin DTB is fine without the display hand-off. Two or three boots.
2. Each fallback costs about 4 minutes (60 s settle, 150 s watchdog, the fallback boot). Read every result with
   `firstboot-probe.sh`: a delta of 170 s or more means a hang or panic before a restart handler existed.

Deploy plans: `python3 -I ~/Work/agents/daily-dcp/mk-daily-dcp.py plan <payload> root@<host>` (offset 0x410000; plain
`mk-daily --deploy-plan` would misread the self-test flag).

No B4: no concrete bug was found in the code. If H1a is confirmed, the next step is a probe-order experiment, either
the DCP takeover before the GPU firmware boot or the GPU deferred until the DCP is bound. Its first payload should
carry `initcall_debug`, with the panel filmed.

## 7. Round 1 results and round 2 (2026-11-08 03:27 UTC onwards)

Runner: `~/Work/agents/daily-dcp/loop/run-dcp-bisect.sh`, log `run-dcp-bisect.log`.

| Payload | Result | Reading |
|---|---|---|
| B2 `b6298d9c` (no `gpu=1`) | **fell back**: delta 208 s, `attempt-stage1-watchdog`, pmu 300130 | **H1 is out.** The DCP takeover fails without the GPU, before any restart handler, the same way as the twin |
| B3 `b62bf9e5` (daily-n1k DTB, no display variable) | **booted** on `7.3.0-gbd53915f2ef1`: delta 49 s, clean; simpledrm + aurora; Wi-Fi associated | **H4 is out**, and the twin loader's display code is harmless when unarmed |
| B1 `583dce9f` (daily loader, twin DTB, `gpu=1` only) | running when this was written | expected to boot: the display nodes stay disabled without the hand-off |

That leaves the display hand-off on the daily-n1k base (H2), with H3 (the B2 loader) still open.

Pre-watchdog differences between B2 and the stage C boot that worked:
- **DT** (in-tree vs dcp9d):
  - three apcie power-controllers set always-on with auto-PM off, plus their parents; `pmgr_pwrstate` probes them before
    any restart handler and raises them;
  - port00 and `dart_apcie0` enabled by 0028 with the link down (`apple,manual-availability`, `pwren-gpios`, SMC GPIO
    bank);
  - GPU/UAT placeholders (disabled) and the NVRAM NOR (module).
- **Loader:** 0028 against stage C's loader with `n1=4`. Without `n1`, nothing in the loader trains the port, and 0028
  copies the host tunables.
- **Kernel:** the daily base (pcie-apple cold train and adopt, DART manual-availability, gpio-macsmc, F6, NVRAM DT)
  against the dcp120 base. The promotion and VRR deltas touch no probe path.

Round 2: each payload differs from B2 in one part, except B7. All are built by `mk-bisect2.py` (copy next to this
file), which first rebuilds B2 byte for byte. They are byte-verified, 0600, and listed in `SHA256SUMS`. Every one
keeps B2's self-test, battery, initramfs-ftab and bootargs, and has no watchdog bootargs.

| Payload | sha256 | Differs from B2 | Splits |
|---|---|---|---|
| B5 `dcpbis-b5-dcp9d-20261107-438f2685.bin` | 438f2685… | DTB `t6050-j716s-daily-dcp9d.dtb` (dab1b4f3) | the daily-n1k DT additions under the hand-off. Under dcp9d (no `pwren-gpios`, no manual-availability), 0028 keeps port00 and `dart_apcie0` disabled: no N1 on this boot |
| B6 `dcpbis-b6-stagec-loader-n1-20261107-47036123.bin` | 47036123… | loader `m1n1-plain-n1-warm-gpu-dcp.bin` (085a2734, no 0028) plus `chosen.m5pro,n1=4` (stage C's variable order) | loader-trained, kernel-adopted N1 instead of 0028 leaving the port down for the kernel's own train, with the in-tree DT and the new kernel |
| B7 `dcpbis-b7-stagec-kernel-dcp9d-20261107-d2ea6fb3.bin` | d2ea6fb3… | kernel `7.3.0-dcp-g22ec57f56b27` (b9e1bafd) **and** DTB dcp9d; that is B5 plus the old kernel | read against B5: the kernel delta. It equals stage C with the B2 loader and no `n1` |

**Why B7 pairs the old kernel with dcp9d and not with the in-tree DTB:**
- With the in-tree DTB and no `n1`, 0028 enables port00 and `dart_apcie0` with the link down (`kboot_n1.c`, the
  `kernel` condition in 3e2321df).
- The old kernel has no `apple,manual-availability` support (14a41f5612e2 is not in 22ec57f56b27), so it would probe
  that DART at once.
- That probe takes the SError 0028's own comment describes, a false failure unrelated to the DCP.
- Under dcp9d the port and the DART stay disabled, so the old kernel meets the DT it was built and booted with.

Recommended order (decide once B1's result is in the log):
- **B1 boots (expected):**
  1. Run **B5** first: it removes every DT addition and the kernel N1 path in one boot.
  2. If B5 boots, the trigger is in the in-tree DT additions. Run **B6**:
     - B6 boots: the kernel-trained N1 port (0028 leaving it down, `dart_apcie0` deferred, cold train) breaks the
       hand-off;
     - B6 falls back: another DT addition. Prime suspect: the apcie power-controllers forced always-on with auto-PM
       off, raised by `pmgr_pwrstate` before the DCP probes. Next payload: the in-tree DTB with only those reverted.
  3. If B5 falls back, run **B7**:
     - B7 boots: the kernel delta (the daily base's pcie/DART/gpio code) breaks the hand-off even with the port disabled;
     - B7 falls back: the B2 loader. Run B6 to confirm; it should boot if 0028 is the trigger.
  4. Two boots in every branch.
- **B1 falls back:** the twin DTB breaks the daily even without the hand-off. B3 booted with the daily-n1k DTB, and
  the only enabled node the twin adds over it is the `clk_disp0` fixed clock; the rest of the display nodes are
  disabled.
  1. Run **B5** to confirm a DT cause.
  2. B6 and B7 add little; the next step is the twin DTB minus `clock-disp0` (`dtchk/vs-n1k.txt`).

Every result: read the `firstboot-probe.sh` delta. A delta of 170 s or more means failure before a restart handler.
An attended boot with the panel filmed still gives the most per boot.

## 8. Round 2 results and round 3 (2026-11-08 03:42 UTC onwards)

| Payload | Result |
|---|---|
| B1 `583dce9f` (daily loader, twin DTB, `gpu=1`) | **booted**, clean, delta 51 s |
| B5 `438f2685` (B2 with the dcp9d DTB) | **booted**, clean, delta 50 s. card1 = apple-drm, eDP-2 connected, six modes. No flip_done or transaction timeouts, no crash, no faults. `apple-dcp` probed at 0.127 s (before any restart handler). No N1 (`wlan=0`), no GPU node |
| B6 `47036123` (stage C loader + `n1=4`, in-tree DTB) | **fell back**: delta 208 s, `attempt-stage1-watchdog` (03:50 UTC). The kernel train is out, and so is 0028: a loader-trained, kernel-adopted port fails too, on the in-tree DTB |

Conclusion so far:
- The DCP takeover works on the daily kernel and the B2 loader with the dcp9d DTB.
- The same takeover fails, before any restart handler, with the in-tree daily-dcp DTB.
- The trigger is one of the in-tree DTB's additions over dcp9d, acting together with the display hand-off. Without the
  hand-off (B1, B3) the same DTB boots.

### Every difference between the twin DTB and dcp9d (from `dtchk/vs-dcp9d.txt`)

| Group | Lines in vs-dcp9d.txt | Enabled before the root mounts? | Rank |
|---|---|---|---|
| **A. kernel-train pcie description** | pcie `reg`/`reg-names` (+6 windows), `pci@0,0 pwren-gpios`, new node `smc/gpio@67500000`, `iommu@410000000 apple,manual-availability` | Yes. With no `n1`, 0028 enables port00 and `dart_apcie0` because of `pwren-gpios` + manual-availability. gpio-macsmc binds the bank when macsmc probes. pcie-apple maps the extra windows and cold-trains the N1 | **1** |
| **B. apcie power-controllers** | `power-controller@118 @138 @148 @1b0 @258 @280` (apcie_gp, fab6_soc, apcie_sys_gp, apcie_phy_sw, aphy_gp_aus5_a, aphy_gp_aus5), all `apple,always-on`, three `apple,no-auto-pm` | Yes. `pmgr_pwrstate` (initcall #1346, before appledrm #1490) raises them out of iBoot's automatic gating and disables auto-PM | **2** |
| C. NVRAM | `spi@505118000` disabled -> okay, `flash@0`, `partitions`, `partition@700000`, alias `nvram` | No: `CONFIG_SPI_APPLE=m`; nothing binds before the root mounts | 4 |
| D. GPU | `/soc@2300000000` (gpu, two mailboxes, PMGR node, four power-controllers), six `/reserved-memory` GPU/UAT placeholders, alias `gpu` | No without `gpu=1`: all `status = "disabled"` (the power-controllers sit under a disabled parent) | 3 |
| E. renumbering only | aop `audio dmas`, nvme `apple,sart`, smc `reboot`/`rtc` `nvmem-cells` | Not a difference: the phandles resolve to the same nodes in both DTBs (checked) | - |

### Round 3 payloads

All are in `~/Work/agents/daily-dcp/bisect/`, files 0600, listed in `SHA256SUMS`, built by `mk-bisect3.py`, which
first rebuilds B2 byte for byte.
- The DTBs come from `dt/mk-dt3.py`. It decompiles c8f1b960, edits by node path and recompiles. The unmodified DTS
  recompiles byte-identical.
- The semantic diff of each DTB against the twin's shows exactly the intended edits. No phandle is left dangling: no
  other property's resolved form changed.
- B12's pcie, DART and GPIO lines are equal to dcp9d's.
- Each payload differs from B2 in exactly one part: the DTB, or for B9 the variables.

| Payload | sha256 | Differs from B2 |
|---|---|---|
| B9 `dcpbis-b9-n1loader-20261107-974350b6.bin` | 974350b6… | `chosen.m5pro,n1=4` added (same 0028 loader): the loader trains the N1 port and the kernel adopts it. In-tree DTB unchanged |
| B8 `dcpbis-b8-nopwren-20261107-990ca745.bin` | 990ca745… | DTB d5765d18: in-tree minus port00's `pwren-gpios`, so 0028 keeps port00 and `dart_apcie0` disabled (no N1). Everything else in the DTB stays |
| B10 `dcpbis-b10-nopwrctl-20261107-f475d784.bin` | f475d784… | DTB 3ef4428b: in-tree minus the six apcie power-controllers (group B) |
| B12 `dcpbis-b12-notrain-dt-20261107-3e693699.bin` | 3e693699… | DTB 99655db5: group A reverted to dcp9d (pcie windows, `pwren-gpios`, SMC GPIO bank, manual-availability); port00 and the DART stay disabled |
| B11 `dcpbis-b11-nogpu-nonvram-20261107-5da555da.bin` | 5da555da… | DTB 7492c2f6: in-tree minus groups C and D |

**About B9 against the requested "pwren-gpios / manual-availability removed so the kernel does not train":**
- Removing those properties does not make an adopted port. Nothing trains the port, so 0028 just disables it; that is
  B8.
- A plain adopted port needs the loader to train it, so B9 adds `n1=4` and keeps the B2 loader.
- B9 differs from B6 only in the loader (0028 or not), which splits B6's two changes.

### Order once B6 is in the log (B6 fell back: take the second branch)
- **B6 boots** (the kernel train of a down port, or 0028, is the trigger):
  1. Run **B9**.
     - B9 boots: the kernel's own N1 train is the trigger, and loader-trained N1 on the in-tree DTB is a daily
       candidate (B9 itself, or B9 with `gpu=1`).
     - B9 falls back: 0028 is the trigger.
  2. Then **B8**, to confirm that no-N1 boots with every other addition present.
- **B6 falls back** (the train path is out; a static addition is the trigger):
  1. Run **B10** (group B). It acts before the DCP probes and is the only enabled block of hardware state that dcp9d
     lacks entirely.
  2. Then **B12** (group A's static parts).
  3. **B11** last; it is expected to fall back.
  4. If B10 and B12 both fall back, run B8 and then B11.

### Could a daily ship on dcp9d plus a DT patch?
B5 drives the panel through the DCP on the daily kernel. As a daily, dcp9d loses three things:
- **Wi-Fi/BT:** 0028 leaves the N1 port disabled because dcp9d has no `pwren-gpios` or manual-availability.
- **The GPU:** dcp9d has no GPU nodes.
- **NVRAM.**

Minimal deltas from dcp9d:
- **Wi-Fi with no DT change at all:** add `chosen.m5pro,n1=4`. The loader trains the port and the kernel adopts it,
  which is the stage C and e2b-era recipe. dcp9d's `dart_apcie0` has no manual-availability, which is correct when the
  loader brings the port up. The B2 loader has the 0027 warm-N1 code. The payload would be B5 + `n1=4`; it is not
  built yet.
- **Kernel-side training instead:** that needs all of group A plus group B, which is exactly what is under suspicion.
- **The GPU:** needs group D plus `gpu=1`. The GPU next to the DCP has still never booted: B2 removed `gpu=1`, so H1
  was ruled out for this failure only, not shown to work.
- **NVRAM:** group C (inert until the module loads).

After B6:
- B9 (the in-tree DTB with `n1=4`) is expected to fall back like B6, so the daily cannot be "in-tree + `n1=4`" until
  the static trigger is found.
- The quickest shippable display daily is **B5 + `n1=4`**: dcp9d with loader-trained Wi-Fi, no GPU, no NVRAM. It
  equals stage C on the daily kernel and the B2 loader.
- Better: the in-tree DTB minus whichever group B10/B12/B11 names, once known.

## 9. Root cause: the in-tree DTB has no phandle on the dcp and display-subsystem nodes

Round 3 so far:
- B10 (no apcie power-controllers) **fell back**, delta 208 s.
- B12 (kernel-train pcie description reverted) **fell back**, delta 208 s.
- B8 and B11 were still running when this was written.

No single DT group made a difference. That pointed at what the semantic diff hides by design: `norm.py` drops
`phandle` lines. So I compared the display nodes byte for byte.

### Byte-level differences between the display nodes (dcp9d against the in-tree twin DTB)

| Node | dcp9d | in-tree | Matters? |
|---|---|---|---|
| `dcp@48ae00000` | `phandle = <0xd3>` | **no phandle** | **yes** |
| `display-subsystem` | `phandle = <0xd4>` | **no phandle** | **yes** |
| `dcp@48ae00000` | `mboxes <0xd2>`, `iommus <0xd0 0x17>`, `apple,bw-scratch <0x12 0 5 0x20000>`, `clocks <0x5f>`; `status` after the gamut property | `<0x4d>`, `<0x4e 0x17>`, `<0x17 0 5 0x20000>`, `<0x4f>`; `status` before `clocks` | no: the same targets, renumbered; property order is irrelevant |
| `piodma`, `display-subsystem` `iommus` | `<0xd1 0x10>`, `<0xd1 0x00>` | `<0x50 0x10>`, `<0x50 0x00>` | no: renumbered |
| `clock-disp0`, both display DARTs, `mailbox@48ae08000`, `pmc-metadata` | phandles 0x5f, 0xd0, 0xd1, 0xd2, 0x12 | 0x4f, 0x4e, 0x50, 0x4d, 0x17 | no: renumbered |
| `panel` under the dcp | **present**: `apple,panel-j716`, 345x223 mm, max-brightness 600, `apple,color-gamut = "display-p3"` | identical | no |
| `/chosen/framebuffer@0` | - | identical | no |

**The panel node: lowest rank, not a candidate.** dcp9d has the same panel node as the in-tree DTB, property for
property. B5's `panel identity fallback: ADT parsed, panel node absent` is about the **ADT**: it has no top-level
`panel` node, so the sizes come from the DT panel node (`stage-c-analysis.md` row 21). Stage C printed the same line
with that panel node present.

### Why the missing phandles stop the boot

`dt_set_display_t6050()`, branch `n1-dt-gpu-dcp` @ 3e2321df:

```c
/* Node offsets move as properties are added: re-find each node by its phandle. */
u32 ph_dcp = fdt_get_phandle(dt, dcp), ph_disp = fdt_get_phandle(dt, disp);
u32 ph_on[] = {ph_dcp, ph_disp, fdt_get_phandle(dt, dart_dcp), fdt_get_phandle(dt, dart_disp),
               fdt_get_phandle(dt, mbox)};
for (unsigned i = 0; i < ARRAY_SIZE(ph_on); i++)
    if (!ph_on[i])
        bail("DCP: T6050: a display node has no phandle\n");     /* kboot.c:2296 */
```

The chain from there:
1. `bail` returns -1.
2. `dt_set_display()` returns -1 (`kboot.c:2336`).
3. `kboot_prepare_dt()` returns -1 (`kboot.c:3237`).
4. `payload_run()` prints "Failed to prepare FDT!" (`payload.c:345-347`).
5. `main.c:131` runs the proxy. `wdt_kick()` runs only per proxy request (`proxy.c:41`), and there is no host.
6. The stage-1 watchdog bites at 150 s. Error stage `0x30` is iBoot's value.

Why the in-tree DTB has no phandle on those nodes:
- dtc gives a node a phandle only when a property references it with `<&label>`.
- In the in-tree source, `dcp:` (`t6050-die0.dtsi:830`) and `display_subsystem:` (`:1106`) are labelled but only
  extended (`&dcp { ... }`, `t6050-j716s.dts:1140`), never referenced.
- The three DART and mailbox nodes are referenced by `iommus` and `mboxes`, so they have phandles.
- dcp9d came from `mk-dcp-dtb.py`, which gave all five nodes phandles.

Correction to section 3: I ranked H3 low because "only libfdt write errors bail". That was wrong: this `bail` is a
DT-shape check, and it is the cause.

What every boot did under this cause (all observed):

| Boot | Hand-off armed? | dcp/display-subsystem phandles? | Outcome |
|---|---|---|---|
| twin, twin-vrr, B2, B6, B10, B12 | yes | no (in-tree) | proxy, stage-1 watchdog: fell back |
| B1, B3 | no | n/a | booted |
| B5, stage C, dcp120 | yes | yes (dcp9d) | booted, DCP on the panel |
| B8 (in-tree minus `pwren-gpios`) | yes | no | **fell back**, delta 209 s, as predicted |
| B11 (in-tree variant) | yes | no | predicted to fall back; can be skipped |

The forward set (dcp9d plus one group each, and F-ALL) is **not built**. Every forward payload keeps dcp9d's phandles,
so all of them would boot and say nothing about the groups. F-X (the in-tree DTB with dcp9d's display nodes) would
boot only because it brings the phandles. One boot of B4 below is the direct test.

How to confirm without a boot: during the 150 s before the bite, stage 2 sits in the proxy with USB up. A host on the
tether can replay its log (`host/macos/m5.sh log`) and should see `DCP: T6050: a display node has no phandle` and
`Failed to prepare FDT!`.

### Fix payloads (`~/Work/agents/daily-dcp/bisect/`, 0600, `SHA256SUMS`)

The DTB is the in-tree one plus `phandle = <0x74>` on `dcp@48ae00000` and `phandle = <0x75>` on
`display-subsystem`. It is built by `fix/mk-dt-fix.py`: decompile c8f1b960, insert the two properties, recompile; the
unmodified DTS recompiles byte-identical. The result, `t6050-j716s-daily-dcp-phfix.dtb`, is sha256 67f43890.
- The raw DTS diff against the twin is exactly those two lines; the semantic diff is empty.

`mk-phfix.py` builds each payload. It first rebuilds the base payload byte for byte, then swaps the DTB. I re-parsed
each payload against its base: only the DTB differs. No watchdog bootargs.

| Payload | sha256 | Base (only the DTB differs) |
|---|---|---|
| **B4** `dcpfix-b4-nogpu-20261107-2b6f5c26.bin` | 2b6f5c26… | B2 `b6298d9c` (display hand-off, no GPU) |
| **B4-twin** `daily-dcp-phfix-test-20261107-e03be5ac.bin` | e03be5ac… | twin `dfe0c6cc` (`gpu=1` + display): the daily-dcp candidate |
| **B4-vrr** `daily-dcp-phfix-test-vrr-20261107-be84bb7d.bin` | be84bb7d… | VRR twin `3606884e` |

Boot order:
1. **B4**: should boot like B5 but on the in-tree DTB, with the DCP on the panel and the kernel-trained N1 (Wi-Fi up).
   That confirms the cause in one boot.
2. **B4-twin**: the real candidate. It is also the first boot ever of the GPU next to the DCP (H1 was never shown to
   work, only shown not to be this failure). If it falls back while B4 booted, the GPU + DCP pair is a second,
   separate problem, and section 3's H1 applies.
3. **B4-vrr**.
4. Skip B8, B11 and the forward set.

### Permanent fixes
- **m1n1 (preferred):** `m1n1-0029-dcp-give-display-nodes-a-phandle.diff` (next to this file). It is an uncommitted
  diff against `n1-dt-gpu-dcp` @ 3e2321df. A display node without a phandle gets a new one (`fdt_generate_phandle`),
  set from the highest offset down so the remaining offsets stay valid, and the rest of the function re-finds nodes by
  those phandles. A loader should not require the DT to reference a node. **Not built or compile-tested yet**; build
  with `build-m1n1.sh` and re-check the 0x410000 size.
- **DT, if the loader stays as it is:** make the in-tree DT reference `&dcp` and `&display_subsystem`, or carry the
  phfix DTB.
