# PMP mailbox decode: macOS 27.3 boot on M5 Pro (T6050 / J716s)

Input: `captures/trace-cpus1-pmp-apr-20261109-0118.log` (22,680 lines, ASYNC trace, no timestamps; the last line is a half-read pop, so the capture was cut). Script: `captures/mbox-decode.py` (`python3 -I mbox-decode.py LOG --dev pmp [--polls]`). Offline only.

Labels: **[F]** decoded fact (raw words quoted), **[I]** inference, **[ADT]** from the J716s runtime ADT (`studio-artifacts/adt-runtime-j716s.bin`, captured at fw 41.2, not from this trace).

## 0. Summary

- **[F]** The AP never originates a request on the PMP application endpoint (0x20). All 3,063 AP messages on ep 0x20 are replies to PMP requests (3,063 PMP messages, strictly request/reply, same count). Nothing in this window is a device-power, voter or floor command.
- **[F]** The ep 0x20 protocol is exactly the one already in m1n1 `proxyclient/experiments/pmp_init.py` (`PMPMessage`, TYPE = bits 55:48, IOVA = 47:0): GET_IOVA_TABLE, MALLOC/FREE, SET_BUF, ADVERTISE, SET_VAL. macOS answers it as the AP-side server. Nothing new in layout; new facts are values and cadence (below).
- **[F]** The only periodic "region" the AP is told about is the RTKit **IOReport buffer: IOVA 0x10000130000, 0x60000 bytes**, with 446 REPORT ping/pongs. All IOVAs below are in dart-pmp0 (vm-base 0x10000000000, 64 GiB) [ADT], so they are IOVAs, not physical addresses.
- **[F]** `apr0` (ProRes): zero accesses. The "3 events" are the three window registration lines (log lines 586-588).
- **[I]** The report-region offsets Joshua asked for (tgt_read, tgt_write, actual, status, fast_die) are not carried by the mailbox. They are PTD aperture offsets (MMIO at 0x284240000, direct loads/stores) and follow from the ADT `ptd-range` (section 4a). This trace did not cover that aperture.

## 1. Ordered PMP conversation

Message counts (decoder, 7,047 messages: 3,526 A2I, 3,521 I2A, plus 7,489 CTRL polls):

| ep | name | A2I | I2A | notes |
|---|---|---|---|---|
| 0 | mgmt | 10 | 5 | bring-up only |
| 1 | crashlog | 1 | 1 | buffer request/reply |
| 2 | syslog | 1 | 2 | INIT + buffer request/reply |
| 3 | kdebug | 3 | 1 | START + 2 buffers |
| 4 | ioreport | 447 | 448 | buffer, START, 446 REPORT each way (+1 REPORT popped, msg1 not logged, at end) |
| 7 | unidentified | 1 | 1 | crashlog-like buffer request |
| 0x20 | PMP app | 3,063 | 3,063 | PMP initiates, AP replies |

### 1a. RTKit bring-up (messages 0-48, lines 1101-1246)

