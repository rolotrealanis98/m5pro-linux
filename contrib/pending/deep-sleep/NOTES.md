# deep-sleep: T6050 suspend to RAM on the J716s (2026-11-15/16)

## Where the "boot loader" sleep data really comes from

No public boot loader produces it. Upstream wrote it into a static DT include instead:
`t6050-j714s-sleep-soc.dtsi` (PR #2030, `e0c68f7593d8`, merged 2026-11-16, 4564 lines) plus
`t6050-j714s-sleep-adt.dtsi`. Its commit message says the values are "the ones macOS uses on this machine" (J714s).
Before #2030 they lived in a private stack (PR #1963 description). They were recorded from a macOS sleep under aura's
hypervisor (`src/sptm_virt_s2r*.c`, `docs/sptm-nv2-virt.md`: "which is how the sleep sequence for Linux was recorded").
No public tool turns that recording into a dtsi. aura main fills only `apple,wake-enable(-gfx)` and
`apple,pinctrl-skip-pins` (#214). For the T6040, aura publishes register windows and tunables only, never sequences.

| Property (sleep node unless noted) | What it is | Source |
|---|---|---|
| `apple,wake-enable`, `apple,wake-enable-gfx` | AP / GFX-die wake sources left unmasked | ADT `/arm-io/pmgr` `ap-wake-sources` (index; >=320 is GFX). aura fills them |
| `apple,pinctrl-skip-pins` | AP pins not saved or restored | ADT `/arm-io/gpio0` `no-restore-gpio-pins`. aura fills them |
| `apple,sleep-low-pins` | pins driven low at entry (the codec reset) | board: the CS42L84 `reset-gpios` pin, AP 139 on J714s and J716s |
| `apple,commit-schedule-us`, `apple,commit-runway-us` | when each of the 20 commit steps runs before the sleep timer | macOS timing (J714s). Without it: no deep sleep |
| `apple,smc-sleep-policy` | pmVC value and the SMC message spacings | macOS SMC traffic (J714s). Without it: no deep sleep |
| `apple,seq-boot/-stage/-commit-wdt/-commit-afr/-commit-sio/-display-gate` | register sequences (kind, block, offset, value) | macOS PMGR/PMC/SPMI accesses (SoC) |
| `apple,clk-gating-boot` (3357 writes), `apple,cpm-boot` (84) | one-time clock-gating and CPM set-up at probe | macOS boot writes (SoC) |
| `apple,wake-order` (3475), `apple,entry-clk-words`, `apple,entry-perf-words` | words restored at wake / cleared / zeroed at commit | macOS PMGR accesses (SoC), checked against the ADT power-word table in `sleep-t6050-tables.h` |
| `apple,radio-*`, `apple,phy-park`, `apple,phy-down` | N1 link shutdown, wake and shared PCIe PHY sequences | macOS APCIE accesses (SoC) |
| `apple,ptd-sleep`, `apple,pmu-sleep-reads`, `apple,pmu-alarm-rearm`, `apple,pmu-wake-stage` | PTD request entry and bits; PMU reads; RTC control; boot stage | macOS PTD and SPMI traffic (SoC / PMU) |
| `apple,spmi-runtime-mask`, `-pmu-sources`, `-sleep-order`, `-sleep-gap-us` | nub-spmi0 masks and acks, order and spacing of the bus masks | macOS SPMI accesses (SoC) |
| `apple,complex-requests`, `apple,perf-floor-steps/-step-ms`, `apple,pmc-sleep-channels` | complex request per state; memory floor steps; PMC channels | macOS (SoC) |
| DART `apple,gapf-slice(-values)` | each stopped DART's GAPF slice | SoC address map (GAPF bank offsets) |
| PMP `apple,sram-keep`, report `apple,ptd-boot/-echo-entry` | PMP SRAM kept; PTD writes at boot | macOS, PMP firmware. Inert on the J716s: its PMP stays disabled |
| AOP/AOP2 endpoints, `init-arg`, `sleep/wake-message`; MTP `sleep-report`; SIO channel words | coprocessor firmware protocol | macOS traffic (J714s firmware) |
| DCP `sleep-*-args`, `panel-*` | firmware 27 display sleep call arguments | macOS IOMFB traffic (J714s, 27.0) |
| port00 `warm-reset-writes`, `endpoint-*-smc-writes`; NVMe `sleep-wake-delay-ms`; GPU `sleep-ps-auto` | N1 reset and SMC writes, ANS delay, GPU auto state | macOS (J714s) |

## What the J716s got (kernel branch `j716s-s2r-data`, local only)

`571617d9ef9c` on `af67d355377b` (cherry-pick of upstream `e0c68f7593d8`) on `j716s-s2r` `e8a25915a7ac`:
- `t6050-j716s.dts` includes `t6050-j714s-sleep-soc.dtsi`. It is the same SoC with the same sleep node.
- New: `t6050-j716s-sleep-adt.dtsi` with this machine's ADT values (macOS 27.3 ioreg). They equal the J714s's: pins
  5 6 7 112 141, the same 27 AP wake sources, and GFX source 1.
- Offline check: `check-t6050-sleep-dt.py KERNEL_TREE j716s.dtb j714s.dtb` replays the driver's parser
  (`t6050_sleep_map_regs/_radio/_ops/_data`). Result: PASS. 0 differences from the J714s in the sleep node and in every
  property the sleep consumers read (phandles resolved).

## Still blocking a real deep sleep on the J716s

1. **The boot object's S2R mailbox.** The driver needs `/chosen/aurora,s2r-mailbox`. Without it, probe stops with
   "no aurora,s2r-mailbox from the boot object: no deep sleep", and s2idle stays the only sleep. The reason is that
   iBoot locks RVBAR to stage 1's base, so a waking core re-enters the boot object, and that object has to send it
   back to Linux. Only aura does this (`smp_s2r_publish`, `smp_s2r_return_to_os`, plus the T6050 RVBAR veneer).
   Today's m1n1 stage 2 does not. aura `j716s` failed its first boot on 2026-11-16. Its fix is `j716s-fix1`, not yet
   booted.
2. **The display on firmware 27.3.** `dcp_v27_sleep_selected()` admits any T6050 DCP on the 27 class, but
   everything behind `dcp->v27_j714s` (panel services, A407, the AFK endpoint handling) is J714s with 27.0 only.
   Expect the first real attempt to be refused at `.enter` ("a bound display coprocessor is still running") or to
   fail in the DCP's suspend. Both are refusals before the commit, and devices resume after either.
3. **The PMP is disabled in the J716s tree.** The gate accepts an unbound PMP only when its power word is on and its
   ASC RUN bit is clear. Otherwise it refuses, which is also before the commit.
4. **Not measured on the J716s:** the schedule, the SMC spacings and the firmware values above.

## Suspend safety (from the code)

- From `.begin` to `.end`, WD2 runs at 120 s, so a hang in device suspend or resume resets the machine. The test
  slot then falls back to `boot.bin.prev`.
- Every refusal before SEP's stop returns `-EBUSY`, and devices resume. This covers the gates, the display,
  `pm_wakeup_pending`, the SoC check, the stage and the SMC notice. Upstream measured three clean sleeps after a
  refusal at `.enter` on the J714s.
- After SEP's stop there is no return path. A failure panics (`CONFIG_PANIC_TIMEOUT=10`, so a reboot and the
  fallback slot). The commit re-arms WD2 at 13 s until the sleep engine takes over, and the wake re-arms it at 120 s.
- One case needs a person: the SoC really sleeps and the PMU RTC alarm never wakes it (wake source masked or the
  alarm not armed). No watchdog runs through a real sleep; otherwise macOS-style sleeps would reset after 13 s.
- With the driver bound, deep becomes the default sleep. Every test boot must pass `mem_sleep_default=s2idle` so
  that a lid close or idle suspend cannot start a deep sleep by accident.
- At probe, the driver writes `clk-gating-boot`, `cpm-boot` and `seq-boot` on every boot, before any suspend.

## Built and requested

- Kernel `7.3.0-g571617d9ef9c` built in `/Volumes/m5pro/bench/pr-verify/kbuild-deep-sleep/`. Its DTB passes the
  offline check with 0 differences from the J714s.
- `deep-sleep-1` (`/Volumes/m5pro/bench/requests/deep-sleep-1.md`) uses today's loader and does no suspend. It checks
  that the sleep data does not break the boot or its consumers. Not booted yet.

- deep-sleep-1 **booted and passed** (orchestrator, 2026-11-16). It showed only the mailbox line from the sleep
  driver, `[s2idle]`, Wi-Fi and eDP working, and no new device errors.
- aura fix3 (`j716s-fix1` `16ab9c11`) boots, but it gives no mailbox: "CTXR_D is armed and the OS is outside its
  window". The check assumed that a core leaving reset is confined to CTXR_D. On this chain the 17 secondaries leave
  reset through the same locked RVBAR and run the veneer, aura and Linux outside CTXR_D, and they answer the heap
  probe. The fix is in aura alone; stage 1 does not change.
  - aura `j716s-s2r` `41272343` (worktree `/Volumes/m5pro/wt/aura-s2r`, local) publishes the mailbox when
    `ctxr_exec_probed_free_cpu()` names a secondary that ran the probe outside CTXR_D.
  - Built: `/Volumes/m5pro/out/aura/aura-j716s-s2r-nohostwait.bin` `01da2146...`. Host tests pass.
- deep-sleep-2 is requested: `/Volumes/m5pro/bench/requests/deep-sleep-2.md`, boot file
  `deep-sleep-2-20261115-4f36b617.bin`. Step 1 is probe only; step 2 is a `pm_test=devices` dry run.

## "failed to reserve memory for node 'sio-firmware-data@10bc89fc000' ... size 0 MiB"

- Source: the loader, not the sleep data. `dt_set_sio_fwdata()` in kboot creates the node. It is present in today's
  daily loader (the string is in `daily-hostwait.bin`) and in aura `j716s`/`j716s-fix1`. The sleep data adds no
  reserved-memory node, and no static node in the J716s DT is near 0x10bc89fc000.
- "0 MiB" is the kernel rounding down (`size / SZ_1M`). The SIO blobs are tens of KiB (`sio.c`, for example 0x1e000
  plus 0x4000 plus 0x1b80), and `alloc_mapped_data()` rounds every size up, so the size is not 0.
- Why it fails: for a `no-map` node, `early_init_dt_reserve_memory()` returns -EBUSY when the range is RAM that is
  already reserved, such as a loader /memreserve/ covering it. The message is the only effect. The pages stay
  reserved (the allocator never gets them) but keep their linear mapping.
- SIO is not affected. `apple-sio.c` reads `iommu-addresses` from the memory-region nodes itself, not through
  `of_reserved_mem`. SIO worked on deep-sleep-1.
- With aura the same message is expected. aura's `dt_reserve_hibernate_layout()` /memreserve/s RAM up to
  `hib_heap_end`, which covers even more. deep-sleep-2 step 1 dumps `memblock/reserved` and `/proc/iomem` to name
  the covering reservation.

## Next requests (after aura's fix has booted)

- deep-sleep-2: aura (fixed) plus this kernel, `mem_sleep_default=s2idle`. Non-suspending checks: the mailbox is
  published, the driver probes, `mem_sleep` shows `[s2idle] deep`, the display, GPU, Wi-Fi and NVMe are fine after the
  probe-time writes.
- deep-sleep-3: `pm_test=platform` dry run (devices suspend and resume, no `.enter`). Then one `rtcwake -m mem -s 30`,
  only once the dry run comes back clean, and attended the first time.

## deep-sleep-2 hung before userspace (2026-11-16)

- deep-sleep-2 (kernel `571617d9ef9c` with aura `j716s-s2r`) hung before userspace. It fell back unattended after
  219 s and left no journal and no pstore. The suspects are aura's mailbox commit, the kernel paths the mailbox
  switches on, and the sleep driver's probe-time writes.
- The kernel fix is `67e7ec279425` (release `7.3.0-g67e7ec279425`, `kbuild-deep-sleep2`):
  - the probe-time writes run only with `apple_sleep.t6050_boot_writes=1`; without them deep is not offered and
    `.begin` refuses;
  - debugfs `apple_sleep/t6050_boot_writes` runs `clk|cpm|seq FIRST COUNT` or `all`, and announces each range at
    KERN_EMERG before it runs.
- deep-sleep-3 is requested: the s2r loader with writes off, plus aura's USB console capture.
- deep-sleep-4 is outlined in the same request file. It uses the same boot file and runs the groups from ssh while
  `dmesg -w` streams live.

## deep-sleep-3 stopped about 13 s into the checks (2026-11-16)

- The mailbox was there and the writes were off. The debugfs read is ruled out: it only counts DT cells.
- The ds3 USB capture is the fallback daily's console (it has the `hostwait:` string, which the s2r loader lacks),
  not aura's.
- The kernel fix is `bddd15bb7fe6`, which adds two switches:
  - `spin_table_park=0` keeps plain spin-table despite the mailbox;
  - `apple_sleep.enable=0` leaves the controller unbound, and writing 1 to the parameter binds it at runtime.
- deep-sleep-4 is requested: one boot with live dmesg and heartbeat streams over ssh.
  - Stage A: mailbox on, kernel switches off. A stop here means aura.
  - Stage B: bind the controller at runtime. A stop here means the binding.
  - If both pass, the parking ops are left, and deep-sleep-5 tests them.

## deep-sleep-4 died within about 30 s (orderly restart 300100), 2026-11-16

- Every kernel-side effect of the mailbox was off, so that kernel behaved like deep-sleep-1's. The parameters, the
  420-byte bootargs and the layout are all fine.
- That leaves two suspects: aura's behaviour with the mailbox published (for example `smp_s2r_return_to_os()`
  reboots on an unarmed boot-core RVBAR entry, which would be an orderly restart), or the s2r kernel and DTB under
  any aura. No boot has had aura with the sleep node and hpm5.
