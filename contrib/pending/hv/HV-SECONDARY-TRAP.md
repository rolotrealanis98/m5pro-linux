# Stage-2 trap on a secondary core, ASYNC trace path (m1n1 hv27-t6050, HEAD 63e6053c)

Static read only. Nothing run, no ssh, no build. Paths relative to <hv27 m1n1 tree>.
FACT = read from code (file:line). INFERENCE = not provable without a target log.

## Bottom line

1. FACT: no code on the ASYNC path is boot-CPU-only. The path from vector to USB ring is serialised by one lock (`bhl`) and never uses `hv_want_cpu`, `hv_pinned_cpu` or the interruptible-CPU rule. There is no `smp_id()==boot_cpu_idx` assert in usb_dwc3.c, uartproxy.c or iodev.c.
2. FACT: cpu0 holds nothing that blocks a secondary except `bhl`, and only while cpu0 is itself in an exception handler (hv_tick or proxy).
3. The "hv_tick keeps feeding the watchdog" fact is the strongest constraint, and it contradicts the premise "secondary deadlocked inside emit". hv_tick runs only inside `hv_exc_entry()`..`hv_exc_exit()` on cpu0 (hv_exc.c:776-786), i.e. with `bhl` held. If cpu0 can take `bhl` every ms, no secondary is parked inside `bhl` (emit, USB ring-full loop, proxy). Either that fact is wrong (see "verify the premise") or the hang is not in the trap path at all.
4. INFERENCE (best fit to all facts): the HV is alive and every core is either in the guest or idle; the guest is stalled before the first traced access (zero events, no prints). The tracers may be a bystander. Run the multi-core, no-tracer baseline and the breadcrumb dump before changing C.
5. Upstream m5-hv has nothing for this. `git log upstream/m5-hv -- src/hv src/uartproxy.c src/usb_dwc3.c src/iodev.c` has no SMP, event or lock commit. The only multi-core commits are Hector's 2021-22 `787c46e8` (adds the BHL) and `e750dfcc` (HV tick only on CPU#0, secondaries skip the BHL on a plain timer tick). Upstream multi-core mmiotrace has run through this same secondary emit path for years on T600x/T8112.

## Q1. Path of an ASYNC stage-2 data abort on a secondary

Vector (FACT):
- `_v_hv_sync` (hv_asm.S:127-137): `msr pan,#0`, push frame, `_hv_entry` (`dsb sy; isb`), `bl hv_exc_sync`. Stack is the per-CPU 64 KiB `secondary_stacks[cpu]` (smp_asm.h:9 `SECONDARY_STACK_SIZE 0x10000`; hv_saved_sp per CPU, hv_asm.S:185-196).
- `hv_exc_sync` (hv_exc.c:627): lock-free fast path only for ERET, MSR, IMPDEF-MSR, HVC (:637-660). DABORT_LOWER is not in it. Any fast-path failure falls through.
- `hv_exc_entry()` (:558-572): `msr daifclr,#4` (SError only; IRQ/FIQ stay masked from exception entry); clears this CPU's bit in `hv_cpus_in_guest` (:564) THEN `spin_lock(&bhl)` (:565). Clearing the bit before locking is deliberate so a rendezvous by the lock holder can complete while this CPU waits.
- `case ESR_EC_DABORT_LOWER: hv_handle_dabort(ctx)` (:680).

`bhl` is `DECLARE_SPINLOCK(bhl)` at hv.c:21. `spin_lock` (utils.c:141-170) is recursive per `smp_id()`, an unfair `ldaxr/wfe` loop, no timeout. `spin_unlock` is a release store.

hv_handle_dabort -> hv_emulate_rw -> hv_emulate_rw_aligned (hv_vm.c:1243 -> :1133 -> :981). For a write, the event is emitted BEFORE the physical store (:1000-1001); for a read, after the load (:1082-1083).

emit_mmiotrace (hv_vm.c:860-883), per 8-byte word:
```
hv_wdt_suspend();                                   // :875
uartproxy_send_event(EVT_MMIOTRACE, &evt, sizeof(evt));   // :876
if (sync) iodev_flush(uartproxy_iodev);             // UNBUF only
hv_wdt_resume();
```
uartproxy_send_event (uartproxy.c:298-318): `iodev_lock(uartproxy_iodev)` (:313); `iodev_queue` x2; `iodev_write(csum)`; `iodev_unlock`. The iodev lock is a separate recursive spinlock (iodev.c:131-145, taken only if `mmu_active()`).
-> `usb_0_queue/usb_0_write` (usb.c:243-262) -> `usb_dwc3_queue` (usb_dwc3.c:1347-1372) and `usb_dwc3_write` (:1375-1385, which also calls `usb_dwc3_cdc_start_bulk_in_xfer`, :933, bounded by `poll32(..., 1000 us)` at :399).