| # | line | dir | msg0 | decode |
|---|---|---|---|---|
| 0 | 1101 | I2A | `0x00100000000c000c` | HELLO min=12 max=12 (RTKit v12; PMP is already running, pre-loaded, no-shutdown [ADT]) |
| 1 | 1103 | A2I | `0x00200000000c000c` | HELLO_ACK 12/12 |
| 2 | 1107 | I2A | `0x008000000000009f` | EPMAP base 0, bitmap 0x9f = eps 0,1,2,3,4,7 |
| 3-5,8,9 | 1109-1127 | A2I | `0x0050000N00000002` | STARTEP for N = 1,2,3,4,7 (one AP message each; kdebug exchange interleaved) |
| 6,7,12,13 | 1118-1140 | A2I/I2A | `0x0008000000000000`, I2A `0x0001000000008001`, A2I `0x0001010000018000`, `0x0002010000120000` | kdebug: START; PMP requests COUNT 0x8001 entries; AP gives buf0 IOVA 0x10000018000 (m1n1 sizing: align(0x8001*0x20, 0x4000) = 0x104000) and buf1 0x10000120000 (0x2000) |
| 10 | 1130 | A2I | `0x0080000000000001` | AP EPMAP reply, last=0, more=1 |
| 11 | 1134 | I2A | `0x0088000100000001` | EPMAP base 1, last=1, bitmap 1 = ep 0x20 |
| 14 | 1143 | A2I | `0x0088000100000000` | AP EPMAP reply, last=1 |
| 15,16 | 1147,1149 | I2A/A2I | `0x0010400000000000` / `0x0010410000128000` | crashlog buffer: 0x4000 bytes, AP gives IOVA 0x10000128000 |
| 17,18 | 1153,1155 | I2A/A2I | `0x0016000000000000` / `0x0016010000130000` | **ioreport buffer: size field 0x60 = 0x60000 bytes, AP gives IOVA 0x10000130000** |
| 19 | 1159 | I2A | `0x00c0000000000000` | ioreport START |
| 20-39 | 1162-1219 | both | `0x0080000000000000` | first 10 REPORT/echo pairs |
| 40,41 | 1223,1225 | I2A/A2I | `0x0010200000000000` / `0x0050210000194000` | ep 7: request size field 2 (0x2000), AP gives IOVA 0x10000194000; the AP reply has TYPE 5 where crashlog uses 1. Role of ep 7 not identified (m1n1/Linux have no ep 7; they have oslog at 8, tracekit at 0xa) |
| 42 | 1229 | I2A | `0x0070000000000020` | IOP_PWR_ACK state 0x20 (ON). No AP SET_IOP_PWR (type 6) precedes it: the AP sent none in the window |
| 43 | 1232 | A2I | `0x00b0000000000020` | SET_AP_PWR state 0x20 |
| 44-46 | 1236-1240 | I2A,I2A,A2I | `0x0080000050000010`, `0x0010100000000000`, `0x001011000019c000` | syslog INIT 16 entries x 80 B; buffer 0x1000 at IOVA 0x1000019c000 |
| 47 | 1244 | I2A | `0x00b0000000000020` | SET_AP_PWR ack from the PMP |
| 48 | 1246 | A2I | `0x0050002000000002` | STARTEP ep 0x20 |

So: HELLO(12) -> EPMAP(2 pages) -> STARTEP 1,2,3,4,7 (+ buffers) -> power state 0x20 handshake -> STARTEP 0x20. There is no oslog (ep 8) here; ep 7 takes its place in the EPMAP.

### 1b. Application endpoint 0x20, start (messages 49-110, lines 1250-1436)

```
I2A 0x0010000000000000  GET_IOVA_TABLE            A2I 0x0011000000000000  IOVA_TABLE_ACK table=0 (none)
I2A 0x0012000000004000  MALLOC 0x4000             A2I 0x00130100001a4000  iova 0x100001a4000
I2A 0x0012000000004000  MALLOC 0x4000             A2I 0x00130100001ac000  iova 0x100001ac000
I2A 0x0012000000001000  MALLOC 0x1000             A2I 0x00130100001b4000  iova 0x100001b4000
I2A 0x00300100001b4000  SET_BUF  iova 0x100001b4000   A2I 0x0031000000000000
I2A 0x00140100001b4000  FREE 0x100001b4000        A2I 0x0015000000000000
then, forever:  MALLOC 0x1000 -> 0x100001b4000 (same address every time),
                ADVERTISE iova 0x100001b4000 -> ADVERTISE_ACK(size), FREE 0x100001b4000
```

- **[F]** The IOVA table reply is 0: no table of host-to-IOVA mappings is handed over (m1n1 only builds one for T600x; this matches the newer-SoC branch).
- **[F]** After SET_BUF the 0x1b4000 page is freed and re-malloc'ed at the same IOVA for every ADVERTISE: it is the descriptor page. The two 0x4000 pages (0x1a4000, 0x1ac000) are never named again in any message.
- **[I]** By the m1n1 handler (`SetBuf`: `buf_ptr, _ = unpack("<QQ", ioread(msg.IOVA, 16))`) the SET_BUF page holds a 16-byte structure whose first qword points at one of the two 0x4000 pages; that page is where property data is written. The trace cannot say which one, since DRAM and the PMP DART were not traced.

