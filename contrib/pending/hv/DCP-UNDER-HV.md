# DCP under the hv27 guest (macOS 27.3, J716s / T6050): read-only study (2026-11-08)

Legend: **FACT** = read in code/capture/ADT/kernelcache this session. **INFER** = reasoning from facts, not proven.
Nothing was run on hardware; the kernelcache (`~/Work/studio-artifacts/macos-27.3/derived/kc.macho`, symbols present)
was disassembled offline (llvm-mc), screenshots are `runs/shots/*.raw` from earlier runs.

## 0. Headline: the premise "DCP never answers" belongs to run 1 only, and run 1 was a guest panic

- **FACT** The two captures differ in one input: run 1 (`...0050.log`, run dir `20261108-194833`, started 19:48) vs run 2
  (`...0105-run2.log`, `20261108-200332`, started 20:03). Same m1n1 build, same guest files (RUN.txt sha256 identical), same ADT
  edits (diff of the non-mbox lines: only heap addresses). `proxyclient/m1n1/hv/sprr.py` was edited at 20:01:26 between them
  (uncommitted, `git diff`): `_H27_RAZWI_MSR/MRS` (sprr.py:341-364) turns `MSR/MRS S3_7_C15_C{11,13,15}_*` in guest text into
  nop / `mov Xd,xzr`.
- **FACT** Run 1 died in a guest kernel panic: screenshot `runs/shots/trace-cpus1.png` (19:54) reads `panic(cpu 0 caller
  0xfffffe003de1c8c8): Undefined kernel instruction: pc=0xfffffe003bdc03b0 instr=d51fff08 @sleh.c:1953`, kernel slide
  0x3215c000 (the slide the 0050 decode used). `d51fff08` = `MSR S3_7_C15_C15_0, X8`; pc - slide = 0xfffffe0009c643b0 =
  `clpc::cpu::CorePerfSampler::enable(bool,bool)` lambda +0x48 (AppleT6050CLPC), exactly what the razwi patch covers.
- **FACT** Run 2 (patched) has the full IOMFB conversation on ep 0x37 and ran ~10 minutes without a panic
  (`--dev dcp`: 16,569 DCP messages vs 76 in run 1; SMC 5,254 vs 233). Screenshot `cycle2.png` (20:09) shows XNU still booting
  (IOSA/scaler init, Centauri/N1 retry loop); `cycle5.png` (20:45, later run) likewise. No panic text in either.
- **INFER** Everything in `DECODE-20261109-0050.md` section 4 after L2371 ("polls +0x114 forever", "18 unanswered mgmt 0xf",
  "missing SET_SHMEM") is the panic flow of a dead guest, not IOMFB bring-up. The decode's own note that SEP/SMC also stop at
  L2371 fits (single CPU, panic).
- **Consequence**: no loader/ADT/doorbell fix is needed for "IOMFB answers". The remaining visible symptom (verbose text on the
  panel) has a simpler cause, see Q1/Q5.

## Q1. What the hv client and stage-2 do to the display/DCP

Client (`proxyclient/m1n1/hv/__init__.py`, driven by `tools/run_guest.py`):
- **FACT** `start()` (2342-2344): `p.fb_improve_logo()` then `p.fb_shutdown(True)`. m1n1 `fb_shutdown(restore_logo)` (src/fb.c:498)
  only clears m1n1's text console rows, restores the logo pixels and frees m1n1's private copy of the fb; it writes iBoot's
  framebuffer (CPU stores to `/vram` 0x10bd15f4000+0x72c4000), never the DCP or its DART. `Removing __OS_LOG` is the only
  DCP-node ADT edit.
- **FACT** `set_bootargs` (1745-1750): any `-v` in the boot-args sets `boot_args.video.display = 0` (text mode). The run used
  `-v debug=0x14e wdt=-1 cpus=1`, so the guest was *told* to keep the verbose console on the iBoot framebuffer.
  Panel showing XNU text is therefore expected with `-v` whether or not IOMFB works.
- **FACT** ADT edits relevant to display: `_remove_oslog()` (1812-1829) deletes `__OS_LOG` from `segment-names/ranges` of every
  nub incl. `iop-dcp-nub` and `iop-dcpext0..3-nub` (log lines "Removing __OS_LOG from iop-dcp-nub"); `setup_adt` (1678) product
  names + `defaults.serial_device`; USB-port node removal for the proxy port including `Removing display endpoint atc0 from
  display-crossbar0` (1717-1727) and `dpxbar/dpphy/dpin0/dpin1` of atc0 (internal panel is not behind atc0). Nothing touches
  `/arm-io/dcp`, `dart-dcp`, `disp0`, `/vram`, `/chosen` display keys, `/chosen/iboot-handoff`.