Locks and wait points on that path (FACT):

| Point | Where | Can block forever? |
|---|---|---|
| `bhl` | hv_exc.c:565 | Yes, if the holder never releases. Holder is only ever another CPU in an exception handler |
| `hv_cpus_in_guest` bit clear | :564 | No, atomic |
| iodev lock | uartproxy.c:313, iodev.c:131 | Only if someone holds it without `bhl` (see below) |
| `ready` test | usb_dwc3.c:1352 | Returns 0 at once if false (drops events, no hang) |
| ring-full loop | usb_dwc3.c:1360-1369 | YES. `while(count){ ringbuffer_write...; if(count){handle_events; start_bulk_in_xfer} }` has no timeout and does not re-test `ready`. It spins holding `bhl` and the iodev lock until the host drains the bulk-IN endpoint |
| `usb_dwc3_flush` | :1435-1448 | Same shape (UNBUF only) |
| `hv_wdt_suspend` | hv_wdt.c:107 | Not a wait. But it disables the SW watchdog for the duration, so a hang inside emit never barks |

Not on the ASYNC path (FACT): `hv_exc_proxy`, `hv_rendezvous`, `hv_want_cpu`, `hv_pinned_cpu`, `hv_maybe_switch_cpu`. Those are entered only when `hv_handle_dabort` returns false (hv_exc.c:719-728) or for SYNC hooks (`hv_exc_proxy(START_HV, HV_HOOK_VM)`, hv_vm.c:1035/1072). So the `hv_want_cpu` hand-off, `interruptible_cpu`, and `uartproxy_run` are irrelevant to a healthy ASYNC trap.

What cpu0 holds / needs:
- cpu0 in the guest (steady state after `p.hv_start()`): nothing. `hv_start()` calls `hv_enter_guest` without `bhl` (hv.c:296; `spin_lock(&bhl)` only after it returns, :299). The client is NOT looping in `uartproxy_run` on cpu0: the `hv_start` proxy request never returned, and its C stack is parked under `hv_enter_guest`. No proxy loop exists on cpu0 until some exception goes to `hv_exc_proxy`.
- cpu0 in hv_tick: `bhl` + `console_lock` (iodev.c:261-286) + the iodev lock briefly. See Q3.
- cpu0 in `hv_exc_proxy`/`uartproxy_run` (shell open): `bhl` for the whole shell session; every other CPU that traps blocks at :565 (or at :188-198 if it asked for the proxy). That is the intended stop-the-world behaviour.

Lock-order note (FACT): `console_lock -> iodev lock` (iodev_handle_events, iodev_console_write) versus `iodev lock -> console_lock` (printf inside usb code while `uartproxy_send_event` holds the iodev lock; usb_dwc3.c uses `usb_debug_printf` at :400, :885). An inversion exists in principle, but it needs two CPUs in these regions at once, and `bhl` excludes that except for printf from the lock-free fast paths (hv_exc_sync :637-660, `hv_hvc_dispatch_unlocked`, `hv_handle_msr_unlocked`) and the unlocked secondary FIQ path (:765-772). INFERENCE: low probability, no printf is expected there in normal operation.

Where a secondary can block forever, ranked by plausibility given the observed facts:
1. `spin_lock(&bhl)` at :565 behind a cpu0 that is itself stuck while holding `bhl`. Only cpu0 paths that hold `bhl` for long: shell open (hv_exc_proxy), `hv_rendezvous` (bounded, panics after 1M polls, hv.c:432-453), the ring-full loop in hv_tick/console flush. All contradict "hv_tick keeps petting".
2. The ring-full loop on the secondary itself: needs events already queued. Zero events were ever delivered, so the ring was never full of event data. Does not fit.
3. `hv_exc_proxy` wait loops (:181-198, :164-179): they release `bhl` while waiting, and only matter if `hv_want_cpu`/`hv_pinned_cpu` != -1. Nothing in the free-running state sets them (`hv_switch_cpu` hv.c:455, `hv_pin_cpu` :467 are called only by Python `cpu()` and `step()`, __init__.py:1203-1230).

## Q2. Why single-core works, and is the emit path safe off the boot CPU?

