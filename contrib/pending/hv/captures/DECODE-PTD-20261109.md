# PMP PTD aperture decode: macOS 27.3 boot on M5 Pro (T6050 / J716s), single core, no disk

Input: `captures/trace-cpus1-pmp-ptd-20261109-0153.log` (150,341 lines; 149,249 MMIO lines = 126,847 `pmp.ptd` + 22,402 `pmp.mbox`; ASYNC trace, groups `pmp,ptd`; window `pmp.ptd` = 0x284240000+0x14000, so offset 0x10000+ is the update aperture `pmp0 reg[3]` 0x284250000). Offline only. Script: `captures/ptd-decode.py` (`python3 -I ptd-decode.py LOG`) reproduces sections 1 and 2; mailbox side from `mbox-decode.py LOG --dev pmp` (7,315 messages here vs 7,047 in the earlier capture).

Labels: **[F]** fact read from the log, **[I]** inference, **[ADT]** from the J716s runtime ADT (`adt-runtime-j716s.bin`, `ptd-range`, `soc-device`, `dvfs-domain`, `mc_*_ptd_count`). Entry mapping rule (m1n1 `trace_pmp.py`, pmp-report.c, confirmed below): read offset = idx*16 (16-byte entry = value qword + stamp qword), write offset = 0x10000 + idx*8 (value only).

Time base. Every 16-byte entry's second qword is a **stamp** = `(counter << 10) | flags`. **[I]** counter = 24 MHz (CNTFRQ). Evidence: AP-written request stamps are 6.4 us apart for back-to-back stores; a periodic writer ticks at 97.8 ms (so a round 100 ms); the end-of-log estimate (about 380 s after counter zero) is consistent with the file mtimes (log closed about 6.5 min after the run started). All "seconds" below are stamp/24e6 and are PMP/PTD hardware time, so they are real time, but tracing slows the guest, so they say how long this *traced* boot took, not a native boot.

## 0. Summary

- **[F]** There is no periodic sweep of the report region. The PTD traffic is five things: (A) a one-shot memory-controller (MC) command handshake with a spin-wait of 6,425 iterations (115,650 of 126,847 accesses); (B) 36 read-modify-write updates of the device power request word plus 5 ack-wait polls; (C) 119 writes of SOC-DEV-DVFS entry 0 (level ramps); (D) a SMC/PPM/CLPC channel: 4 reads once, 5 writes once, then 3,199 ticks of 3 writes about every 98 ms; (E) one-shot reads (fast die, LTS-VOLT-CAP).
- **[F]** All five pmp-report.c T6041 offsets are exercised exactly as the table says: status 0x10, tgt_read 0x1e00, tgt_write 0x10f00 (35 of 35 read-backs equal the preceding store), actual 0x1e80, fast_die 0x2580 (read once, value 0).
- **[F]** macOS writes 20 request words **before PMP-STATUS ever reads non-zero** (status 0 for 465 reads, 1 from 78.178 s). The PTD latches them and the PMP acks the net state about 0.2 ms after it starts. This contradicts "macOS writes no request before the PMP starts" in the `apple_pmp_offsets_t6041` comment, for T6050 at least.
- **[F]** Request bit N is soc-device id N+1 and equals PMGR `id1 - 1`: bits 12, 15, 17, 19-22, 23, 25-29, 31-33, 35, 36 were all set, covering `id1` 13..37. A `device_id > 15` filter would drop all but the three CPU-cluster managers (answers the open point in `PMP-J716S.md`).
- **[F]** No DRAM or fabric floor is requested through the PTD in this window: request bits 0-11 (DCS, AMCC, SOC-NI0-9) never set, SOC-DEV-BWR (idx 0x220) and SOC-DEV-PKT untouched. The only performance-level write is SOC-DEV-DVFS entry 0 (0x1f0), levels 0..14, 119 writes; its domain is unresolved.
- **[F]** PMP bring-up order: AP finishes serving the PMP (last ep 0x20 message is SET_VAL index 0x1f answered with size 0x6e8) -> PMP publishes MC quota entries 27 trace lines later (77.2120 s) -> 120 REPORT messages -> PMP-STATUS = 1 (78.1783 s) -> MC command ack (entry 8 = 2) 0.4 ms later -> the AP's spin loop ends. First mailbox message to status = 1 took about 11.7 s traced.
- **[F]** The "17 AP messages/s, 2.8 s per 96-message period" assumption of the earlier decode is not supported: PTD stamps anchor 3,646 AP messages in about 11.7 s (about 310 AP msg/s traced) and one 96-message period coincides with one 100 ms CLPC tick.
- **[F]** New message types after PMP start: ep 0x20 type 0x36 (PMP, index 0x347..0x371) answered by AP type 0x37 value 8, 13 pairs; ep 2 LOG.