- **FACT** Never effective on this path: `dcp_shutdown`, `display_start_dcp`, `display_configure` are not reached; `display_shutdown` is reached (main.c:175) but is a no-op (see below).
  `hv_init()` (src/hv/hv.c:141-146) only runs `display_start_dcp()+display_shutdown(DCP_QUIESCED)` when `display_is_external`;
  the J716s internal panel is not external ("display: Display is internal").
- **FACT** Stage-2 in proxy mode (no payload): `main.c:172` `display_init()` -> "display: Display is already initialized
  (3456x2234)" (display.c:668) and returns 0 without `display_start_dcp`, so `has_dcp` stays false and `display_shutdown()`
  (display.c:674-677, main.c:175/204) is a no-op. `display_configure()` would refuse anyway on 27.x (display.c:406 "Unsupported
  firmware version ... skipping"). `fb_init/fb_display_logo` draw into the iBoot fb only.
- **FACT** kboot DCP hand-off (`dt_set_display`, kboot.c:2656, `dt_set_display_t6050` 2536, `dt_reserve_t6050_oslogs`) runs only in
  `kboot_prepare_dt()` (kboot.c:3555), reached from `payload.c:345`/proxy `kboot_prepare_dt`; the proxy loader never calls it.
  Confirmed by the stage-2 log: no `DCP: T6050:` or `FDT:` lines. The loader's T6050 code is DT-only anyway (guarded reads of
  ASC `CPU_CONTROL`, DART `PROTECT/TCR/TTBR`, DT edits); m1n1 never sends a mailbox message to this DCP, in any mode.
- **FACT (correction to the brief)** m1n1 does not do "SET_SHMEM and wait for INIT_COMPLETE" on T6050. Linux does (aurora fw-27
  drm/apple: "negotiating RTKit with the running DCP", `start_ios_gated`, `switch to normal mode succeeded`, stage C PASS in
  `contrib/validated/integration/RESULTS.md:1528`), adopting iBoot's live session; m1n1's own DCP client is for M1/M2 only.
- **FACT** Other stage-2 side effects on the DCP: `pmgr_init` "Cleaning up device states" only touches parents of already-active
  devices (pmgr.c:458-500). Nothing DCP-specific.

## Q2. What XNU expects from iBoot for the DCP (warm path) and whether stage-2 changed it

- **FACT (ADT, `studio-artifacts/adt-runtime-j716s.bin`, an earlier boot, mBoot-20457.41.2 tags)** `iop-dcp-nub`: `quiesced`
  (flag), `running=1`, `pre-loaded=1`, `idle-msg=1`, `coredump-enable=64`, `watchdog-enable`, `no-firmware-service`,
  `crashlog-region` 0x1000ac8c000+0x17000, `coredump-region` 0x10bd07cc000+0x8000. `iop-smc-nub` and `iop-ans-nub` carry the same
  `quiesced running pre-loaded`. `dcp` node: `iop,ascwrap-v6`, reg0 0x28ae00000+0x88000, reg1 0x28a850000+0x4000, 8 IRQs
  (1043..1050), `iommu-parent` mapper-dcp SID 23 + exclave SID 24 (`dart-dcp`: `dart,t8110`, l1-tt-23/24 pre-populated,
  `manual-availability`). `/chosen/iboot-handoff` = 0x10000000000+0x4000 (RAM base, matches the first DCP DVA 0x10000000000 given to
  kdebug). `/vram` = 0x10bd15f4000+0x72c4000 = boot_args.video.base.
  m1n1 does not write `quiesced` (grep); it is iBoot's flag. No `/chosen/display*` key beyond rotation/scale/corner-radius.
- **FACT** The warm path is exactly what both captures show for DCP *and* SMC (which works): first AP message `SET_IOP_PWR 0x220`
  (kext: `RTBuddyManagementEndpoint::wakeQuiesced`, 0x20 / 0x220), firmware answers `HELLO 12/12`, `EPMAP`, then `IOP_PWR_ACK 0x20`.
  DCP endpoints 0x20-0x25, 0x28-0x2d, 0x31, 0x37 (14) are all `STARTEP`ed by the AP in run 2; the 0x2x ones are AFK/EPIC-style
  (`...cafe` init words), 0x37 is the legacy `dcpep` call protocol.