FACT, safe:
- `grep -n "smp_id\|boot_cpu\|is_boot_cpu" src/usb_dwc3.c src/uartproxy.c` returns nothing. `src/iodev.c:170` is the only hit and only guards the MMU-off console path (`if (!do_lock && !is_boot_cpu())`).
- USB is polled, not interrupt-driven. `usb_dwc3_handle_events` (:1078-1098) reads GEVNTCOUNT. There is no IRQ handler, so "interrupts masked on secondaries" is irrelevant. `exception_initialize` (exception.c:157-160) only differs in the pre-HV DAIF of non-boot CPUs; inside the HV, every exception entry masks everything anyway.
- `usb_dwc3` has no lock of its own. Mutual exclusion is the iodev spinlock plus `bhl`. `usb_0_handle_events` is called WITHOUT the iodev lock (iodev.c:276 holds only `console_lock`), so the dwc3 event ring is only protected by `bhl` in the HV. Same on cpu0 and secondaries.
- Secondaries run with the same EL2 stage-1 tables (`mmu_secondary_setup`, memory.c:608-646) and the same VTTBR/VTCR (`hv_init_secondary`, hv.c:330-376). Device MMIO, ring buffers and xfer buffers are shared identically.
- Per-CPU differences that could matter: stack (64 KiB each, enough: frames are a few hundred bytes), `TPIDR_EL2` = CPU index (set by smp.c:104; used by `smp_id()` and `PERCPU`), and `hv_secondary_info` copied at `hv_start` time (hv.c:268-290), so any HCR/HACR/MDCR change Python makes after `hv_start` does not reach secondaries started later (INFERENCE: not related here).

So the code gives no reason why the FIRST access from a secondary would behave differently from cpu0's. If the hang were in the emit path it would also hang on cpu0 in a cpus=1 guest. It did not: 52,666 events.

