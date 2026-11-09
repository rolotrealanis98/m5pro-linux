# Tracing under `--sptm-mode emulation`, round 2 (m1n1 hv27-t6050, HEAD 63e6053c)

Static read only. No hardware, ssh or build. Paths are relative to <hv27 m1n1 tree>.
Tree state: only local change is the 5-line `handle_brk` edit in proxyclient/m1n1/hv/__init__.py:908-915. src/ is untouched.
FACT = read from code. INFERENCE = not provable without a target log.

## Bottom line

1. No C or Python path in this tree completes a guest MMIO access to a trace/hook page without emitting an event or printing a message. Every early return in the stage-2 abort path prints and drops to the proxy shell.
2. Guest XNU, SPTM and cL4 all run in physical EL1&0 with stage 2 on. There is no EL2&0 or E2H regime for the guest and no stage-2 bypass. Your F1 HCR value confirms it: VM=1, TGE=0, E2H=1, TTLB=1.
3. F4 is a missing vreg. `S3_7_C15_C11_3` is the next member of an already-virtualised family (`(3,7,15,N,3)` for N=1,3,5,7,9 are in the patch list; 11 is not). Add it and the UNDEF goes away.
4. Most likely F2 root cause (INFERENCE): the installs landed after the init traffic, and the steady state is quiet. The cpus=1 negative runs are also confounded by the CLPC panic. Prove it with an unmapped-page tripwire (Q5, E1), which bypasses event emission entirely.

## Q1. Path of a guest EL1 data access to a trace or hook page

### Entry (FACT)

`hv_exc_sync` (src/hv/hv_exc.c:627) first runs a lock-free fast path for ERET, MSR, IMPDEF-MSR and HVC only (:637-660). DABORT_LOWER is not in it. It reaches the locked section at :675 and then:

    case ESR_EC_DABORT_LOWER:        // hv_exc.c:680
        handled = hv_handle_dabort(ctx);

- The SPRR emulation handler is not consulted for aborts. `hv_sprr_handle_eret` and `hv_sprr_handle_msr` only see ERET and MSR/TLBI. Guest GENTER/GEXIT/sysreg/TLBI instructions were text-patched into HVCs (proxyclient/m1n1/hv/sprr.py:341-364), and HVCs go to `hv_hvc_dispatch*`.
- Loads and stores to MMIO are never patched. They fault at stage 2 straight into the lines above, regardless of the emulated GL1/GL2 context (XNU, SPTM or CL4).

### Context sensitivity inside `hv_handle_dabort` (src/hv/hv_vm.c:1243-1441), all FACT

- `hv_get_esr/far/elr/spsr` (hv.c:500-550) use the GL1 banked registers only if `in_gl12()` is true. That needs real `GXF_STATUS_GUARDED` on the HV core, which is false at m1n1's EL2. Guest GL is purely virtual (`sprr_guarded()`, hv_sprr.c:57). Your pre-start PMGR events prove this path works.
- `hv_translate(far, true, w)` (:1251, impl :426) uses `AT S1E1R/W`. The EL comes from the physical SPSR, and the tables are whichever shadow root is live in `TTBR*_EL12` (the el or gl variant).
  - Failure prints `HV: stage 1 translation failed` (:1255). It can fail on PAN or permission.
  - Out of range prints `IPA out of bounds` (:1260).
- Three SPRR-specific checks follow, all keyed on IPA, none on PC or context (:1267-1293):
  - `hv_sprr_is_pt_page` (write-protected guest table pages)
  - `hv_sprr_is_commpage`
  - `hv_sprr_is_shadow_page` (the shadow pool)
  
  A device IPA can only match them if it overlaps guest tables, the commpage or the pool. The pool is carved out of RAM and RESERVED by Python (`_reserve_sprr_pool`, __init__.py:1783-1796).
- There is no check on ELR being inside SPTM or TXM, no `hv_cpus_in_guest` test, no CTRR or "SPRR pool" region test (the only CTRR text in hv_vm.c is an L2-block alignment comment at :334), and no per-CPU "in trace" flag. I grepped for each.

### Every early return (all print and go to the proxy)