- **INFER** Nothing the stage-2 loader did could have changed this state (Q1): no DCP register write, no DART write, no ADT
  property change on dcp/dart-dcp. `quiesced` ADT flag + `SET_IOP_PWR 0x220` + the DART l1 tables from the ADT are the whole
  contract and XNU consumed them (run 2).
- **FACT** run 2 order after `STARTEP 0x37`: AFK endpoints started one by one (L1260-1719, each: AP init word, DCP `...cafe`
  replies, AP shmem address, ring sizes), then **L2687 `SET_SHMEM dva=0x10000044000`** (msg0 `0x0100000440000040`), L2697
  **`INIT_COMPLETE`** (msg0 `0x0040227b39590101`; non-zero upper bits, M1-era m1n1 `DCPEp_InitComplete` has only TYPE), then the
  IOMFB call stream. In run 1 the AP had not reached SET_SHMEM when it panicked (it sent 0x37 and died).

## Q3. The 18 type-0xf messages

- **FACT** Every one is msg0 `0x00f0000000000000`, msg1/info `0x0000000000000000` (endpoint 0, mgmt type 15, no payload):
  L2372, 3142, 4580, 6733, 9622, 13242, 17560, 22578, 28372, 34923, 43166, 51154, 51525, 51898, 52270, 52643, 53015, 53387.
- **FACT (kernelcache)** The only place the constant `0xf << 52` is materialised in the whole kernelcache is
  `RTBuddy::_signalNmi(RTBuddyNmiType, OSString*, bool, bool)` (0xfffffe000b54c8e4, built as `0xf0000000000000`, sent on
  endpoint 0 via vfunc +0x8a8 when protocol version > 3). Siblings: `RTBuddy::signalNmiOnAPCrash`, `RTBuddyService::sendNMI`,
  `RTBuddyCoredump`. The real ping is type 3 (`_watchdogSendPing`: `0x30000000000000 | ts<<32 | seq`), power-nap is 0xa,
  SET_IOP_PWR 6, SET_AP_PWR 0xb. So 0xf is not an OSLog/ioreport/IOMFB setup message.