### 1c. Steady state

- **[F]** Counts on ep 0x20 per direction: MALLOC/ACK 990 (988 x 0x1000, 2 x 0x4000), FREE/ACK 988, SET_BUF 1, ADVERTISE/ACK 987, SET_VAL/ACK 96. ADVERTISE_ACK INDEX (bits 47:32) is 0 in all 987.
- **[F]** One transaction = `MALLOC 0x1000 / ACK 0x100001b4000 / ADVERTISE 0x100001b4000 / ACK(size) / FREE / ACK`: 6 messages, 3 from the AP. Every PMP message carries the same IOVA; **the varying field is the ADVERTISE_ACK size** and the SET_VAL index/size.
- **[F]** From line 13377 on the pattern is periodic with **96 messages (48 A2I) per period**: 8 consecutive periods at lines 13.4k-15.4k (idx 4009-4681) and 10 at lines 16.5k-19.2k (idx 5035-5899), with a burst of 0x3c/0x3c0 blocks between them (lines 15.5k-16.5k) and later bursts (lines 19.2k-22k). Each period: 15 transactions (14 with size 0x4, one with size 0x40), 2 SET_VAL pairs (index N with size 4, index N+1 with size 0x40, N advancing 14 per period), and 1 ioreport REPORT pair. The interleave before that is bursty (REPORT runs of up to 186 pairs at line 2757; a run of 109 REPORT pairs with no ep 0x20 traffic at lines 22014-22677, the end).
- **[I]** Rate: the log has no clock. If the AP sends about 17 messages/s, a 48-message period lasts about 2.8 s: about 5.4 ADVERTISE transactions/s and one REPORT every 2.8 s in steady state. Treat as conditional on the 17/s figure.
- The AP side polls: 7,488 status reads from one PC (`AppleA7IOP::_reg+8`), A2I 0x100101 (one message pending) 3,369 times, I2A 0x100101 (one message queued) 3,458 times. The same ASC wrapper PCs as `DECODE-20261109-0050.md` (`_inbox` 0x...d218, `_outbox` 0x...d1f8; here slid to 0xfffffe003c61xxxx).

## 2. Application protocol decode (ep 0x20)

Layout (m1n1 `pmp_init.py`, confirmed by the values here), msg0 bits: TYPE 55:48, IOVA 47:0; MALLOC SIZE 23:0; ADVERTISE_ACK INDEX 47:32, SIZE 31:0; SET_VAL INDEX 15:0; SET_VAL_ACK SIZE 31:0. msg1 = 0x20 (endpoint).

| type | name | dir | payload seen | AP reply |
|---|---|---|---|---|
| 0x10 / 0x11 | GET_IOVA_TABLE / ACK | PMP / AP | once; ack IOVA 0 | none |
| 0x12 / 0x13 | MALLOC / ACK | PMP / AP | size 0x4000 x2, 0x1000 x988 | IOVA 0x100001a4000, 0x100001ac000, then 0x100001b4000 x988 |
| 0x14 / 0x15 | FREE / ACK | PMP / AP | 0x100001b4000 x988 | 0 |
| 0x30 / 0x31 | SET_BUF / ACK | PMP / AP | once, IOVA 0x100001b4000 | 0 |
| 0x32 / 0x33 | ADVERTISE / ACK | PMP / AP | descriptor IOVA 0x100001b4000 | size (table below), INDEX 0 |
| 0x34 / 0x35 | SET_VAL / ACK | PMP / AP | index N (see below) | size M |