| Condition | Where | Visible as |
|---|---|---|
| S1 translate fails | hv_vm.c:1253-1256 | `HV: stage 1 translation failed` |
| IPA >= 2^vaddr_bits (42 bits on this SoC, from VTCR T0SZ=22) | :1258-1261 | `IPA out of bounds` |
| Unmapped IPA (PTE==0) | :1296-1300 | `HV: Unmapped IPA` |
| PTE is HW-valid | :1302-1307 | `Data abort on mapped page`, retry |
| ELR translate fails | :1314-1318 | `Failed to fetch instruction` |
| Instruction form not emulated | :1334, 1341 | `store/load not emulated: 0x%08x` |
| `far != vaddr` | :1372-1375 | `faulted at ..., but expecting ...` |
| Page-straddle, other half fails | :1383-1411 | prints |

### Access width and instruction forms (FACT)

- Widths 4-6 (16/32/64-byte LDP, STP, Q-register, DC ZVA) are split into aligned chunks by `hv_emulate_rw` (:1133-1190). `hv_pa_read/write` handle widths 0-6 (:906-970). `hv_pa_read` has no case 6 (a 64-byte read returns false, prints under `dprintf` only). That cannot occur for a 64-bit MMIO register.
- Atomics (`LDADD`/`SWP`/`CAS`, mask `insn & 0x3b200c00 == 0x38200000`) and exclusives are not in `emulate_load/store`. They fall through to Python `handle_dabort` (__init__.py:917-956), which maps the 16K page HW, single-steps it, then calls `pt_update`.
  - They log `Unhandled atomic`/`Unhandled exclusive`, but they do not emit an MMIO event.
  - Atomics do not stay silent either.
- LD64B and ST64B are not implemented by this core and are not handled by m1n1.
- `STR q` pre/post-index, `LD1`/`ST1` multi-structure and similar forms are missing from `emulate_*`. They print `not emulated` and open a shell. They are not silent.

### Event emission

- ASYNC and UNBUF (SPTE_MAP plus trace bits): `hv_emulate_rw_aligned` (:981) calls `emit_mmiotrace` (:860-883) when `pte & SPTE_TRACE_WRITE` (:1000) or `pte & SPTE_TRACE_READ` (:1082). It does the real access via `hv_pa_rw`.
- SYNC (type 4 = `SPTE_PROXY_HOOK_RW`): `hv_exc_proxy(START_HV, HV_HOOK_VM)` (:1035, :1072), then Python `handle_vm_hook_mapped` (__init__.py:535-633).
- Python-side silent drops (`handle_mmiotrace`, __init__.py:494-524), only these:
  - an entry with `mode == OFF` is skipped with `continue`
  - the map list for `evt.addr` is empty
  
  Neither applies to your F1 maps. The `ERROR: mmiotrace event but expected ...` case prints.
- `PrintTracer.event_mmio` (trace/__init__.py:158) calls `device_addr_tbl.lookup(evt.addr)`. A KeyError would go through `shellwrap` and open a debug shell. It is not silent.

Conclusion: stage-2 trace and hook PTEs, once effective on the faulting core, cannot swallow the access. Silence means no fault was taken.

## Q2. Could XNU device accesses bypass hv_Ltop stage 2?

No (FACT):

- Regime. `hv_init` (hv.c:157-165) sets `HCR_E2H|HCR_VM|...` and never sets TGE. The HV is the VHE host. The guest runs EL1&0 with stage 2 on. Your read (bits 0, 3, 5, 6, 21, 25, 31, 34, 37, 40, 41, 53, 55, 56 = VM, FMO, AMO, VF, TACR, TTLB, RW, E2H, TEA, API, APK, EnSCXT, TTLBOS, ATA) matches. `mmu_el20`/`mmu_el10` in hv_sprr.h are virtual-state bookkeeping for what the guest believes is EL2 vs EL1. They never select a hardware regime. `HCR_EL2` as seen by the guest is a shadow (hv_sprr.c:187).
- Shadow tables. `sprr_mirror_entry` (hv_sprr.c:628-740) copies the guest PTE (`base = d & ~perm bits`, `descriptor = base | pel`). Output addresses stay IPAs. Only permission bits are rewritten. Device leaves are not special-cased. Shadow roots go into hardware `TTBR0/1_EL12` (`sprr_write_hw_ttbr`, :763). The walker's own accesses pass through stage 2, which is why the pool is mapped RO in stage 2 (`hv_map_hw_ro`, :310).
- `sprr_ipa_to_pa` (hv_sprr.c:394) is called only for guest table pages and the commpage (:435, :479, :713, :739), never for device leaves.
- The vector page at VA 0xffffffffffffc000 only injects an HVC for guest-internal exceptions. Stage-2 aborts always go to EL2 and never reach it.

