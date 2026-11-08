# Tracing MMIO under `--sptm-mode emulation` (m1n1 hv27-t6050, HEAD 63e6053c)

Static read only. Nothing was run. Paths are relative to <hv27 m1n1 tree>.
Items marked FACT are read from code. Items marked INFERENCE are not proven without a log from the target.

## 0. What "SPTM emulation" is in this tree

FACT: there are no SPTM hypercall or SPTM "map IO page" handlers in m1n1. `grep -i sptm` over src/ and proxyclient/ shows only:
- mode flag: `hv_sptm_mode` (src/hv/hv.c:34, set by `hv_sptm_set_mode` at hv.c:135)
- SPRR/GXF emulation (src/hv/hv_sprr.c)
- patching of the guest's SPRR/GXF sysreg and TLBI instructions into HVCs (proxyclient/m1n1/hv/sprr.py, applied in `load_macos_sptm`, proxyclient/m1n1/hv/__init__.py:2012-2016)
- AMCC/CTRR virtualisation (proxyclient/m1n1/hv/amcc.py, src/hv/hv_amcc.c)
- CPU power-control hooks (src/hv/hv_cpu_power.c)

The real, unmodified SPTM binary runs as the first guest stage. It builds its own stage-1 tables in guest RAM. m1n1 mirrors them into per-world "shadow" stage-1 tables (src/hv/hv_sprr.c:628-740 `sprr_mirror_entry`) and runs the guest on the shadows. Stage 2 (IPA to PA) is a single table, `hv_Ltop` (src/hv/hv_vm.c:118, VTTBR set at :143). SPTM never touches stage 2.

## A. How are guest MMIO mappings created, and by what?

Answer: only by m1n1's own stage-2 writers, all calling `hv_map()` on the one table `hv_Ltop`. The guest/SPTM path creates no stage-2 entries.

FACT, the writers:
1. Python `HV.pt_update()` (proxyclient/m1n1/hv/__init__.py:348-419) walks `dirty_maps`/`mmio_maps` and issues `p.hv_map` through `unmap`/`map_hw`/`map_sw`/`map_hook_idx` (lines 209-256). `hv.init()` registers every `/arm-io` range as a `"HW"` `TraceMode.OFF` tracer (1458-1460, the "Map MMIO ranges as HW" loop), so MMIO gets identity-mapped HW by the first `pt_update`.
2. `HV.start()` order (2314-2326): `map_essential()` (live `map_hook` calls plus RESERVED tracers), then `pt_update()`, then upload ADT, then `p.hv_start()`.
3. C-side hooks installed inside `hv_start()` AFTER that pt_update (src/hv/hv.c:239-253): `hv_cpu_power_init` (hv_cpu_power.c:76-118, CPU/CPM control hooks), `hv_amcc_init` (-> `hv_aic_hook`, hv_aic.c:71), `hv_cpu_state_setup_hook` (hv.c:252). They are not in Python's `mmio_maps`, except the cpu-state slot ("CPU STATE HACK", RESERVED, __init__.py:1604-1606). A later `pt_update` over a zone that overlaps them would re-map those pages HW. Your zones do not overlap them.
4. HV-internal RAM stage-2 edits: `hv_map_hw_ro` for shadow-pool chunks (hv_sprr.c:310), `hv_pt_set_writable()` write-protecting guest page-table pages and the commpage (hv_sprr.c:336, 370, 476; hv_vm.c:403-424). RAM only, never MMIO.
5. Python `HV._reserve_sprr_pool` does a live `unmap` of the pool and RESERVED-marks it (1793-1794).

Does a later `pt_update()` rewrite entries "created by SPTM"? There are none. `pt_update` only rewrites zones in `dirty_maps`, and for each overlapping `mmio_maps` piece it applies the highest-priority mode. RESERVED zones are skipped (`continue`, line 378), OFF -> `map_hw`, ASYNC/UNBUF/BYPASS -> `map_sw` with trace bits (SPTE_MAP, invalid PTE), SYNC/HOOK/WSYNC -> `map_hook_idx` (invalid PTE, SPTE_PROXY_HOOK_x, id 0).

The guest's stage-1 leaf for a device page just carries the IPA through (`sprr_mirror_entry` copies `base | perm_bits`, hv_sprr.c:~700-740). Whatever stage 2 says for that IPA applies, with no SPTM-specific stage-2 state to desync.

## B. Why would a pre-start trace range make the first stage fault?

### B.1 The IABORT at 0x200 is most likely the shell's own BRK reflection (INFERENCE, strongly supported by code)