## 1. Access pattern

### 1.1 What is touched

All 126,847 PTD accesses are 64-bit (`R.8`/`W.8`), none other. Four guest PCs (KASLR-slid; same slide as the mailbox PCs `0x...cb351f8/5218/56fc`):

| PC | role | accesses |
|---|---|---|
| `0xfffffe003d7dc4dc` | generic PTD entry read: two 8-byte loads (value, stamp) | 1,438 R |
| `0xfffffe003d7a71c0` | generic PTD update store (one qword to 0x10000+8*idx) | 9,757 W |
| `0xfffffe003db9ede8` | MC command writer (same function as next, +0x48) | 2 W |
| `0xfffffe003db9ee30` | MC response reader (9 entries per iteration) | 115,650 R |

Per offset (entry names from ADT `ptd-range`; `[k]` = entry k of the range):

| offset | PTD entry | known in pmp-report.c | count | values |
|---|---|---|---|---|
| R 0x10 / 0x18 | PMP-STATUS[0] | `status` | 573 each | 0 (465x), then 1 (108x) from line 140432; stamp 0x1bf56fbbc02 = 78.1783 s |
| R 0x1e00 / 0x1e08 | SOC-DEV-PS-REQ[0] | `tgt_read` | 36 each | request word, 25 distinct, always equals last store |
| W 0x10f00 | SOC-DEV-PS-REQ[0] update | `tgt_write` | 36 | see 2.1 |
| R 0x1e80 / 0x1e88 | SOC-DEV-PS-ACK[0] | `actual` | 103 each | 5 distinct, last 0x1b8c009000; only polled after PMP start (2.1) |
| R 0x2580 / 0x2588 | FAST-DIE-CE[0] | `fast_die` | 1 each | 0x0 / 0x0 (line 2548, before PMP start); never read again |
| R 0x25a0..0x25d8 | SMC-TO-PPM[0..3] of 7 | **no** | 1 each | see 1.3 |
| R 0x2610..0x2688, 0x2690/98 | MC-CTRL-TO-DRV[0..8] (all 9) | **no** | 6,425 each | see 1.3 |
| R 0x26a0 / 0x26a8 | LTS-VOLT-CAP[0] | **no** | 2 each | 0x0 (line 2550), 0x1e1 (line 140477, stamp 78.1835 s) |
| W 0x10f80 | SOC-DEV-DVFS[0] update (idx 0x1f0 of 0x30) | **no** (T6041 has no `update`/`dvfs_*`) | 119 | 0x2000000000000000 + level, 13 distinct (levels 0..11, 14) |
| W 0x11220 / 0x11228 | MC-DRV-TO-CTRL[8] / [9] update (of 10) | **no** | 1 each | 0x1002 / 0x600000 |
| W 0x11380..0x113a0 | PPM-TO-SMC[0..4] update (all 5) | **no** | 1 each | 0x2111100000000, 0, 0, 0, 0 |
| W 0x113a8 / b0 / b8 | CLPC-TO-SMC[0..2] update (of 5) | **no** | 3,199 each | two float32 / 0 / 0x43ab800000000000 (floats 0.0, 343.0) |