## Q3. ASYNC flushing and what remains

FACT:

- `emit_mmiotrace` (hv_vm.c:860) calls `uartproxy_send_event` (uartproxy.c:298), which is `iodev_queue` x2 plus `iodev_write(csum)`. For USB, `.write` is `usb_dwc3_write`, which queues into the ring and calls `usb_dwc3_cdc_start_bulk_in_xfer` (usb_dwc3.c:1375-1385). So every event kicks the bulk-IN endpoint. A second kick cannot start while `xfer_in_progress`, so a later `usb_dwc3_handle_events` is needed to refill.
- That is called from `hv_tick` (hv.c:571, `iodev_handle_events`) at `HV_TICK_RATE` = 1000 Hz on the interruptible CPU (hv_exc.c:766-790), from `usb_dwc3_queue` whenever the ring is full (:1365), from `iodev_flush` (`while (ring used || xfer_in_progress) handle_events`, :1435), and at the end of every `uartproxy_run` reply (:291-292). UNBUF flushes synchronously (`emit_mmiotrace(... sync)`).
- So ASYNC latency is about 1 ms and the events are not stuck waiting for a buffer to fill. The client being inside `hv_start` -> `reply()` is irrelevant. That loop dispatches EVENT packets (proxy.py:290-299). The `unkhandler` path prints raw console bytes.
- Real silent-drop path (FACT): `usb_dwc3_queue/write/flush` return immediately when `pipe[pipe].ready` is false (usb_dwc3.c:1352, 1393, 1437). `ready` clears on host DTR drop (SET_CTRL_LINE_STATE, :777-781), on interface re-config (:645) and on bus reset. If the host closes and reopens the tty, events (and console) are discarded until DTR returns. This matches F5's "link dropped", but it cannot explain F2, where the link was healthy.
- SYNC does not use the ring. It is `hv_exc_proxy` -> `uartproxy_run` (reply path, flushes) plus a Python callback print. If F2 were a flush problem, SYNC would have printed. Silent in both modes means the fault never fires.

Explanations that remain for F2, ranked (INFERENCE unless noted):

1. No qualifying guest access in the window. Live install happens after driver init. The SEP, DCP and SMC bring-up handshakes are bursts at kext start. After that: no userland yet, static console, so no DCP swaps, no sensor polls. The only observed event stream (44 PMGR events) is the HV's own ATC hooks, which fire only when XNU powers the proxy's USB domain. It says nothing about steady-state MMIO traffic.
2. The guest does not touch these IPAs at all (alias, or the driver talks elsewhere). Address choices come from Linux-style `reg0+0x8000` for SEP and DCP, and Linux's SMC window.
3. The PTE is not effective on the faulting core (stale TLB, or reverted). Weak, because F1 did `dsb ishst; tlbi vmalls12e1is; dsb ish; isb` and VMID is 0 everywhere. But F1 only walked once, immediately after install. Re-walk after a minute to rule out reversal. Python `pt_update` (__init__.py:414) issues the TLBI with no DSB. The C helpers have them (hv_vm.c:419-423).
4. The cpus=1 observations are confounded by F4: if the single-core guest panicked in CLPC before the traced drivers started, no events were possible. When did the panic happen relative to the 100 s windows?

## Q4. `S3_7_C15_C11_3`

### Does the tree know it? (FACT)

No. `grep` over src/ and proxyclient/ finds nothing for `(3,7,15,11,3)`.

- Same CRm/op2 at other op1: `EHID18_EL1` = (3,0,15,11,3) (src/cpu_regs.h:384) and `SPSR_GL2` = (3,6,15,11,3) (apple_regs.json).
- Neighbours at op1=7: `UPMC4` = (3,7,15,11,4) and `UPMESR1` = (3,7,15,11,5). Both are UPM and are in a different HACR group.
- The patch list `HV_VREGS` "Unknown" block (sprr.py:244-298) already holds `(3,1,15,0|1|2,3)` and `(3,7,15,1,3)`, `(3,7,15,3,3)`, `(3,7,15,5,3)`, `(3,7,15,7,3)`, `(3,7,15,9,3)`. The odd-CRm op2=3 sequence stops at 9. 11 is the next in the arithmetic progression (INFERENCE: 13 and 15 probably exist too, as T6050 adds CLPC regs).
- HACR_EL2 bit 59 is `TRAP_s3_1z7_c15_cx_3` (sysreg.py:304, apple_regs.json:402), which describes exactly the group (3,{1,7},15,*,3).