- deep-sleep-5 is requested: boot-aura-3's fix3 loader (no mailbox) with kernel `bddd15bb7fe6`, `panic=0`, live
  streams and a 5 min soak.

## The cause is in aura's mailbox path; fixed and recorded (2026-11-16)

- next3-1 booted the whole s2r-data kernel under aura fix3 (no mailbox) and passed, so the kernel is cleared.
- aura `j716s-s2r` `74aa840e`:
  - `1e11b38a`: an unarmed boot-core RVBAR entry parks the core instead of calling `reboot()`.
  - Every RVBAR entry after the publish is counted per core in a 16 KiB page that Linux sees as MTD
    `aura_s2r_resets`.
  - Host test `tests/python/test_s2r_reset.py`.
  - `74aa840e` fixes 2 host-test regressions from `41272343`. That earlier commit had been reported as passing; it
    did not.
- Built loaders:
  - `out/aura/aura-j716s-s2r2-nohostwait.bin` `d7375c28...`;
  - `aura-j716s-s2r2.bin` (hostwait) `09f85e05...`.
- deep-sleep-6 is requested with deep-sleep-4's kernel and switches, `panic=0`, live streams, and the record read
  every minute.

## The debugfs read was the hang (2026-11-16)

- deep-sleep-6/7/8 (s2r2 aura with the mailbox, in every kernel configuration) were stable with no RVBAR entries.
  The record never caught one.