Not touched at all: DVFS-STATE, PMPTOOL, PMS-*-PKT, SOC-DEV-PKT, SOC-DEV-BWR, DVFS-DIE-TO-DIE, FAST-DIE-TO-SMC, GFX-TO-SMC, MC-CTRL-TO-SMC, ANE-TO-SMC, LTS-TO-GFX, PMP-TO-GFX, PMU-TO-GFX, PMS-VIRT-CNTR; SOC-DEV-PS-REQ/ACK entries 1-7; fast-die entry 1.

Of 36 request stores, 36 are preceded by a read of the current request (R 0x1e00/0x1e08: a read-modify-write) and 19 of those by a status read (R 0x10/0x18) in front. Pattern: `[R status] R req  W req`, then the status is read again after the store.

### 1.2 Order of one iteration of each loop

- **MC spin** (PC ...ee30), 18 reads: entry 8 first (0x2690 ack word, 0x2698 stamp), then entries 0..7 (0x2610,0x2618 ... 0x2680,0x2688). 6,425 iterations, lines 1144 to 140437; the loop exits on the iteration whose first read (0x2690) returns 0x2. Other contexts preempt it at arbitrary points (status read pairs appear mid-iteration; 454 zero-status reads in the mailbox phase, about one per 13 iterations).
- **CLPC tick** (PC ...a71c0): W 0x113a8 (floats), W 0x113b0 (0), W 0x113b8 (0x43ab800000000000). Strictly in that order, 3 lines apart; no reads.
- **PPM handshake** (once, lines 4282-4294): read SMC-TO-PPM entries 0..3, then write PPM-TO-SMC entry 4, 3, 2, 1, 0 (reverse order, entry 0 = header last).
- **MC command** (once, lines 1142-1143): W 0x11228 (argument 0x600000), then W 0x11220 (command 0x1002), then the spin starts at line 1144.

### 1.3 Values and evolution

- **MC-CTRL-TO-DRV** (ADT `mc_quota_rsp_ptd_count` = 8, `mc_cmd_ack_ptd_count` = 1: entries 0-7 quota responses, entry 8 command ack). All zero for the first 6,043 iterations. First published at 77.2120-77.2122 s (flags 2 on first read, 0 afterwards): e0 = 0x80030, e5 = 0x4000000000030, e6 = 0x4000400040004, e7 = 0x40004, e1-e4 = 0, e8 = 0 (still). Re-published at 78.17868-78.17888 s (flags 3) with identical values, and e8 = 0x2 at 78.17897 s. The stamps of e0..e7 are about 1.8 us apart (the PMP writes the block in order).
- **SMC-TO-PPM** (single read, line 4282): e0 = 0x1111000000000, e1 = 0xc06000143480000, e2 = 0xc100001437f0000, e3 = 0; stamps 65.5528-65.5529 s, flags 3. The writer published them 0.57 s before the AP's first PTD access (the SMC runs before macOS).
- **PPM-TO-SMC** reply (written on the next trace lines after the read): e0 = 0x2111100000000, e1-e4 = 0.
- **CLPC-TO-SMC[0]**: two float32 per store. [F] low float: 0.027, 0.209, 0.375, 0.524, 0.657, ... 1.50 at the peak, then settles at 0.457 +/- 0.001; high float: 0.336 -> 1.94 peak -> noisy 0.44-0.47. [I] a filtered load/power estimate plus a raw companion (a first-order step response, then steady); units unknown. Entry 1 always 0; entry 2 always {0.0f, 343.0f}.
- **Stamp flags** (low 10 bits of every stamp): [F] bit 1 is set on the first read after an update by the other side and clear afterwards (MC entries 8/8, status, ack); for AP-written request words it is set while the PMP has not yet consumed the store (readback right after a store: 0x2, later reads: 0x0, readback 2 lines after the JPEG store at line 140468: still 0x2) and clear once the PMP is running and has processed it. [F] bit 0 is set on entries published by a running remote agent (SMC-TO-PPM, ack word, MC entries after 78.178 s) and clear on AP-written words. [I] bit 1 = "update pending/unconsumed", bit 0 = "published by a running agent".
- **LTS-VOLT-CAP**: 0 before PMP start, 0x1e1 (481) at 78.1835 s, 5 ms after status = 1. Unit unknown.