FACT: guest exceptions of class BRK (EC 0x3c) are routed to EL2 (`MDCR_EL2.TDE=1`, __init__.py:1493). The C side does not handle EC BRK (src/hv/hv_exc.c:632-748, no BRK case). The exception goes to the proxy and Python `handle_sync` -> `handle_brk`:

    def handle_brk(self, ctx):                       # __init__.py:907
        iss = ctx.esr.ISS
        if iss != 0x4242:
            return self._lower()                     # any other BRK is auto-"lowered" to the guest

FACT: `_lower()` (1151-1182) writes ELR_EL12/SPSR_EL12/ESR_EL12/FAR_EL12 from the context and forces the return state:

    self.ctx.spsr.M = SPSR_M.EL1h   # ... D/A/I/F = 1
    self.ctx.elr = self.u.mrs(VBAR_EL12) + exc_off    # exc_off = 0x200 for a SYNC from EL1h

It returns True, so `handle_exception` treats it as handled and prints nothing for the BRK.

FACT: before the guest enables SPRR, `VBAR_EL12` is the value `hv_init` set: `msr(VBAR_EL12, 0)` (src/hv/hv.c:183). `sprr_update_vbar` (hv_sprr.c:863-880) only starts managing VBAR once `sprr_en` is set (`hv_sprr_activate`, 925-952). So the reflected BRK lands at IPA 0x200, which is unmapped. That gives IABORT_LOWER at ELR 0x200, SPSR EL1h (forced by `_lower`), VBAR 0, and the guest's x0 untouched (0x20003 would then be SPTM's own register value at the BRK).

This matches all four symptoms you listed exactly. The faulting thing is probably not an MMIO abort. SPTM (still in its pre-SPRR phase) executed a BRK, i.e. a panic or assert, and m1n1 forwarded it into a guest with no vectors.

How to confirm (once in the shell on the IABORT): `hv.u.mrs(ELR_EL12)` is the BRK address, `hv.u.mrs(ESR_EL12) >> 26 == 0x3c` with the immediate in the low 16 bits, and `hv.u.disassemble_at(hv.p.hv_translate(elr, False, False) - 16, 32, ...)` shows the call site. The SPTM symbol or caller then tells you which check failed.

### B.2 Why the BRK would appear only with a tracer

No code excludes SPTM's early accesses from tracing, and nothing requires tracers to wait for `sptm_init`. There is no SPTM-state-dependent hook dispatch. Hooks are dispatched purely by stage-2 PTE type in `hv_handle_dabort` (hv_vm.c:1243-1441) -> `hv_emulate_rw_aligned` (981-1130). Pre-start tracing of SPTM-touched pages is known to work: the "SPTM AMCC" HOOK entries (`load_macos_sptm`, __init__.py:2197-2200) are 4-byte invalid-PTE hooks read by SPTM at its first instructions.

So the break is device-specific. Mechanisms that make a traced page behave differently from a passthrough HW page, all FACT from code:
- Every access to an ASYNC/SYNC page is a stage-2 fault, emulated by decoding the instruction (`emulate_load`/`emulate_store`, hv_vm.c:550-858) and split into aligned chunks (`hv_emulate_rw`, 1133-1190). Unsupported forms -> "HV: load/store not emulated" -> proxy shell with a DABORT, not a BRK. Atomics and exclusives are only handled by Python `handle_dabort` (__init__.py:917-956), which temporarily maps the 16K page HW, single-steps, then `pt_update`s it back.
- A split or multi-register access (LDP, Q-register, 128-bit; widths 4-6) becomes several 8-byte reads/writes (`hv_pa_read` width cases, hv_vm.c:928-970). A read-with-side-effect FIFO (dockchannel RX, mailbox) can be popped more than once or in a different order than the CPU would have.
- Latency: SYNC pays a UART round trip per access (`handle_vm_hook_mapped` -> `u.read`, __init__.py:568); ASYNC pays a UART event per access (`emit_mmiotrace`, hv_vm.c:860-883). SPTM polling the dockchannel/SEP mailbox with a counter timeout can time out and panic. On T6050 the tree already treats the SEP mailbox as dangerous (commit 72ed8f9c "kboot: T6050: keep off the SEP mailbox").
- A Python exception inside a SYNC handler leaves the hook's return data zero (`hv_exc_proxy` returns with `hook.data` zeroed, hv_vm.c:1058-1075), and the guest gets 0 for the read.

INFERENCE: SPTM panics on a bad or timed-out read from the SEP mailbox or dockchannel UART (it logs through dockchannel early). Check B.1's ELR to confirm the site.

### B.3 Not the cause (checked)