- deep-sleep-8 hung on `cat` of `apple_sleep/t6050_boot_writes`, as deep-sleep-3 had: 2 of 2.
- The cause was my bug in `t6050_boot_writes_open()`: it overwrote `single_open()`'s `seq_file` pointer with
  `struct apple_sleep`, so `seq_read()` ran on the sleep state.
- The fix is in `1387a783a606` (`kbuild-deep-sleep4`).
- pmu-scrpad 300134 is boot_stage 0x30, one counted failure, error stage 0x34 (after network-online).
- deep-sleep-9 is requested: the write ranges at runtime in probe order (clk in chunks of 500, then cpm, then seq),
  each announced at KERN_EMERG, then a soak, then one read to confirm the fix.
- Still open: deep-sleep-2's hang before userspace, with the writes at probe. Its reason is not yet known; it is
  either the writes or an aura reboot-path entry. aura now parks on that path instead of rebooting, and the record
  counts such entries.

## The CPM boot writes stop the J716s (2026-11-16)

- deep-sleep-9 and the orchestrator's bisection:
  - all 3357 clock-gating writes run clean at runtime;
  - CPM entry 0 alone (cluster 0's `cpm-impl-reg` block `0x2_10e40000` + 0x8000 <- 0) stops the machine within
    about 10 s, with or without the clock writes first.
- `apple,cpm-boot` is XNU's recorded runtime CPM traffic: per cluster, +0x8000 <- 0, +0x8008 <- 0, +0x40f8 <- 1.
  The sleep only reads +0x8000/+0x8008. One possible difference from the J714s: the J714s runs the PMP and the
  J716s does not. Unproven.
- `fb5f67175200` deletes `apple,cpm-boot` in `t6050-j716s.dts`, and an empty write group now counts as done.
  Deep sleep still works without the CPM writes; the entry needs only the reads.
- deep-sleep-10 (requested): the deep-sleep-9 file, with `clk` then `seq 0 125` at runtime. The boot sequence has
  never run on this machine.
- deep-sleep-11 (built `d48c11be`, requested only after deep-sleep-10 passes): the writes at probe, deep offered,
  then the step 1 checks and the `pm_test=devices` dry run.

## First dry run (deep-sleep-11) refused at .begin; fixed for deep-sleep-12 (2026-11-16)

- deep-sleep-10 passed: the boot sequence ran at runtime.
- deep-sleep-11: the writes ran at probe (no CPM), deep was offered, all checks were fine.
  - Its `pm_test=devices` run refused at `.begin` with -ENODEV, from PTD ownership: the J716s's PMP report is
    disabled.
  - The same `.begin` warned that the boot core's AGT timers were not cleared: the bound worker missed its 2 s.
- The kernel fix is `a629c409e709`:
  - a disabled PMP report leaves the PTD entries to the sleep;
  - the AGT write goes by IPI.
- deep-sleep-12 is requested: devices, then platform dry runs, with on-machine logs because ssh freezes.
- deep-sleep-13 (a real sleep with the PMU RTC alarm, `rtcwake -m mem -s 30`) is proposed for the owner's approval
  only. If the alarm fails to wake the SoC, a person has to press power.

## deep-sleep-12b crashed the DCP in the devices dry run; deep now refused at .prepare (2026-11-16)

- **What happened.** `.begin` passed. In the device suspend, `dcp_platform_suspend()` (dcp.c:8792 at
  `77f43d0e2a53`) took the firmware 27 display sleep.
  - `dcp_v27_sleep_selected()` (dcp-v27-sleep.inc:85) asks only for: a T6050 DCP, firmware 27, the T6050 sleep,
    adopt-live and the default method profile. The J716s on 27.3 matches all of them.
- **Why the firmware crashed.** In `dcp_v27_sleep_prepare()`, the step "open" (inc:1003) calls
  `dcp_v27_sleep_endpoints_open()`.
  - That function skips an endpoint only if it is in `dcp->sleep_v27_ep`. `afk_init()` (afk.c:139) fills that
    table only for `dcp->v27_j714s`, which is the J714s machine compatible. So on the J716s nothing was tracked.
  - It then ran `afk_init()` + `afk_start()` (inc:583/606) on endpoint 0x20, the system endpoint that
    `systemep_init()` had started at boot: `START_EP` (mailbox #122 `0x0050002000000002`), then `RBEP_INIT`
    (#123 `0x0080000000000000`) on its running ring.
  - The firmware asserted at `afk_messenger_common.c:246` with that exact message (`0x80000000000000`). The crash
    report arrived on the crashlog endpoint, which the firmware never advertised ("Message to undiscovered
    endpoint 0x01").
  - `afk_start()` waited 1 s for an INIT_ACK and returned -ETIMEDOUT. That is the `platform_pm_suspend returns
    -110`.
- **No 27.3 sleep path yet.** Even with the endpoint tracked, the rest of the sleep sends 27.0's literal tags:
  A484 (set_power_state), A500 (the sleep's own call), A414/A489/A487/A412 (display stage) and A115.
  - 27.2 and 27.3 renumbered those methods. set_power_state is A534/A535 there, and A500 is set_parameter_dcp.
  - The 27.3 tags of the sleep's own calls are unknown: the 27.3 trace has no power-state or sleep calls.
  - The A500 sleep entry exists only in the J714s's private copy of the 27.0 table.
- **Kernel `eb13c59cec29` on `j716s-s2r-data`** (not built):
  - `dcp->v27_sleep_known` is set only for the J714s on its 27.0 table copy.
  - `dcp_platform_prepare()` refuses a firmware (deep) sleep on any other T6050 firmware 27 DCP. It returns
    -EOPNOTSUPP before any device suspends and logs one line: `deep sleep refused: no display sleep known for
    firmware 27.3.0 on this machine (only the J714s on 27.0); s2idle is not affected`.
  - s2idle does not reach that branch (no `pm_suspend_via_firmware()`).
  - `dcp_v27_sleep_endpoints_open()` now refuses (-EPROTO) rather than start an endpoint that already has an
    untracked AFK ring. On the J714s every AFK ring is tracked.
- **Request:** deep-sleep-13pre, the deep devices and platform dry runs (refused, no crash), then an s2idle devices
  dry run.
- **What a J716s deep sleep needs from the display:**
  - the 27.3 tags of A484/A500/A414/A489/A487/A412/A115's methods, from a macOS 27.3 sleep trace of the DCP;
  - the endpoint tracking (`sleep_v27_ep`) opened to this machine;
  - then the same dry runs again.

## deep-sleep-13pre result (2026-11-16, `eb13c59cec29`, `deep-sleep-13pre-20261116-ef2bd978.bin`)

- Deep, `pm_test=devices`: refused at `prepare` with -95 and the one line `deep sleep refused: no display sleep known for
  firmware 27.3.0 on this machine (only the J714s on 27.0); s2idle is not affected`. `.begin` ran first (timer guard and
  PTD lines), no device suspended, no DCP crash, display connected, network up, 18 CPUs.
- s2idle, `pm_test=devices`: success +1, the display mode set again on resume, no new errors.
- So the J716s deep path now stops safely at the display. What it needs next: the 27.3 method tags of the display
  sleep's calls (a macOS 27.3 sleep trace through the HV), then the platform dry run, then an attended `rtcwake`.
- Logs: `/Volumes/m5pro/bench/deep-sleep/run13pre/`. deep-sleep-11's oops log: `/Volumes/m5pro/bench/deep-sleep/results/`.

## The 27.3 sleep tags are known; DPMS power-down and the deep step built, not booted (2026-11-16)

From the J716s's own DCP firmware 27.3 (`t605xdcp`), matched to 27.0 (26A428) handler by handler
(`derived-dcp/{macos-27.0-26A428,j716s-fw_Firmware_dcp}/rtxt.dis`, `switch_ap.json`; capture evidence in
`WINDOWS-MINING-20261116.md`):

| role | 27.0 (J714s) | 27.3 (J716s) | basis |
|---|---|---|---|
| set_power_state | A484 | A535 | handler 0x41fa820 (27.0 0x41f39f4); plain power-on `{1,0..}` OOB answers `01 00..` on the J716s |
| AP link release / wake | A500 | A550 | in code, not the table: 27.3 0x41ad070 `mov w9,#0x3530; movk w9,#0x4135,lsl#16` (27.0 0x41a6a48, #0x3030); handlers 0x41bee54 / 0x41b85f0 identical but one pointer offset, both want >= 4 bytes |
| pipe_cfg_414 | A414 | A464 | 0x41ffaf0; 8 zero bytes in, reply 01 on the J716s |
| pipe_query_478 | A489 | A540 | 0x41fa4f4; sent at every client open |
| pipe_set_476 | A487 | A538 | 0x41fa628; u32 1 in |
| is_main_display | A412 | A462 | 0x41ffd20 |
| A115 | A115 | A115 | 0x4258314, 0.98 alike, never sent on 27.3 |
| A442 (OOB) | A442 | A492 | 0x41fd7e4, 0.95 alike, never sent on 27.3 |

Not yet run on 27.3: set_power_state(0) (plain and flags `01 00 00 01 01..`), the command context for it, A550, A115,
A492.

Kernel (local, not pushed; worktrees under `/Volumes/m5pro/wt/`):

- **`j716s-dcp-sleep-27.3`** (`dcp-sleep-27.3`), head `07f30d5e4360`, release `7.3.0-g07f30d5e4360`, BUILD OK: next6 +
  #1941/#2019/#2063 (dcp-pm) + #2027-#2029 (T6050 DCP stop/power/restart helpers) + `83b3dafc746b` (the sleep's tags
  by build: every sleep call takes its tag from `iomfb_v27_sleep_tags()`, J714s 27.0 / J716s 27.3, nothing sent
  elsewhere) + `07f30d5e4360` (`appledrm.j716s_sleep`, default 0: 1 = display off on the running firmware, 2 = also
  the DCP stopped and powered down; every step logged as `J716s DPMS: ...`).
  Test file `dcp-sleep-27.3-20261116-9571d966.bin`.
- **`j716s-s2r-27.3`** (`s2r-27.3`), head `0558d13754ca`: the above + `appledrm.j716s_deep_sleep` (command line, default
  0) so the deep sleep's DCP .prepare runs the J714s step with the 27.3 tags instead of refusing; endpoint tracking
  (`v27_sleep_eps`) for the J716s; one `J716s: sleep step (...)` line per try. Release `7.3.0-g0558d13754ca`, BUILD OK;
  test file `s2r-27.3-20261116-44aa8fbe.bin` (s2r2 aura loader, `appledrm.j716s_deep_sleep=1`). Supersedes `j716s-s2r-data` (its five
  #2027-#2029 commits are in the base).
- Request: `/Volumes/m5pro/bench/requests/dcp-sleep-27.3.md` (part A DPMS levels 1/2 and s2idle devices; part B deep
  devices/platform dry runs).