Single-core vs multi-core differences that are NOT in the emit path (INFERENCE, candidates for the real cause):
- Guest bring-up: `cpus=1` deletes ADT cpu nodes, so XNU never runs `configMiscCores`/CPU_START, never takes cross-CPU IPIs, never runs the T6050 CPU_START hook (last commit 63e6053c; hv_start_secondary, hv.c:401-420). Multi-core runs the SPTM/XNU secondary bring-up plus IPI emulation (hv_exc.c:504-522 `IPI_RR_LOCAL/GLOBAL`, :813-820). A lost or mis-targeted IPI hangs the guest silently, with hv_tick alive. Note the GLOBAL-IPI decode compares `(mpidr & 0xffff)` and on a 18-core multi-cluster T6050 a mismatch returns false and goes to the Python shell, so that variant would not be silent.
- Shared mutable state touched from the lock-free fast paths without `bhl`: `hv_sprr_cpus`, shadow pool and `sh->active` (hv_sprr.c:768-770, `hv_hvc_dispatch_unlocked` :1795). One CPU per core is expected, but the shadow pool and pt-page bookkeeping are global and also modified under `bhl` by the DABORT path (`hv_sprr_pt_updated`). A race gives a stale or wrong shadow TTBR for one core: guest hang with no HV message.
- Timing: `cpus=1` also changes what XNU runs when (the previous report's CLPC panic confound is still open).

## Q3. hv_tick

FACT:
- Runs only from `hv_exc_fiq` (hv_exc.c:754-800), only on `interruptible_cpu` = `hv_pinned_cpu`, else `boot_cpu_idx` (:765-768). Other CPUs on a plain timer tick take the lock-free early return (:770-774, `hv_update_fiq(); hv_arm_tick(true)`) and never touch `bhl`, the iodev, or the HV tick. A secondary takes the slow path only if another FIQ source is still pending (`ISR_EL1 & 0x40`: IPI, PMC, UPMC, guest timer) or `hv_want_cpu != -1`.
- Slow path = `hv_exc_entry()` (takes `bhl`) -> `hv_tick` (hv.c:571-586): `wdt_kick()` (writes WDT_COUNT, wdt.c, only if `m1n1.wdt=keep`), `hv_wdt_pet()`, `iodev_handle_events(uartproxy_iodev)` (console_lock; `usb_dwc3_handle_events`; then `iodev_console_write(NULL,0)` flushing the 8 KiB console backlog through `iodev_write` -> ring-full loop), `iodev_can_read` (HV_USER_INTERRUPT `hv_exc_proxy` if the host sent `!`), `hv_vuart_poll` (second USB pipe, same dwc3 device, `iodev_handle_events(IODEV_USB_VUART)`).
- It takes the same locks a secondary would block on: `bhl` first, then console_lock and iodev locks. It cannot run while any secondary holds `bhl`.

Therefore "cpu0's hv_tick keeps petting the watchdog while a secondary is deadlocked" can only hold if the secondary is NOT inside a `bhl` region: e.g. stuck in the guest, in a lock-free fast path (hv_exc_sync :637-660, `hv_sprr_*` unlocked handlers), in the `_hv_entry` `dsb sy`, or blocked in a `wfe`-wait elsewhere. It cannot hold for a secondary parked in emit_mmiotrace/usb_dwc3_queue.

Verify the premise (INFERENCE flags): `wdt_kick()` is also called from `proxy_process()` (proxy.c:41, commit 479b13ef) and does nothing unless the boot log said "Primary WDT left armed (m1n1.wdt=keep)" (wdt.c:46-47). If that line was absent, no watchdog was armed and "no reset for N minutes" proves nothing about hv_tick. Also the SW HV watchdog (`hv_wdt_*`, hv_wdt.c) is only active if Python set `wdt_cpu` (__init__.py:2360) and is blind inside `emit_mmiotrace` and `_hv_exc_proxy` because both call `hv_wdt_suspend()`.

Cheapest decisive probe: SIGINT the client. The Python `_handle_sigint` writes `!` to the USB iodev (__init__.py:2303-2312). That is serviced only by hv_tick on cpu0 (`iodev_can_read` -> `hv_exc_proxy(HV_USER_INTERRUPT)`). If the shell opens, `bhl` is free, cpu0 is alive, and the deadlock-in-emit hypothesis is dead. If nothing opens, hv_tick is NOT running and `bhl` (or cpu0's USB path) is wedged.

## Q4. Why does the whole guest stop, not just one thread?

Mechanisms, with consistency against the observed facts:
1. A CPU parks inside `bhl` (emit, ring-full loop, shell). cpu0 takes the slow FIQ path every 1 ms (:776) so it blocks at :565 within 1 ms; every other CPU blocks at its next slow-path trap (timers, IPIs, PMGR/MSR traps that miss the fast path). The guest stops within milliseconds, and hv_tick stops. FACT consequence: this predicts the hardware watchdog bites within about 170 s if armed, and `!` is ignored. Conflicts with "hv_tick feeds the watchdog" and with the run where the panel kept advancing 2 minutes after install.
2. Guest-level dependency stall (INFERENCE): the console prints from the IOKit matching thread. If that thread blocks (DCP/IOMFB start waits for a PMGR power-on, ASC boot, DART setup, or an IPI-driven cross-call), no more lines appear while other cores idle in WFI. Looks identical to a frozen guest. Zero events then simply means the traced pages were never reached. Fits: zero events, HV alive, no prints, SIGINT normal.
3. Lost IPI or a wrong shadow TTBR on one core (INFERENCE, see Q2): a CPU that never gets its cross-call blocks whatever thread waits on it; stop-the-world at a driver boundary is common (xcall at IOMFB start).

Which fits best: 2/3 over 1, given hv_tick-alive. The one fact in the list that supports 1 is the USB link dropping at about 2 minutes, but `ready` clearing (DTR drop / reconfig, usb_dwc3.c:645, :777-781) makes `usb_dwc3_queue` return 0 immediately (:1352), which cannot deadlock. The ring-full loop, though, never re-checks `ready` (:1360-1369): if DTR drops while it is already spinning, it spins forever holding `bhl`. That is a real latent wedge for heavy tracing, but needs events in flight, and in that run the panel was advancing, so it was not the multi-core freeze.

## Q5. Fix options

I did not find a defect in the secondary emit path, so no C change is justified as "the fix" yet. Ranked, with locations:

1. (d) + baseline first, zero C: run multi-core with NO tracers (or only RESERVED/OFF) and see whether the console still stops at the DCP line. If yes, tracing is not involved and the work is in SMP bring-up (IPI emulation hv_exc.c:504-522 and :813-820, sprr per-CPU/global state hv_sprr.c:768-770, CPU_START hook). If no, tracing is the trigger. Keep captures at `cpus=1` meanwhile (apply the `S3_7_C15_C11_3` vreg fix from TRACE-UNDER-SPTM-2 Q4 first, since cpus=1 otherwise panics in CLPC).
2. Smallest safe C change, diagnostic and hardening, about 15 lines:
   - usb_dwc3.c:1360-1369 (`usb_dwc3_queue` ring-full loop) and :1435-1448 (`usb_dwc3_flush`): re-test `dev->pipe[pipe].ready` each iteration and bail with a bounded retry counter (drop and count) so a vanished host cannot wedge `bhl`. Print the drop count once to raw UART (`uart_puts`, not through iodev).
   - hv_vm.c:860-883 (`emit_mmiotrace`): add `hv_wdt_breadcrumb('T')` before and `'t'` after `uartproxy_send_event`, so a CPU stuck there is visible in `hv_wdt_breadcrumbs` (static, hv_wdt.c:16) from the shell. Existing breadcrumbs already cover `hv_handle_dabort` ('0','1','2','3','4','7') but not the emit call itself.
3. (a) Per-CPU lock-free buffering drained by cpu0's hv_tick: a per-CPU SPSC ring of `struct hv_evt_mmiotrace` filled in `emit_mmiotrace` (hv_vm.c:860) for the ASYNC (non-UNBUF) case, drained in `hv_tick` (hv.c:571, after `iodev_handle_events`). Removes USB I/O and the ring-full spin from secondaries entirely, and from under `bhl` for every trap (a real latency win at 18 cores). About 60 lines; costs cross-CPU ordering (the MMIO_EVT_CPU field is already in `flags`, hv_vm.c:863, and per-ring order is preserved; cross-ring order needs a timestamp, `mrs(CNTPCT_EL0)`, which the event does not carry today). Worth doing if item 1 shows the trap path is the problem.
4. (b) Routing secondary traps through `hv_want_cpu`: wrong tool. That hand-off exists to move the Python shell between CPUs (hv_exc.c:164-179, :181-215) and costs a client round trip per access (it is the SYNC path). It also needs the interruptible CPU to reach `uartproxy_run`. Do not use for ASYNC.
5. (c) Pinning the device's accesses to cpu0: no mechanism in the tree. `hv_pin_cpu` pins only who may enter the proxy, not where guest threads run. Guest affinity cannot be set from the HV.

Upstream: `upstream/m5-hv` has not addressed this (see Bottom line item 5). Nothing in the local branch history (`git log --oneline -40 -- src/hv`) touches events, locks or SMP; the newest hv commits are `479b13ef` (wdt kick), `06a770c0`, `96393289` (AVNCR via GL2), `7f2feca4` (timer IMASK gating).

## Ranked next actions

1. Baseline: multi-core guest, zero tracers installed. Does the console still stop at the DCP line? (Separates "tracer/trap bug" from "SMP bring-up bug".)
2. On a frozen multi-core run with tracers: Ctrl-C the client. Shell opens: cpu0 and `bhl` are alive, drop the emit-deadlock hypothesis. No shell: hv_tick is dead, `bhl`/USB is wedged and the hv_tick/watchdog premise is wrong.
3. If the shell opens: dump `hv_wdt_breadcrumbs[0..17]` (symbol from m1n1.elf `nm`; 8 bytes per CPU, ASCII history, newest in the low byte). Reading: a CPU ending in `S` without `X` is blocked on `bhl`; ending in `...D0123` or `...T` is stuck in the abort handler or emit; ending in `s`, `#` or `x` returned to the guest. Then `hv.cpu(n)` is not possible for a CPU that never entered the proxy, so use the dump, not context switches.
4. Check the boot log for "Primary WDT left armed (m1n1.wdt=keep)". If absent, "hv_tick feeds the watchdog" is unproven. Also confirm whether `wdt_cpu` is set (SW watchdog).
5. Tripwire (TRACE-UNDER-SPTM-2 E1) on the multi-core guest: unmapped PTE instead of ASYNC. If it trips on a secondary, `hv_exc_proxy` entry from a secondary works and the shell shows `ctx.cpu_id` and ELR. If silent, the guest never reaches the page and the freeze is earlier.
6. Control (E2): ASYNC read-only on the AIC register page, multi-core. Proves ASYNC emission from secondaries at high rate (about 1 kHz per core) works on this tree.
7. Apply the C hardening in Q5 item 2 (ring-full timeout plus `ready` re-test, emit breadcrumbs). Rebuild only after 1-6 have not explained it.
8. Only if 5-6 show the secondary emit path itself failing: implement Q5 item 3 (per-CPU rings drained by hv_tick).
9. Keep `cpus=1` for all trace captures until 1-3 are answered, after adding the `S3_7_C15_C11_3` vreg.