- IABORT is not handled in C (hv_exc.c:680 only DABORT_LOWER), so a stage-2 fault on an instruction fetch would go to the shell as IABORT with the real PC. Yours has PC=0x200 because of `_lower`.
- Traced pages are never handed to guest vectors by C code; the only reflector is Python `_lower` (called from `handle_brk` and the `lower()` shell helper, 1185).

## C. Correct way to trace a range the guest already mapped

FACT: there is no guest-side re-walk and no "remap" helper to call. Stage 2 is the only thing that matters, and the Python tracer API is:
- `hv.trace_range(irange(addr, size), mode)` or `hv.add_tracer(...)` (__init__.py:313-346) then `hv.pt_update()` (348-419). The shell does this implicitly: `handle_exception` always calls `pt_update()` after the shell returns (line 1058), so `hv.trace_range(...)` followed by `hv.cont()` is the supported flow.
- Low level: `hv.unmap`, `hv.map_hw`, `hv.map_sw`, `hv.map_hook(ipa, size, read=, write=)` (209-256, direct `p.hv_map`, no tracer bookkeeping, so a later `pt_update` of an overlapping zone can overwrite it unless a RESERVED tracer covers it).
- Inspect: `hv.p.hv_pt_walk(ipa)` (src/proxy.c:517) and `hv.p.hv_translate(va, s1, write)`. Hook PTE type is bits 52:50 (SYNC/HOOK/RW hook = 4<<50, trace bits 63:61).
- TLB: `pt_update` ends with `self.u.inst(0xd50c83df)` = `tlbi vmalls12e1is` at EL2 (default `exec_modes[None]` is `proxy.call` at EL2, proxyutils.py:109). The C helpers use `dsb ishst; tlbi vmalls12e1is; dsb ish; isb` (hv_vm.c:419-423, hv_cpu_power.c:135-140). The Python version has no DSB around the TLBI. Add one if you suspect stale TLB entries on other cores.

How the AMCC hook works: it is not a re-walk. `load_macos_sptm` calls `add_tracer(irange(addr,4), "SPTM AMCC", HOOK, read=..., write=...)` for each AMCC register before start (2197-2200). The first `pt_update` in `start()` maps them as 4-byte L4 hook entries, before the guest runs. Nothing is remapped later. SPTM's accesses go through `handle_vm_hook_mapped` HOOK mode with Python read/write returning values.

## D. Recommendations

### D.1 Diagnose before changing anything (needs only a shell on the existing failure)

1. In the IABORT shell, read `ELR_EL12`/`ESR_EL12` (B.1). If EC=0x3c, the "first-instruction fault" is an SPTM BRK.
2. Preceding console lines to look for: `HV: load not emulated`, `HV: store not emulated`, `HV: Exception during read/write`, `Unmapped IPA`, `Python exception while handling guest exception`. Any of these means the traced access failed first.
3. `hv.mmio_maps[addr]` for the zone. The highest `TraceMode` wins (types.py:48-56: OFF<BYPASS<ASYNC<UNBUF<WSYNC<SYNC<HOOK<RESERVED). A leftover RESERVED/HOOK from another module hides your SYNC silently. `pt_update` logs the winner as `PT[...] -> SYNC.RW PrintTracer`.
4. `hv.p.hv_pt_walk(addr)` for the DCP mailbox page after the live install: expect a non-zero invalid PTE with type field 4 (RW hook) and bits 63:62 as appropriate; a valid PTE (bit 0 set) means the zone was not remapped.

### D.2 Smallest Python-only way to trace from guest start without breaking SPTM

Make the trace non-intrusive for the pre-SPRR phase: install the PrintTracer ranges lazily from a callback that SPTM itself triggers late in its init. SPTM reads the AMCC CTRR registers during init. `handle_exception` runs `pt_update()` after every handled event (line 1058), so a tracer added from inside the AMCC HOOK callback is applied while the guest is stopped on that access:

    # in the -m module
    done = False
    orig_read = hv.sptm_amcc.read          # set in load_macos_sptm (2197)
    def _read(addr, width=None):
        global done
        if not done:
            done = True
            hv.trace_range(irange(sep_mbox, 0x4000), TraceMode.ASYNC)
            hv.trace_range(irange(dcp_mbox, 0x4000), TraceMode.ASYNC)
        return orig_read(addr, width)
    for a in hv.sptm_amcc.registers:       # re-register with the wrapper
        hv.add_tracer(irange(a, 4), "SPTM AMCC", TraceMode.HOOK, read=_read,
                      write=hv.sptm_amcc.write)