- **INFER** They are the AP panic flow signalling an NMI to the coredump-enabled IOP (the DCP nub has `coredump-enable=64`) and
  polling its mailbox for a response/crashlog (`RTBuddy::pollHardwareForMessage` is the poll loop in
  `_waitForRemoteStatePolling`; the DCP's EPMAP has no crashlog endpoint 1). The ~370-poll cadence = retry/timeout loop. The DCP
  popping them without answering is normal for an NMI request, not a protocol fault.
- Answer to "what would make firmware stop answering while still popping": in run 1 nothing was wrong with the firmware; the AP
  stopped sending anything but NMIs. For the general case: no crash/crashlog endpoint, a mgmt type it only logs, or the AP
  waiting for a different endpoint; none applies to run 2 where every call is acked.

## Q4. How upstream hv gets IOMFB working, and what differs here; doorbells

- **FACT** Upstream hv does nothing DCP-specific for an internal panel: the DCP keeps running under passthrough MMIO, the guest
  gets iBoot's `quiesced/running` DCP, wakes it by RTKit (`SET_IOP_PWR`), uses the iBoot DART tables. Same here (Q1/Q2).
- **FACT** Differences on this SoC, none blocking in run 2: `iop,ascwrap-v6` (guest `AppleA7IOP-ASCWrap-v6`), RTKit v12, cL4
  roottask firmware with a second DART SID (exclave-sid 24), 27.x IOMFB (method table renumbered, Linux has its own 27.3 table),
  `disp0,t605x`. `AppleASCWrapV6::_inbox` = one `stp` to reg0+0x8800, `_outbox` = `ldp` reg0+0x8830, status regs reg0+0x8110/0x8114,
  mailbox debug reg0+0x8180: all inside the traced +0x8000..+0xc000 page; no other register is touched to send a message.
- **FACT (disassembly of `AppleASCWrapV6`)** Other registers the wrapper uses, none needed for messaging: `_runCPU` reg0+0x44
  (bit 4 RUN), `_isIdle` reads, `_generateNMI`: if the nub has `nmi-ext-irq` it writes bit (n&7) at offset 0 of page (n>>3)*0x4000
  of the region named by `ext-irq-reg-index`, else writes reg0+0x1004=0x10 and reg0+0x1014=1; `_setIORVBAR/_isIORVBARLocked`
  use reg1 (`this+408`) at a stored offset (firmware (re)map, not used for `pre-loaded`). The DCP nub has neither
  `nmi-ext-irq` nor `ext-irq-reg-index`, so the ext-irq doorbell is not even mapped for the DCP. **No doorbell ring is required
  to deliver a mailbox message on v6.**
- **FACT** "doorbell: 1" and `msgbox-mailbox-num / msgbox-dashboard-num / msgbox-doorbell-num` are unrelated to the DCP ASC:
  `IOMFB: Enable low latency shared events mapping: %d, doorbell: %d` is printed by `IOMobileFramebufferAP::start`
  (0xfffffe000abe79fc) from tunables `iomfb_low_latency_shared_events_mapping/_doorbell` (default 1: GPU<->DCP shared-event
  signalling, `sharedEvent id=%d, dva=0x%llx, signal doorbell=0x%x`); the `msgbox-*` lines are the IOSA/MSR scaler driver
  (`Scaler[0]:[msgbox-mailbox-num]: 0 (default)`, visible in `cycle2.png`).
- **FACT** The ADT lists 8 DCP IRQs (two sets of four); the wrapper code only uses the one mailbox page. **INFER** the second set
  belongs to a second, untraced block (exclave side or a second mailbox); no evidence it matters, run 2 works without it traced.
- Pages worth tracing only if a future run misbehaves (offsets from reg0 = 0x48ae00000 unless noted; reg1 = 0x48a850000):
  `reg0+0x0000..0x0100` (CPU_CONTROL +0x44, status), `reg0+0x1000..0x1020` (NMI trigger 0x1004/0x1014), `reg0+0xc000..0x10000`
  (possible second mailbox), `reg1+0x0000..0x4000` (IORVBAR), plus `dart-dcp` writes (already in group `darts`). Not `disp0`.

## Q5. Recommendation (ranked)

1. **Commit/keep the `sprr.py` razwi patch** (hv27 fix for AppleT6050CLPC `S3_7_C15_C{11,13,15}`). It is the change that turned
   "DCP silent" into a working IOMFB session. Re-confirm with a fresh trace that the panic is gone (no `Undefined kernel
   instruction` on `cycle*.png`; `--dev dcp` shows SET_SHMEM/INIT_COMPLETE).
2. **If the goal is the panel leaving verbose text:** drop `-v` from the guest boot-args (hv sets `video.display=1`) and use the
   debug flags/serial separately. With `-v` the XNU console deliberately keeps painting the iBoot framebuffer, so text stays on
   screen even with a perfectly healthy IOMFB. Take `shot.sh` after the Centauri-loop point to compare.
3. **Judge IOMFB health from the mailbox, not the picture.** Run-2 health indicators (all FACT from the capture): INIT_COMPLETE,
   330 DCP->AP callbacks answered, 10 AP commands (A401-sized 0x10 call first, then 0x14/0x60 calls, 2 OOB) all acked, ~7.7k
   ASYNC (ctx 3, len 0x1c) notifications acked. INFER: those ASYNC are the firmware `pr_publish` flood Linux stage C also sees
   (`pr_publish: id: 119` every ~40 ms).
4. **To learn the 27.3 method tags macOS uses** (useful for the Linux table): pause the guest after INIT_COMPLETE and read the
   shared memory behind `SET_SHMEM dva=0x10000044000` (walk dart-dcp SID 23 from `l1-tt-23` 0x10bffea0000, same layout as m1n1
   `dcpep.py`: CMD 0x0, OOBCMD 0x8000, ASYNC 0x40000, OOBASYNC 0x48000, CB 0x60000, OOBCB 0x68000; each entry =
   reversed 4-char tag, in_len, out_len). The tags are in the buffers, not in the mailbox words.
5. Not worth doing: doorbell hunting, ADT edits to `/arm-io/dcp`, loader flags (`chosen.m5,t6050-display`), reinstating the
   kboot hand-off in proxy mode. Each addresses a cause the evidence rules out.
6. Housekeeping: `DECODE-20261109-0050.md` section 4/5 (and its copy under `m5pro-linux/contrib/pending/hv/captures/`) should say
   run 1 was the CLPC panic; the 0xf "mgmt type" should read "RTBuddy NMI".

## Open items (unknown, not blocking)
- Which exact AP function issues the NMI in run 1 (the panic path); only `_signalNmi` was located statically.
- Meaning of the non-zero payload in `INIT_COMPLETE 0x0040227b39590101` and of the 27.3 `dcpep` call tags (see Q5.4).
- Whether the AP-side `CALL ctx=0 ack=0 off=0x40` messages (19, nested AP calls on the CB buffer) are expected; run 2 shows the DCP acks them.