### How the HV normally avoids IMP-DEF UNDEFs (FACT)

1. `HV.init()` (__init__.py:1482-1493) sets only HACR `TRAP_CTRR|EHID|HID|ACC|IPI|SERROR_INFO|PM`. TRAP_UPM (58) and bit 59 are not set. `TIDCP` is 0 (:1474) and `TACR` is 1.
2. HACR traps arrive as EC=0x3f/ISS=0x20 with the real ISS in AFSR1. `hv_exc_sync` handles them at hv_exc.c:644-650 and :696-702 via `hv_handle_msr_unlocked/hv_handle_msr` (the `SYSREG_PASS` tables, hv_exc.c:395-445). Otherwise they go to Python `handle_impdef` -> `handle_msr` (:699-784, which has `shadow`, `skip` and `ro` sets plus pass-through).
3. Under SPTM emulation, XNU, SPTM and TXM were written for EL2/GL2 but run at physical EL1. Registers that UNDEF at EL1 are turned into HVCs at load time. `patch_text_sprr_emu` matches the exact MSR/MRS opcode against `_SYSREG` built from `HV_VREGS` (sprr.py:341-364), only in `__TEXT_EXEC` and `__TEXT_BOOT_EXEC` (`load_hook`, __init__.py:1996-2001). The C side in `hv_sprr_emulate_sysreg`: unknown vregs fall into `default:` and are plain per-CPU shadow storage (hv_sprr.c:1666-1672), so reads return the last write, 0 initially.
4. Anything not in the list executes natively and UNDEFs if the core forbids it at EL1. That is what F4 shows: the instruction is outside the list, so it reached hardware, UNDEFed at EL1 and XNU panicked (`sleh.c:1953`).

### Why only the cpus=1 guest (INFERENCE, nothing in the tree ties it to tracers)

No code path links a tracer install to this UNDEF. A mid-run `hv_pt_update` does not touch sysregs. Candidates, none verified:
- A cluster-idle or last-CPU path in CLPC that never runs with other cores kept busy.
- Boot-arg or ADT dependence: `setup_adt` (__init__.py:1733) and `run_guest.py --cpus` (:99-106) delete ADT cpu nodes. A CLPC init that iterates ADT cpus and picks core-type registers could differ if the one remaining node does not match the physical core type.
- Timing: CLPC reaches this code later than the multi-core guests were observed.

To decide: disassemble the kext around 0xfffffe003c4fc398 and read the guard conditions of the function. The panic backtrace is already on screen.

### Smallest fix

Option A (idiomatic, needs an m1n1 rebuild, 2 lines):
- sprr.py: append `(3, 7, 15, 11, 3),` after `(3, 7, 3, 14, 1),` (:297).
- hv_sprr.h: add `HV_VREG_S3_7_C15_C11_3,` after `HV_VREG_S3_7_C3_C14_1,` (:321, before `HV_VREG_MAX`).
- Indices must stay in sync because the vreg ID is the list index. Appending keeps existing IDs. Count is 267, limit is 511 (9-bit field).
- Optionally add (3,7,15,13,3), (3,7,15,15,3) and (3,1,15,3..,3) pre-emptively. Unused vregs cost nothing.
- Semantics: writes stored, reads return the stored value (0 at start). Handled in the lock-free fast path.

Option B (Python-only, no rebuild, hot-path free): in `patch_text_sprr_emu` (sprr.py:341), before the `_SYSREG.get` branch, special-case `(w & ~0x1f) == sysreg_encode((3,7,15,11,3), 0)` (an MSR) -> `0xd503201f` (NOP), and the read form `sysreg_encode((3,7,15,11,3), 1)` -> `0xaa1f03e0 | Rd` (`mov Xd, xzr`). RAZ/WI, no read-back. `0xd51ffb68` is the MSR with Rt=8.

Not recommended: HACR bit 59 plus a `skip` entry in `handle_msr`. I could not verify that setting the bit converts the EL1 UNDEF into an EC 0x3f trap on T6050 (run proxyclient/experiments/hacr_trap_bits.py with bit 59). Even then each access costs a UART round trip to Python.

## Q5. Recommendation

Most likely root cause for F2 (INFERENCE, ranked first above): the observation windows contain no accesses to those pages. This is a methodology artifact. Nothing in m1n1 drops events.