(`hv.sptm_amcc.read` must keep its `(addr, width=None)` signature; the HOOK path calls `read(addr, 8<<width, **kwargs)`.) Use ASYNC first: no per-access UART round trip, so no timeout risk. Use `TraceMode.WSYNC` only if you need ordering of writes.

If the BRK is a timeout or a multi-register access, also keep SPTM out of the loop by tracing only after it has finished its device phase (the AMCC trigger above is a late point, once SPTM has read the CTRR state).

### D.3 Live install that actually takes effect

Use the supported flow, with verification, from the shell: `interrupt`, then `hv.trace_range(irange(0x48ae08000, 0x4000), TraceMode.SYNC)`, `hv.pt_update()` (explicit, so you can check the `PT[...]` log line), `hv.p.hv_pt_walk(0x48ae08000)` (expect an invalid PTE with type 4), `hv.u.inst(0xd50c83df)` followed by a DSB (`hv.u.inst(0xd5033b9f)` is `dsb ish`), then `hv.cont()`. If `hv_pt_walk` shows the hook but still no events, the guest is not touching that IPA through this stage-2 table (e.g. the address is not the CPU-visible window). Cross-check `hv.device_addr_tbl.lookup(addr)` and the ADT `reg` translation: `get_reg` returns the translated physical address, `to_bus_addr()` the bus one.

### D.4 C change, only if D.1 proves it is needed

`handle_brk` in Python reflecting every non-0x4242 BRK to a guest that has no vectors turns an SPTM panic into an IABORT at 0x200 and hides the real BRK. A one-line Python fix is enough: in `handle_brk` (__init__.py:907-914), if `self.u.mrs(VBAR_EL12) == 0` (no guest vectors yet), log the BRK context (ELR, ESR ISS, x0) and return False so the shell opens at the real PC instead of `_lower()`. No C change in src/ is required for D.2 or D.3.

## E. TraceMode.ASYNC delivery: ways events can be dropped without any error

All FACT from code.
- `handle_mmiotrace` (__init__.py:494-524) re-reads `self.mmio_maps[evt.addr]` at event time, not at emission time. If the tracer was removed or changed while the event was in flight (`del_tracer`, `trace_range(OFF)`), or if the zone's entry list is empty, the event is dropped silently.
- `mode == TraceMode.OFF` entries are skipped with `continue` and no message (line 515).
- If the highest-priority map is above WSYNC, or the event is a write and the mode is above UNBUF, it prints `ERROR: mmiotrace event but expected <mode> mapping` and skips (line 513). Visible only on the console.
- It only calls `read`/`write` if the tracer registered one. `trace_range(read=False)` sets read None, so no read events; C also does not emit them because `SPTE_TRACE_READ` is only set when `need_read` (pt_update 395-399).
- Events are generated only when the PTE carries `SPTE_TRACE_READ/WRITE` (hv_vm.c:1000, 1082). Pages left HW (OFF), or accesses that hit the hook path with a hook that overrides the event (HOOK mode, `first += 1` in `handle_vm_hook_mapped`), produce no event.
- ASYNC events are queued with `iodev_queue`/`iodev_write` (src/uartproxy.c:298-318) and are not individually flushed unless `sync` (UNBUF) is set (hv_vm.c:878-881). If the guest/CPU dies or the HV exits soon after, the last events may never reach the host.
- Shell state: `shellwrap` (421-459) catches any exception from the tracer and enters an interactive "debug shell" in the event thread (the `skip`/`cont` flow). That blocks event handling for all later events until you leave it.
- Multi-word accesses (width > 3) are split into 8-byte events marked MULTI (hv_vm.c:860-883); filtering by size will miss them.
- A SPTE_PROXY_HOOK_R/W page (map_hook with read only or write only) produces events only for the direction it hooks; the other direction goes through `SPTE_MAP` with no trace flag unless `pt_update` set it.

## Key line references

- src/hv/hv.c:34, 135-139, 183, 239-253 (mode flag, VBAR_EL12=0, C hooks installed in hv_start after Python's pt_update)
- src/hv/hv_vm.c:118-143, 254-287, 309-371, 403-424, 473-545, 860-883, 981-1130, 1192-1241, 1243-1441
- src/hv/hv_exc.c:632-748 (no IABORT/BRK handling in C)
- src/hv/hv_sprr.c:296-319, 331-349, 628-740, 863-880, 925-952, 1859-1867
- proxyclient/m1n1/hv/__init__.py:209-256, 313-419, 494-633, 907-956, 998-1065, 1151-1182, 1419-1521, 1532-1647, 1778-1796, 2012-2016, 2190-2200, 2314-2364
- proxyclient/tools/run_guest.py:97, 154, 165, 178, 180 (init, load, -m scripts, optional shell, start)