## 2. Writes

### 2.1 Device power request word (0x10f00, 36 stores; bit N = soc-device id N+1 = PMGR `id1 - 1`)

Stamp = hardware time of the store (read-back equals the value 35/35; first read-back carries the store's stamp). Context columns: PMP-STATUS at that time and the nearest mailbox message.

| # | line | stamp (s) | word | change | status | mailbox |
|---|---|---|---|---|---|---|
| 1 | 1064 | 66.123174 | 0x80000000 | +ATC0 | 0 | before first message |
| 2 | 1069 | 66.123181 | 0x180000000 | +ATC1 | 0 | |
| 3 | 1074 | 66.123187 | 0x380000000 | +ATC2 | 0 | |
| 4-7 | 1079-1094 | .123193-.123212 | 0x380080000 -> 0x380780000 | +DISPEXT0, +DISPEXT2, +DISPEXT3, +DISPEXT1 | 0 | |
| 8 | 1099 | 66.123218 | 0x1380780000 | +ANS | 0 | |
| 9 | 1102 | 66.123285 | 0x1380781000 | +MACC0 | 0 | |
| 10 | 1139 | 66.207628 | 0x1380781000 | rewrite, same value (after six PMGR PS power-up writes, 84 ms) | 0 | |
| 11-13 | 2734, 2757, 2888 | 66.3131, .3137, .3169 | 0x1380789000, 0x1b80789000, 0x1b807a9000 | +AGX, +AUSS, +ISP | 0 | |
| 14-20 | 15780..51467 | 66.585-67.615 | toggles of AUSS (14,15,16,19) and ISP (17,18,20) | | 0 | between REPORT pairs |
| 21-32 | 140436..140586 | 78.1785-78.2261 | pulses: +SCODEC -SCODEC, +JPEG -JPEG, +AVD, +MSR0, +AVE0 -AVE0, +JPEG -JPEG, -AVD, +MSR1 | | 1 | after last ep 0x20 message |
| 33-36 | 142080, 142151, 142299, 142394 | 126.3547, .3814, .5790, ~126.62 | 0x1b8c589000 -> 0x1b8c009000 | -DISPEXT2, -DISPEXT3, -DISPEXT0, -DISPEXT1 | 1 | none |

- **[F]** Final word 0x1b8c009000 = MACC0, AGX, MSR0, MSR1, ATC0, ATC1, ATC2, AUSS, ANS. Never set: DCS, AMCC, SOC-NI0-9, MACC1, PACC, ANE, DISPINT, AVE1, ATC3, PRORES, SCODEC (after its pulse).
- **[I]** MACC0 only, not MACC1/PACC: only the boot cluster is up with `cpus=1`.
- **[F]** Bit-to-device check (13 devices): ATC0-2 (PMGR id1 32-34), DISPEXT0-3 (20-23), ANS 37, MACC0 = MCPM0 13, AGX = GFX 16, AUSS 36, ISP 18, SCODEC 30, JPEG 29, AVD 26, MSR0/1 27/28, AVE0 24. ATC0_COMMON PMGR power-up (`notify_pmp`) follows request #9, request #10 repeats the word after it.
- **Meaning [F]:** these are level requests (a bitmap of wanted devices), not events. A store is accepted with PMP-STATUS 0, and the later ack equals the last store: first ack read (line 142083) = 0x1b8c789000 = word #32, stamp 78.2263 s, 0.196 ms after word #32's stamp 78.2261 s. Pre-start toggles (#14-#20) leave no trace in the ack.
- **Ack polling [F]:** macOS polls ack only after releasing a bit once the PMP runs (#33-#36: 16, 33, 21, 29 poll iterations, 103 ack reads in total, each iteration status + ack = 4 reads) and never after a power-up request. Ack latency = ack stamp - request stamp: 196, 106, 217, 172 us (#32-#35). The ack does not follow stores #1-#31 in the log (no ack read).
- **[F]** Read-back reflects every store immediately (35/35), including with PMP-STATUS = 0.

### 2.2 DVFS entry 0 (0x10f80, 119 stores; word = 0x2000000000000000 | level)

Bit 61 is the valid bit, the same as `PMP_DVFS_VALID` in pmp-report.c (T8140 layout); levels 0..11 and 14 appear (maximum 14, within the driver's 0x1f field).
- Lines 3072-6444, before any mailbox message: ramp 1,2,3,4,5,6,7,8,9,10,11,14 (12 stores, about 6 ms apart traced), then no more until the mailbox phase.
- Mailbox phase (lines 31220-120173): 15 cycles `0 -> 8 -> (9) -> 14` (one `0 -> 8 -> 5 -> 6 -> 14`), about 0.1-2 s apart traced (line spacing x ~118 us).
- After PMP start: `0,14,0,11,0,7,0,5,0,3,0,3,0,1,0` (lines 140587-140607, 0.5 s window, a decay), then bursts `1,0,1`, `1,0,1,2,3,4,0,3,0,3,0,3,0,3,0,2,0,1,0` (line 144594, about 194 s [I]) and `1,0,1,2,3,4,0,4,0,2,0,2,0,1,0` (line 148303, about 315 s [I]): up to 4, back to 1.
- **[I, weak]** a load-tracking performance-level request: it rises under CPU load (spin plus mailbox service) and decays when the AP idles. Which of the ADT `dvfs-domain` entries it is (DCS 0..7, AFR 0..13, SOC 0..4, DISP_INT, DISP_EXT, from the `dvfs-domain` words 7/13/4/4/4) is **not resolved**; levels 8, 9, 14 exceed DCS and SOC ranges, so DCS/SOC are unlikely if the ADT counts are max levels.

### 2.3 Other writes

- **MC command (lines 1142-1143)**: entry 9 = 0x600000 then entry 8 = 0x1002 (ADT: 2 cmd words, 8 quota requests; the 8 quota-request entries 0-7 are never written). **[F]** acked only when the PMP starts (entry 8 of the response = 0x2, 78.179 s). Semantics of 0x1002 / 0x600000 unknown **[I: command opcode, argument]**; 0x600000 is a round 6 MiB figure.
- **PPM-TO-SMC** (5 stores, once): reply to the SMC-TO-PPM block, no later writes.
- **CLPC-TO-SMC** (3 stores per tick): not acknowledged by any visible read.

## 3. Timing and frequency

Anchors (stamp time, trace line, mailbox message index at that line):

| event | time (s) | line | msg # |
|---|---|---|---|
| first AP request store | 66.1232 | 1064 | 0 (before) |
| request #14 | 66.5854 | 15780 | 477 |
| request #20 | 67.6153 | 51467 | 887 |
| PMP publishes MC quota | 77.2120 | 133115 | 7167 |
| PMP-STATUS = 1 | 78.1783 | ~140430 | 7287 |
| request #32 | 78.2261 | 140586 | after |
| request #33 | 126.3547 | 142080 | after |

- **HELLO** (line 10465) lies between request #13 (66.3169 s) and #14 (66.5854 s): about 66.47 s by linear interpolation in lines [I].
- **Mailbox rate [F, traced]:** msgs 477-887: 398 msg/s (94% REPORT); msgs 887-7167: 6,281 msgs in 9.597 s = 654 msg/s = 327 AP msg/s; msgs 7167-7287: 119 msgs in 0.966 s = 123 msg/s. The earlier estimate of 17 AP msg/s (2.8 s per period) is off by about 20x. The steady-state 96-message period (idx 4000-5900 here) holds one CLPC tick each (about 100 ms), so **[F/I] period of 96 messages (48 AP) about 0.10-0.15 s traced**, 30-45 MC spin iterations per period.
- **CLPC tick [F]:** 492 ticks between requests #32 and #33 = 48.129 s -> 97.8 ms per tick = 10.2 Hz; pre-start ticks 90-121 ms apart (the busy single core delays them). 3,199 ticks in total; 2,598 after the last stamped event (126.62 s), so the log ends at about 380 s counter time [I] (about 5 min of idle CLPC ticks; the guest has no disk).
- **MC spin [F]:** 6,425 iterations in 12.05 s = 1.88 ms per iteration traced (355/s in the mailbox phase). It is a busy-wait, not a paced poll: its rate is the cost of 18 traced MMIO reads, a native loop is far faster. There is **no design period** for it.
- **Status polling:** 573 reads (11 before the mailbox, 458 during, 104 after); not periodic: they come from other contexts preempting the spin and from the request routine.
- **Ack-wait loops:** 16-33 iterations of 4 reads, 0.1-0.2 ms.
- Assumptions: stamp counter is 24 MHz (see top); tracing overhead is about 20-120 us per logged access and varies, so line-to-time maps are only valid between stamped anchors; rates are upper bounds for a native boot except timer-driven ones (CLPC tick 97.8 ms is native-speed, the tail of the log runs untraced-fast).

## 4. Relation to the mailbox

- **[F]** No PTD access follows a particular message type. The 36 request stores, 119 DVFS stores and the MC/SMC accesses sit at arbitrary message boundaries. Requests #14-#20 are all between REPORT messages, but msgs 477-887 are 94% REPORT (386 of 410), so this is composition, not coupling. DVFS stores fall next to MALLOC/ADVERTISE/REPORT in proportion to their frequency. Nothing aligns with SET_VAL or IOReport REPORT.
- **[F]** Hard order: the **last SET_VAL (index 0x1f, AP answers size 0x6e8, the `controller` property length)** at line 133088 -> PMP stamps MC-CTRL-TO-DRV at 77.2120 s (27 lines later) -> 120 REPORT messages (60 pairs, 0.966 s) -> PMP-STATUS = 1 at 78.1783 s -> 0.4-0.7 ms later the MC block is re-published and the ack word = 2 -> spin ends, request #21 (SCODEC) at 78.1785 s. The first status = 1 read (line 140432) is 3 lines after the AP's last REPORT reply (msg 7286), but the status stamp is earlier than any message the AP sent after it; **[I]** the PMP sets status itself after about 1 s once its tables are loaded.
- **[F]** After start: ep 2 LOG (msg 7287/7288), then ep 0x20 type 0x36 (PMP, index 0x347, 0x34a, 0x34d, 0x351, 0x354, 0x357, 0x35b, 0x35e, 0x361, 0x36b, 0x36e, 0x371, 0x365) each answered by type 0x37 with value 8: 13 pairs, not in m1n1 `pmp_init.py` (types 0x30-0x35 only). [I] a get/set on the same index space as SET_VAL, 8-byte values. Unresolved.
- The PTD requests do **not** wait for the mailbox: the first 13 requests, the MC command and the DVFS ramp all precede message 0. PTD readiness (status) is the only thing gated by the mailbox service.

## 5. Answer for omacom/linux-aurora #293

**Offsets macOS reads (T6050, macOS 27.3, single core, no disk, 380 s):** PMP-STATUS 0x10/0x18 (573x, as a readiness check around every request update), SOC-DEV-PS-REQ 0x1e00/0x1e08 (36x, as the read half of each update), SOC-DEV-PS-ACK 0x1e80/0x1e88 (103x, only waiting for a *release* after the PMP runs, 4 ack waits), fast die 0x2580/0x2588 (once, before the PMP runs, value 0, never again), plus MC-CTRL-TO-DRV 0x2610-0x2698 (6,425x, one-time wait for the MC command ack), SMC-TO-PPM 0x25a0-0x25d8 (once), LTS-VOLT-CAP 0x26a0 (twice). **How often:** nothing is polled periodically except the busy-wait for the MC ack (until 78.18 s) and the ~10 Hz CLPC store; the report entries are read only on demand.

**What it writes:** SOC-DEV-PS-REQ update 0x10f00 (36x, read-modify-write of the device bitmap, no write sequence needed before the PMP runs), SOC-DEV-DVFS entry 0 at 0x10f80 (119x, `0x2000000000000000 | level`), the MC command at 0x11220/0x11228 (once), PPM-TO-SMC 0x11380-0x113a0 (once), CLPC-TO-SMC 0x113a8-0x113b8 (3,199x).

**Implications for `pmp-report.c` T6050 table:**
- **Confirmed** (all five, with `idx*16` read and `0x10000 + idx*8` write): `status` 0x10, `tgt_read` 0x1e00, `tgt_write` 0x10f00, `actual` 0x1e80, `fast_die` 0x2580. `fast_die_lanes` = 3 (ADT `fast-die-ctrl-ce-map`) is not exercised: macOS read the word once while it was 0.
- **`running_any`:** status is only ever 0 or 1 here, so it neither confirms nor refutes "any bit".
- **`defer_requests` rationale is wrong for T6050**: macOS writes 20 requests with status 0 and they are honoured at start. Deferring is a safe choice, not macOS behaviour; the PMP acks the net state about 0.2 ms after it starts.
- **Missing fields (T6041 entry has none):** `update = 0x10000`, `dvfs_first = 0x1f0`, `dvfs_count = 0x30` (SOC-DEV-DVFS, same valid bit 61 as T8140). macOS uses only entry 0x1f0. Also unknown to the driver: the MC command pair (0x11220 = 0x1002, 0x11228 = 0x600000) and its ack (0x2690 = 2); SMC-TO-PPM / PPM-TO-SMC / CLPC-TO-SMC (the CLPC to SMC float feed); LTS-VOLT-CAP (0x1e1); stamp flag semantics (bit 1 = pending).
- **`id1 - 1` is the request bit**, confirmed for 13 devices, id1 up to 37. Do not gate on `device_id > 15`.
- If Linux ever starts the PMP itself on T6050: the AP first writes requests (ATC, DISPEXT, ANS, MACC0), then the MC command pair, then serves the mailbox; the PMP signals ready only after about 1 s following the last property reply.

**For the Linux PMC floor work:** [F] nothing here shows macOS requesting DRAM or fabric floors through the PTD. Bits for DCS/AMCC/SOC-NI0-9 are never set; SOC-DEV-BWR (idx 0x220, 26 entries) and SOC-DEV-PKT are never touched. The only performance-level traffic is SOC-DEV-DVFS entry 0x1f0 (level ramps to 14 under load, decay at idle) and the one-shot MC quota command. [I] if entry 0x1f0 turns out to be the DCS/fabric domain, it would be the macOS analogue of a load-driven floor, but the level range (0..14) does not fit the ADT DCS range (0..7). The PMC voter/rail block (0x286...) was not traced, so this log is silent on direct voter writes.

## 6. Caveats and next capture

- Boot is single-core, no disk, ends idle (CLPC ticks only); no workload, no display change beyond the DISPEXT release, no GPU/ANE/video activity: DVFS and request behaviour under load is not covered.
- Stamp unit (24 MHz) is inferred; a single read of `CNTVCT_EL0` next to a stamp in a future trace would pin it.
- To resolve what entry 0x1f0 is and whether the PMP honours the pre-start writes: add the PMC window 0x286000000 to the trace groups, and (when hardware is available) read back PTD entries 0x1f0..0x21f (offsets 0x1f00-0x21ff) and SOC-DEV-BWR 0x2200-0x239f after a workload.