**ADVERTISE_ACK sizes (987 replies).** The descriptor itself (name at +0, size at +0x40 per m1n1) is in DRAM and not in the trace, so names are not decoded. [F] size histogram: 0x4 x742, 0x38 x93, 0x3c x61, 0x8 x27, 0x40 x23, 0x0 x9, and 24 sizes with 1-3 occurrences. [I] **Large and medium sizes are the AP serving ADT properties of `/arm-io/pmp0/iop-pmp0-nub`** (the m1n1 handler does exactly this when the descriptor size is 0): replied sizes equal the byte lengths of J716s ADT properties one-to-one:

| size | count | ADT property of the same length [ADT] |
|---|---|---|
| 0x3c | (first, #5) | `pm-ptd-ranges` |
| 0x3a0 | 1 | `ptd-range` (29 x 32 B) |
| 0x8c | 1 | `dvfs-domain` / `dvfs-domain-afc-bin` |
| 0x11ec | 1 | `soc-device` |
| 0x6e8 | 1 | `controller` |
| 0xf50 | 2 | `temp-sensor` |
| 0x840 / 0xb60 / 0x620 / 0x690 / 0x380 | 1 each | `mcache-stream` / `agx-afr-bw-threshold` / `agx-dcs-bw-threshold` / `ane-dcs-bw-threshold` / `agx-af-bw-threshold` |
| 0x3c0 | 3 | `ane-af-bw-threshold`, `ane-lnk0/1-af-bw-threshold` (3 props) |
| 0x40 | 23 | the 23 properties of length 0x40 (`soc-niN-bw-threshold`, ...): 23 props, 23 replies |
| 0xa8 | 3 | `agx-af/dcs/afr-bw-constraint` (3 props, 3 replies) |
| 0x70, 0x78, 0x84, 0xa0, 0x114, 0x1c0, 0x1c, 0x20 | 2,2,2,1,1,1,1,1 | `dcs-bw-threshold`/`ans-dcs-bw-threshold`, `lts-voltage`, `fast-die-ctrl-ce-map`, `lts-config`, `sochot-sensors`, `lts-ctrl-loop`, `lts-clpc-voltage`, `lts-acsk-tddb-config` |

Not matched by any iop-pmp0-nub property length: 0x310, 0x578, 0x13b0 (1 each); 0x150 matches `pmgr perf-domains` and ptd SOC-DEV-PKT; **0x38 x93 and 0x3c x61 (counts far above ADT supply)**; and the many 4- and 8-byte replies (742 x 4 versus 71 u32 properties in the node). The 0x50-byte `-a` threshold variants (20 props) and 0x4b0 are never requested. [I] The unmatched small sizes are descriptors the PMP itself filled with a nonzero size (a "register" it publishes: the m1n1 handler just echoes that size and records it in `ioregs`). The 0x38/0x3c runs come in blocks (for example 12, 24 or 48 consecutive 0x38 replies, or 0x3c0 then 12 x 0x3c) which looks like arrays of 56/60-byte records. This is unresolved without the descriptor contents.

**SET_VAL.** [F] N takes 96 values from 0x4 to 0x369 (plus 0x1e at the very end), mostly rising by 1; the periodic steady state advances N by 14 per 96-message period although 15 ADVERTISE transactions occur. M is frequently the size of a nearby ADVERTISE_ACK (for example 0x35 0x3c right after 0x33 0x3c, 0x35 0xf50 after 0x33 0xf50) but not always: three consecutive SET_VAL with index 0x342 answered 0x78, 0xf50, 0x1c; 0x341 answered 0xa0 well after the 0xa0 ADVERTISE; and no simple `ioregs[N+k]` offset reproduces the replies (best offset matches 44 of 96). The relation between N and the ADVERTISE sequence is **not decoded**; m1n1 `pmp_init.py` replies `ioregs[INDEX]`, macOS does something that is not a plain list index (INDEX in ADVERTISE_ACK is always 0).

**Request/response pairing.** [F] Strictly one reply per request on ep 0x20, in order, no pipelining beyond one outstanding PMP request (balance 0 at every message). Ep 4 REPORT: PMP sends `0x0080000000000000`, AP echoes the same word (m1n1 `ioreporting.py` reads the buffer between the two; whether macOS reads before acking is not visible).

### Pointers that could be shared memory (all IOVAs in dart-pmp0 [ADT], none physical)

| IOVA | size | owner / use | source |
|---|---|---|---|
| 0x10000018000 | 0x104000 (derived) | kdebug buffer 0 | msg 12 |
| 0x10000120000 | 0x2000 (m1n1 value) | kdebug buffer 1 | msg 13 |
| 0x10000128000 | 0x4000 | crashlog | msg 16 |
| **0x10000130000** | **0x60000** | **ioreport (IOReport channels written by the PMP)** | msg 18 |
| 0x10000194000 | 0x2000 | ep 7 buffer | msg 41 |
| 0x1000019c000 | 0x1000 | syslog (16 x 80 B) | msg 46 |
| 0x100001a4000, 0x100001ac000 | 0x4000 each | PMP app pages (ADT-property data target, [I]) | msgs 52, 54 |
| 0x100001b4000 | 0x1000 | PMP app descriptor page (malloc/free'd 988 times) | msgs 56-... |

The allocation order is a bump allocator in 0x4000 steps (0x128000, 0x130000+0x60000, 0x194000, 0x19c000, 0x1a4000, 0x1ac000, 0x1b4000), the same style as the SEP/DCP IOVAs in the earlier report.

## 3. ProRes (apr0) register touches

- Registered windows (log lines 586-588): `apr0.reg1+0` 0x48c000000+0x1004000, `apr0.reg3+4` 0x48d070000+0x5000, `apr0.reg2` 0x48d0c0000+0x4000; PT entries installed ASYNC.RW.
- **[F] No MMIO event was logged in any of the three windows.** The log has 21,584 `MMIO:` lines and every one is `pmp.mbox`. Greps for 0x48c/0x48d addresses and `apr0` match only the registration/PT lines.
- So there are no offsets, directions or values to report. The "3 events" are almost certainly those three registration lines. [I] macOS did not touch the ProRes blocks before the capture ended (this boot window stops at PMP service steady state, single core, no disk).

## 4. What this means

### 4a. Answering #293 (offsets/regions macOS reads, how often)

- **[F] The mailbox gives no report-region offsets and no PTD addresses.** The PMP never receives an AP-originated register or offset message in this window, and the IOVA table reply is empty. The only shared-memory pointers are the IOVAs above. The only one macOS is prompted to consume repeatedly is the 0x60000 IOReport buffer (REPORT x446; about one per 96 messages in steady state, bursty at start).
- **[ADT, I] The `pmp-report.c` offsets are the PTD aperture (MMIO, base `0x284240000`, PTD update reg `0x284250000`, `ptd-update-reg-index` 3), from `iop-pmp0-nub` `ptd-range` as read by m1n1 `trace_pmp.py` (read = idx*16, write = 0x10000 + idx*8):**

| field | ptd-range entry | idx | offset | absolute |
|---|---|---|---|---|
| status | PMP-STATUS | 0x1 | 0x10 | 0x284240010 |
| tgt_read | SOC-DEV-PS-REQ | 0x1e0 | 0x1e00 | 0x284241e00 |
| tgt_write | SOC-DEV-PS-REQ | 0x1e0 | 0x10f00 | 0x284250f00 |
| actual | SOC-DEV-PS-ACK | 0x1e8 | 0x1e80 | 0x284241e80 |
| fast_die | FAST-DIE-CE | 0x258 | 0x2580 | 0x284242580 |

  This is identical to the existing `apple_pmp_offsets_t6041` in `drivers/pmdomain/apple/pmp-report.c` (0x1e00 / 0x10f00 / 0x1e80 / 0x10 / 0x2580, `running_any`, `defer_requests`). Lanes: `fast-die-ctrl-ce-map` has 3 entries, MACC0, MACC1, PACC_ANE (three 44-byte records), matching 2 M clusters + 1 P cluster, so `fast_die_lanes = 3`. Other ptd entries for completeness: FAST-DIE-TO-SMC 0x29a (0x29a0), SOC-DEV-DVFS 0x1f0, SOC-DEV-BWR 0x220, PMP-TO-GFX 0x2b5, PMS-VIRT-CNTR 0x320 (29 entries, ids 1-19, 24-29, 32-34, 40; identical to Joshua's J714c table per `PMP-J716S.md`).
- **How often macOS reads those offsets is not answerable from this log**: the PTD aperture was not in the trace groups (groups were `pmp` mailbox + `apr`). To answer it, add `0x284240000+0x14000` (covering reg[3] 0x284250000) as a trace window.

### 4b. Linux PMC/PMP floor work

- **[F] macOS does not write voter or floor registers through the PMP mailbox in this window.** No AP-originated message exists on ep 0x20 or on any other endpoint beyond RTKit bring-up and the REPORT echoes. The PMC (0x286000000 region) was not traced, so this log is silent on whether macOS writes the PMC voter/rail registers directly; it neither supports nor refutes the direct-write model in `REPORT.md`. Device power requests (SOC-DEV-PS-REQ) are PTD stores, not mailbox messages.
- **[F] Handshake that precedes the PMP service:** HELLO v12, 2-page EPMAP, STARTEP 1,2,3,4,7, IOP_PWR_ACK/AP_PWR 0x20, STARTEP 0x20, GET_IOVA_TABLE (ack 0), three MALLOCs, SET_BUF, then the AP serves ADT properties and register advertisements. **[I]** The PMP does not appear to need anything from the AP other than this service: the first ADT-property replies (`pm-ptd-ranges`, `ptd-range`, `dvfs-domain`, `soc-device` are among the first ten ADVERTISE_ACKs, lines 1368-1497) are how the PMP learns its own PTD layout and DVFS table. A Linux AP that stops answering MALLOC/ADVERTISE would starve the PMP of that table.
- **[I]** For Linux, the readiness signal remains PTD `PMP-STATUS` (0x284240010; `running_any` on T6041/T6050). In this trace the PMP is already running when the AP first looks (HELLO queued before the first status read at line 1098), and m1n1 `pmp_init.py` shows PTD writes are accepted before the mailbox is started, but only a PTD trace can say what macOS writes first and when.
- **[F] PMGR writes immediately before the PMP mailbox starts** (log lines 1068-1097, m1n1 "Dangerous write" PMGR hooks): read-modify-write of six PS registers, `0x3ff -> 0xff` then `0x100000ff` (ATC0_COMMON 0x280600208, FAB8_SOC 0x280900288, UART_P 0x280900310, UART0 0x280900360, ATC0_USB_AON 0x288300148, ATC0_USB 0x288300150; device names from the ADT PMGR table). ATC0_COMMON has `notify_pmp` set (id1 32). Whether these are meant for the PMP is [I] only.
- **Gap for the next capture:** (1) trace PTD aperture 0x284240000+0x14000 and PMC 0x286000000; (2) hook ADVERTISE/SET_VAL like `trace_pmp.py` and dump the descriptor page 0x100001b4000 and the SET_BUF target, which needs the dart-pmp0 DART tracer (m1n1 `trace_pmp.py` still names `/arm-io/dart-pmp` and `/arm-io/pmp`; J716s nodes are `dart-pmp0`, `pmp0`). That would turn the unresolved ADVERTISE names/SET_VAL index into facts.

## 5. Script change

`captures/mbox-decode.py`: `--dev pmp` accepted; ep 0x20 on pmp decoded with the m1n1 PMP layout (`pmp_decode`), ep 7 shown as a crashlog-like buffer request. Verified: `--dev sep|dcp|smc` output on `trace-cpus1-sep-dcp-smc-20261109-0050.log` is byte-identical to the previous script. The PMP-specific tables in this note (histograms, periodic-structure check, ADT size matching) were computed with ad-hoc scripts over the same parser, not added to the file.