### Experiments (Python, no rebuild)

E1 (tripwire, decisive, bypasses event emission and flushing). At the paused shell:

    for pg in (dcp_mbox_page, sep_mbox_page, smc_mbox_page):
        hv.p.hv_map(pg, 0, 0x4000, 0)          # invalid, PTE==0
    hv.u.inst(0xd5033a9f)                      # dsb ishst
    hv.u.inst(0xd50c83df)                      # tlbi vmalls12e1is
    hv.u.inst(0xd5033b9f)                      # dsb ish
    hv.u.inst(0xd5033fdf)                      # isb
    hv.cont()

Any guest touch prints `HV: Unmapped IPA 0x...` and opens the shell with the real ELR and FAR. `hv.addr(hv.ctx.elr)` gives the symbol. Use raw `p.hv_map`, not `trace_range`, so `pt_update` cannot overwrite it. An atomic access instead logs `Unhandled atomic` and keeps going. Fault means: now trace that page ASYNC and read the PC and caller. No fault means the guest does not touch it, or the entry is stale (re-walk with `hv.p.hv_pt_walk` after a minute).

E2 (control that live install works): ASYNC read-only on the AIC register page that XNU hits on every interrupt (about 1 kHz), for a couple of seconds:

    hv.trace_range(irange(aic_base, 0x4000), TraceMode.ASYNC, write=False)
    hv.pt_update()
    # DSB/TLBI/DSB/ISB as above
    hv.cont()

Remove with `hv.trace_range(zone, TraceMode.OFF)` (deletes the tracer). Do not use RAM for the control without a custom callback: `PrintTracer.event_mmio` calls `device_addr_tbl.lookup`, which raises KeyError outside /arm-io and opens a debug shell.

E3 (discover the real window if E1 stays silent): tripwire every 16K page of `/arm-io/dcp` and `/arm-io/sep` reg0 one at a time, and the SMC reg0 range. The first hit tells you the true register page.

E4 (from guest start). Evaluate the earlier D.2 (late install from the AMCC read callback, report TRACE-UNDER-SPTM.md:92-112):
- Strengths: single core running (SPTM init only), `pt_update` runs right after the callback while the guest is stopped (__init__.py:1063), ASYNC avoids per-access UART latency, and it precedes XNU's driver start so init handshakes are caught.
- Risks:
  - Python `pt_update` TLBI has no DSB.
  - The AMCC read happens early in SPTM and does not by itself prove SPTM won't touch the mailboxes. Whatever SPTM does there is exactly what the pre-start BRK/IABORT investigation (report section B) is about.
  - The callback signature must be `(addr, width=None)`.
- Verdict: reasonable as the first from-start attempt. Trigger it with WSYNC or ASYNC on the three mailbox pages only, not whole devices. Check for the `Guest BRK ... not reflecting` line from the new `handle_brk` after install.
- Alternative trigger that lands even closer to driver start: a guest breakpoint on an XNU symbol (`hv.resolve_symbol`, `_bp_hooks` in handle_break, __init__.py:975-984). UNTESTED here.

### Next actions, ranked

1. Add `(3,7,15,11,3)` to both HV_VREGS lists (Q4 option A) or the NOP/`mov xzr` patch (option B). Nothing else is needed for F4.
2. Run E1 (tripwire) for DCP, SEP, SMC on the multi-core guest, installed as early as you can.
3. Run E2 (AIC control) to separate "live install is broken" from "no traffic".
4. Re-walk `hv_pt_walk` on the installed pages after about 60 s to rule out reversion.
5. If E1 trips: ASYNC-trace that page from the PC it shows. If silent, E3 to find the true register window.
6. For from-start tracing, D.2 with the three mailbox pages only.
7. Find out when the cpus=1 CLPC panic happened relative to the 100 s trace windows. If it came first, discard those runs. Disassemble the kext at the panic PC to get the guard conditions.
8. Add DSB around the Python `pt_update` TLBI (`self.u.inst(0xd5033a9f)` before, `0xd5033b9f` after) for live installs on multi-core guests.
9. F5 (USB link drop after the DCP tracer): check the host tty for a DTR drop (`ready` false, usb_dwc3.c:777-781) and for `UartChecksumError` in the client (proxy.py:296-298). A hot DCP mailbox plus per-access ASYNC print can also stall the HV in `usb_dwc3_queue`'s ring-full loop with `bhl` held.
