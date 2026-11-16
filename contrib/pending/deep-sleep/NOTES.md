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
