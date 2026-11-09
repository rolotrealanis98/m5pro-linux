# Mailbox decode: macOS 27.3 boot on M5 Pro (T6050 / J716s), SEP + DCP + SMC

Input: `captures/trace-cpus1-sep-dcp-smc-20261109-0050.log` (53,737 lines; the last line has no trailing newline, so the capture was cut). Run dir named `...-guest-nodisk-trace`, macOS guest with `cpus=1`, m1n1 hv27 under SPTM emulation. Offline analysis only; script: `captures/mbox-decode.py` (`python3 -I mbox-decode.py LOG [--dev sep|dcp|smc] [--polls]`).

## 0. Capture facts and one correction

| device | base | log lines (first..last message) | messages | A2I / I2A | status polls (+0x110/+0x114) |
|---|---|---|---|---|---|
| smc.mbox | 0x28c608000 | 1098..2369 | 233 | 115 / 118 | 241 |
| sep.mbox | 0x502608000 | 1416..2317 | 111 | 48 / 63 | 173 |
| dcp.mbox | 0x48ae08000 | 1717..53387 | 76 | 47 / 29 | 51,389 |

- After line 2371 the capture holds only DCP I2A polls (and 18 AP-to-DCP mgmt messages). No SEP or SMC access follows line 2371. The trace is ASYNC mode, so line order is arrival order, not time; there are no timestamps.
- Correction to the brief: in RTKit (DCP, SMC) the endpoint is `msg1[7:0]` (m1n1 `R_INBOX1.EP = 7:0`, Linux `apple_rtkit_send_message(rtk, ep, ...)`), not bits 63:56. Bits 63:56 are only the oslog endpoint's message type. The SEP is not RTKit: its endpoint is `msg0[7:0]` and `msg1` is 0 on every A2I.
- On I2A the `+0x838` word is not payload: bits 56:52 OUTCNT, 51:48 INCNT, 47:44 OUTPTR, 43:40 INPTR (m1n1 `R_OUTBOX1`) are FIFO counters. Bits 7:0 are the RTKit endpoint (0 for SEP).
- CTRL word (`+0x110` A2I, `+0x114` I2A, m1n1 `R_MBOX_CTRL`): FIFOCNT 23:20, OVERFLOW 18, EMPTY 17, FULL 16, RPTR 15:12, WPTR 11:8, ENABLE 0.

### Guest PCs resolve to the generic ASC wrapper, not to the SEP/DCP/SMC drivers
Unslid by matching the unique `ldp`/`stp` pair 0x20 apart in `studio-artifacts/macos-27.3/derived/kc.macho` (slide 0x3215c000; all five PCs land in matching symbols):

| guest PC | symbol (kext `com.apple.driver.AppleA7IOP-ASCWrap-v6`) | used for |
|---|---|---|
| 0xfffffe003ada5218 | `AppleASCWrapV6::_inbox(void*)+0x14` | every A2I send (one `stp` writes +0x800/+0x808) |
| 0xfffffe003ada51f8 | `AppleASCWrapV6::_outbox(void*)+0x10` | every I2A receive (one `ldp` of +0x830/+0x838) |
| 0xfffffe003ada5c40 | `AppleA7IOP::_reg(unsigned)+8`, copy inside `AppleASCWrapV6SEP` | all SEP status reads (+0x110/+0x114) |
| 0xfffffe003ada56fc | `AppleA7IOP::_reg(unsigned)+8`, copy inside `AppleASCWrapV6` | all DCP and SMC status reads |
| 0xfffffe003ada5368 | `AppleASCWrapV6::_enableOutbox(bool)+0x5c` | the one `W.4 +0x114` per device (writes back the value just read, ENABLE already 1) before the first send; SMC, SEP and DCP all do it |

So the PCs identify the shared mailbox primitives. The only SEP-specific fact they give: the SEP is driven through the `AppleASCWrapV6SEP` subclass. The log carries no callers, so the SEP/DCP/SMC protocol drivers are not identified.

## 1. Script

`captures/mbox-decode.py` pairs `W +0x800/+0x808` into one A2I message and `R +0x830/+0x838` into one I2A message, keeps `+0x110/+0x114` as polls (`--polls` prints them as collapsed runs with the CTRL word split into fields), and prints per device: line, guest PC, direction, msg0, info word, decode.
- RTKit (dcp, smc): mgmt type = msg0[59:52] (HELLO 1, HELLO_ACK 2, STARTEP 5, SET_IOP_PWR 6, IOP_PWR_ACK 7, EPMAP 8, SET_AP_PWR/ACK 0xb), EPMAP bitmap expansion, crashlog/syslog/debug(kdebug)/ioreport/oslog buffer and init messages (layouts from Linux `rtkit.c` and m1n1 `fw/asc/*.py`), DCP ep 0x37 (m1n1 `dcpep.py`), SMC ep 0x20 (`macsmc.c` / m1n1 `smc.py`: type 7:0, id 15:12, size 23:16, wsize 31:24, key 63:32 as ASCII).
- SEP: m1n1 `hw/sep.py` `SEPMessage` (ep 7:0, tag 15:8, type 23:16, param 31:24, data 63:32), discovery names (data as 4 ASCII chars, MSB first, as `sep.py` does), shmem registration, control-endpoint ops (Linux `proto.rs`), xarm requests (Linux `xarm.rs` byte layout).
- Prints the SEP endpoint table in advertised order.


## 2. SEP

### Result
- macOS 27.3 does a **warm registration**: one message on ep 0xFE, no boot-ROM (0xFF) traffic at all, no TZ0/IMG4. The SEP answers with a **discovery burst on ep 0xFD: 7 endpoints in 17 messages**.
- The sequence **does not complete and does not fail inside the capture; it is cut off** (see "Where it stops"). Only the first 7 endpoints (of the 12 macOS lists for this machine in `FEASIBILITY.md`: cntl hibe stac xars xarm pnon hdcp sbio skdl sse scrd sks) are ever advertised in the window; sbio/skdl/sse/scrd/sks never appear.

### Advertised endpoints, in advertised order
Descriptor = `ep 0xFD, type 0, param = endpoint index, data = 4 ASCII chars MSB first`; each is followed at once by a config message (`type 1`, same param, data = 4 config bytes; meaning unknown).

| order | index | name | config word | seen later |
|---|---|---|---|---|
| 1 | 0x14 | hibe | 0x01010101 | none |
| 2 | 0x18 | stac | 0x02020202 | OOL buffers, echo/ping-like msgs |
| 3 | 0x00 | cntl | 0x00000000 | control ops, replies |
| 4 | 0x10 | xars | 0x02020202 | OOL buffers, one AP message |
| 5 | 0x13 | xarm | 0x02020202 | SEP request (QUERY_PROTECTED) |
| 6 | 0x15 | pnon | 0x05050707 | none |
| 7 | 0x0e | hdcp | 0x01010101 | OOL buffers, 14-step exchange |

Between descriptors the SEP also sends three non-discovery messages: xarm request tag 0x02 opcode 0x0e (line 1687), control-endpoint type 0x0d (1698), type 0x29 (1702). Later, unsolicited control type 0x10 (2286).

### Conversation (phases)
1. **L1414-1418, AP**: reads I2A_CTRL (0x22201, empty, rptr=wptr=2), writes the same value back (ENABLE), then one send: `0x100005dc001c00fe` = ep 0xFE, size field (23:16) 0x1c (x4 KiB = 0x1c000), data (63:32) 0x100005dc (x4 KiB = IOVA 0x100005dc000), msg1 = 0. No acknowledgement exists on 0xFE.
2. **L1652-1709, SEP**: the 17-message burst above (first I2A_CTRL poll shows 2 queued).
3. **L1712 on, AP control endpoint 0x00** (replies = type 0x01, same tag, data in 63:32): `GET_ENTROPY` (type 0x36, tag 0x08) first, then pipelined (several requests before any reply) per endpoint `IN_SIZE (0x04)`, `IN_ADDR (0x02)`, `OUT_SIZE (0x05)`, `OUT_ADDR (0x03)` with param = endpoint, data = length or IOVA>>12: hdcp 0x4000/0x4000, xarm 0x8000/0x8000, stac 0x8000/0x8000 (L1818-2102), later xars 0x8000/0x8000 (L2289-2314). `SECMODE` (type 0x14, tag 6) reply data = 3. Every control request got its reply (tag balance zero). 12 `GET_ENTROPY` requests in total, 12 replies (32-bit words, not reproduced here).
   OOL IOVAs (all inside the DART window that starts at 0x10000004000): hdcp in 0x10000004000, out 0x10000040000; xarm in 0x1000001c000, out 0x10000034000; stac in 0x10000028000, out 0x10000048000; xars in 0x10000054000, out 0x10000060000. Shared table at 0x100005dc000.
4. **hdcp 0x0e, L2105-2259**: AP `0x270e` (tag 0x27, type 0); SEP `0x0000000e0000000e`; then 14 AP messages tag 0x28 with param 0..0xd, each answered by SEP type 0x08 (`0x0008000e`). 30 hdcp messages total.
5. **stac 0x18, L2269-2286**: AP `0x0ffc18` (tag 0xfc, type 0x0f), the SEP echoes it bit for bit; AP `0x0bfc18` (tag 0xfc, type 0x0b), no echo; SEP then sends control type 0x10.
6. **xars 0x10, L2289-2317**: OOL setup as in 3, then AP `0x170610` (tag 6, type 0x17). Last message in the SEP window.

### Which messages the AP sends first, and what the SEP answers
First AP message: the 0xFE registration (nothing else, nothing before it). First SEP answer: `hibe` descriptor (0x68696265140000fd). First AP control request after discovery: `GET_ENTROPY` (not a NOP/probe). The AP never answers the SEP's xarm QUERY_PROTECTED (tag 0x02) inside the window; no A2I message on ep 0x13 exists in the whole log.

### Where it stops
- Last SEP message: reply tag 0x08 to `OOL_OUT_ADDR` (xars), L2314. Last AP message: xars `0x170610`, L2317. Last SEP-window access: `R A2I_CTRL = 0x10f001` (cnt=1, the message just sent, not yet consumed), L2319.
- No I2A status read follows, so the capture cannot say whether the SEP answered. The cause is on the guest side: after L2371 the guest spins on the DCP status read (section 4) and no mailbox of any device is touched.
- Outstanding at the end: xarm tag 0x02 query (AP never replied), xars `0x170610`. The run is `guest-nodisk`; whether the missing xarm reply is because no disk/xART store was present is a guess, not shown by the log.

### Full ordered SEP conversation (111 messages; entropy words omitted)
| # | line | dir | msg0 | decode |
|--|--|--|--|--|
| 0 | 1416 | A2I | `0x100005dc001c00fe` | SHMEM registration: size field 0x1c -> 0x1c000 bytes, iova field 0x100005dc -> iova 0x100005dc000 |
| 1 | 1653 | I2A | `0x68696265140000fd` | DISCOVER descriptor: endpoint 0x14 name 'hibe' |
| 2 | 1656 | I2A | `0x01010101140100fd` | DISCOVER config for endpoint 0x14 ('hibe') cfg bytes [1, 1, 1, 1] |
| 3 | 1660 | I2A | `0x73746163180000fd` | DISCOVER descriptor: endpoint 0x18 name 'stac' |
| 4 | 1663 | I2A | `0x02020202180100fd` | DISCOVER config for endpoint 0x18 ('stac') cfg bytes [2, 2, 2, 2] |
| 5 | 1667 | I2A | `0x636e746c000000fd` | DISCOVER descriptor: endpoint 0x00 name 'cntl' |
| 6 | 1670 | I2A | `0x00000000000100fd` | DISCOVER config for endpoint 0x00 ('cntl') cfg bytes [0, 0, 0, 0] |
| 7 | 1674 | I2A | `0x78617273100000fd` | DISCOVER descriptor: endpoint 0x10 name 'xars' |
| 8 | 1677 | I2A | `0x02020202100100fd` | DISCOVER config for endpoint 0x10 ('xars') cfg bytes [2, 2, 2, 2] |
| 9 | 1680 | I2A | `0x7861726d130000fd` | DISCOVER descriptor: endpoint 0x13 name 'xarm' |
| 10 | 1683 | I2A | `0x02020202130100fd` | DISCOVER config for endpoint 0x13 ('xarm') cfg bytes [2, 2, 2, 2] |
| 11 | 1687 | I2A | `0x00000000000e0213` | xarm request: tag=0x02 opcode=0x0e(QUERY_PROTECTED) len=0x0 args=0x00,0x00,0x00 |
| 12 | 1691 | I2A | `0x706e6f6e150000fd` | DISCOVER descriptor: endpoint 0x15 name 'pnon' |
| 13 | 1694 | I2A | `0x05050707150100fd` | DISCOVER config for endpoint 0x15 ('pnon') cfg bytes [5, 5, 7, 7] |
| 14 | 1698 | I2A | `0x00000000000d0000` | CONTROL I2A type 0xd (unsolicited / unknown) |
| 15 | 1702 | I2A | `0x0000000000290000` | CONTROL I2A type 0x29 (unsolicited / unknown) |
| 16 | 1706 | I2A | `0x686463700e0000fd` | DISCOVER descriptor: endpoint 0x0e name 'hdcp' |
| 17 | 1709 | I2A | `0x010101010e0100fd` | DISCOVER config for endpoint 0x0e ('hdcp') cfg bytes [1, 1, 1, 1] |
| 18 | 1712 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 19 | 1818 | A2I | `0x000040000e040700` | CONTROL request OOL_IN_SIZE for ep 0x0e ('hdcp') len=0x4000 |
| 20 | 1824 | A2I | `0x0000000000140600` | CONTROL request SECMODE |
| 21 | 1910 | A2I | `0x0000800013040500` | CONTROL request OOL_IN_SIZE for ep 0x13 ('xarm') len=0x8000 |
| 22 | 1913 | A2I | `0x0000800018040400` | CONTROL request OOL_IN_SIZE for ep 0x18 ('stac') len=0x8000 |
| 23 | 1993 | I2A | `0xea2d822400010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 24 | 1997 | I2A | `0x0000400000010700` | CONTROL reply tag 0x07, data=0x4000, to OOL_IN_SIZE |
| 25 | 2001 | I2A | `0x0000000300010600` | CONTROL reply tag 0x06, data=0x3, to SECMODE |
| 26 | 2005 | I2A | `0x0000800000010500` | CONTROL reply tag 0x05, data=0x8000, to OOL_IN_SIZE |
| 27 | 2009 | I2A | `0x0000800000010400` | CONTROL reply tag 0x04, data=0x8000, to OOL_IN_SIZE |
| 28 | 2012 | A2I | `0x1000001c13020500` | CONTROL request OOL_IN_ADDR for ep 0x13 ('xarm') iova=0x1000001c000 |
| 29 | 2015 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 30 | 2020 | I2A | `0x1000001c00010500` | CONTROL reply tag 0x05, data=0x1000001c, to OOL_IN_ADDR |
| 31 | 2024 | I2A | `0x8baf4d8300010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 32 | 2028 | A2I | `0x100000040e020700` | CONTROL request OOL_IN_ADDR for ep 0x0e ('hdcp') iova=0x10000004000 |
| 33 | 2031 | A2I | `0x0000800013050500` | CONTROL request OOL_OUT_SIZE for ep 0x13 ('xarm') len=0x8000 |
| 34 | 2035 | I2A | `0x1000000400010700` | CONTROL reply tag 0x07, data=0x10000004, to OOL_IN_ADDR |
| 35 | 2038 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 36 | 2041 | I2A | `0x0000800000010500` | CONTROL reply tag 0x05, data=0x8000, to OOL_OUT_SIZE |
| 37 | 2045 | A2I | `0x1000003413030500` | CONTROL request OOL_OUT_ADDR for ep 0x13 ('xarm') iova=0x10000034000 |
| 38 | 2048 | I2A | `0x3af7368a00010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 39 | 2052 | A2I | `0x1000002818020400` | CONTROL request OOL_IN_ADDR for ep 0x18 ('stac') iova=0x10000028000 |
| 40 | 2055 | A2I | `0x000040000e050700` | CONTROL request OOL_OUT_SIZE for ep 0x0e ('hdcp') len=0x4000 |
| 41 | 2058 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 42 | 2062 | I2A | `0x1000003400010500` | CONTROL reply tag 0x05, data=0x10000034, to OOL_OUT_ADDR |
| 43 | 2066 | I2A | `0x1000002800010400` | CONTROL reply tag 0x04, data=0x10000028, to OOL_IN_ADDR |
| 44 | 2070 | I2A | `0x0000400000010700` | CONTROL reply tag 0x07, data=0x4000, to OOL_OUT_SIZE |
| 45 | 2073 | I2A | `0x8d392c9200010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 46 | 2076 | A2I | `0x0000800018050400` | CONTROL request OOL_OUT_SIZE for ep 0x18 ('stac') len=0x8000 |
| 47 | 2080 | A2I | `0x100000400e030700` | CONTROL request OOL_OUT_ADDR for ep 0x0e ('hdcp') iova=0x10000040000 |
| 48 | 2083 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 49 | 2087 | I2A | `0x0000800000010400` | CONTROL reply tag 0x04, data=0x8000, to OOL_OUT_SIZE |
| 50 | 2090 | A2I | `0x1000004818030400` | CONTROL request OOL_OUT_ADDR for ep 0x18 ('stac') iova=0x10000048000 |
| 51 | 2094 | I2A | `0x1000004000010700` | CONTROL reply tag 0x07, data=0x10000040, to OOL_OUT_ADDR |
| 52 | 2098 | I2A | `0x37c19b5800010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 53 | 2102 | I2A | `0x1000004800010400` | CONTROL reply tag 0x04, data=0x10000048, to OOL_OUT_ADDR |
| 54 | 2105 | A2I | `0x000000000000270e` | 'hdcp' endpoint message msg |
| 55 | 2108 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 56 | 2112 | I2A | `0x0000000e0000000e` | 'hdcp' endpoint message msg |
| 57 | 2116 | I2A | `0x0a5d342300010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 58 | 2119 | A2I | `0x000000000000280e` | 'hdcp' endpoint message msg |
| 59 | 2122 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 60 | 2126 | I2A | `0x7251e31f00010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 61 | 2130 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 62 | 2133 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 63 | 2137 | I2A | `0xa4283bd300010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 64 | 2141 | A2I | `0x000000000100280e` | 'hdcp' endpoint message msg |
| 65 | 2144 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 66 | 2148 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 67 | 2152 | I2A | `0x3e4385fb00010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 68 | 2155 | A2I | `0x000000000200280e` | 'hdcp' endpoint message msg |
| 69 | 2158 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 70 | 2162 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 71 | 2166 | I2A | `0xe12eccd000010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 72 | 2169 | A2I | `0x000000000300280e` | 'hdcp' endpoint message msg |
| 73 | 2172 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 74 | 2176 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 75 | 2180 | I2A | `0x5a76a5ac00010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 76 | 2183 | A2I | `0x000000000400280e` | 'hdcp' endpoint message msg |
| 77 | 2186 | A2I | `0x0000000000360800` | CONTROL request GET_ENTROPY |
| 78 | 2190 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 79 | 2194 | I2A | `0xd0352a8900010800` | CONTROL reply tag 0x08 to GET_ENTROPY (data = one 32-bit entropy word) |
| 80 | 2198 | A2I | `0x000000000500280e` | 'hdcp' endpoint message msg |
| 81 | 2202 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 82 | 2205 | A2I | `0x000000000600280e` | 'hdcp' endpoint message msg |
| 83 | 2209 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 84 | 2212 | A2I | `0x000000000700280e` | 'hdcp' endpoint message msg |
| 85 | 2216 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 86 | 2219 | A2I | `0x000000000800280e` | 'hdcp' endpoint message msg |
| 87 | 2223 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 88 | 2226 | A2I | `0x000000000900280e` | 'hdcp' endpoint message msg |
| 89 | 2230 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 90 | 2233 | A2I | `0x000000000a00280e` | 'hdcp' endpoint message msg |
| 91 | 2237 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 92 | 2240 | A2I | `0x000000000b00280e` | 'hdcp' endpoint message msg |
| 93 | 2244 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 94 | 2247 | A2I | `0x000000000c00280e` | 'hdcp' endpoint message msg |
| 95 | 2251 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 96 | 2255 | A2I | `0x000000000d00280e` | 'hdcp' endpoint message msg |
| 97 | 2259 | I2A | `0x000000000008000e` | 'hdcp' endpoint message msg |
| 98 | 2269 | A2I | `0x00000000000ffc18` | 'stac' endpoint message msg |
| 99 | 2273 | I2A | `0x00000000000ffc18` | 'stac' endpoint message msg |
| 100 | 2276 | A2I | `0x00000000000bfc18` | 'stac' endpoint message msg |
| 101 | 2286 | I2A | `0x0000000000100000` | CONTROL I2A type 0x10 (unsolicited / unknown) |
| 102 | 2289 | A2I | `0x0000800010040800` | CONTROL request OOL_IN_SIZE for ep 0x10 ('xars') len=0x8000 |
| 103 | 2293 | I2A | `0x0000800000010800` | CONTROL reply tag 0x08, data=0x8000, to OOL_IN_SIZE |
| 104 | 2296 | A2I | `0x1000005410020800` | CONTROL request OOL_IN_ADDR for ep 0x10 ('xars') iova=0x10000054000 |
| 105 | 2300 | I2A | `0x1000005400010800` | CONTROL reply tag 0x08, data=0x10000054, to OOL_IN_ADDR |
| 106 | 2303 | A2I | `0x0000800010050800` | CONTROL request OOL_OUT_SIZE for ep 0x10 ('xars') len=0x8000 |
| 107 | 2307 | I2A | `0x0000800000010800` | CONTROL reply tag 0x08, data=0x8000, to OOL_OUT_SIZE |
| 108 | 2310 | A2I | `0x1000006010030800` | CONTROL request OOL_OUT_ADDR for ep 0x10 ('xars') iova=0x10000060000 |
| 109 | 2314 | I2A | `0x1000006000010800` | CONTROL reply tag 0x08, data=0x10000060, to OOL_OUT_ADDR |
| 110 | 2317 | A2I | `0x0000000000170610` | 'xars' endpoint message msg |

## 3. SMC (smc.mbox) - RTKit v12, then SMC endpoint 0x20

Management bring-up (L1098-1239), all standard (matches m1n1 `ASCManagementEndpoint` and Linux `rtkit.c`):
`SET_IOP_PWR 0x220` (A2I) -> `HELLO min=max=12` (I2A) -> `HELLO_ACK 12/12` -> `EPMAP` base 0 bitmap 0x117 = eps 0,1,2,4,8 (not last) -> `STARTEP` 1,2,4,8 -> AP EPMAP reply (more=1) -> `EPMAP` base 1 bitmap 0x1 = ep 0x20 (last) -> AP EPMAP reply (last) -> `IOP_PWR_ACK 0x20` -> AP `SET_AP_PWR 0x20` -> SMC `SET_AP_PWR 0x20` -> `STARTEP 0x20`.
Standard endpoints in between: crashlog (ep 1) buffer request 0x4000 at firmware-placed 0x28de88000, echoed by the AP; ioreport (ep 4) buffer request 0x1000 at 0x28de8e000, START, then 12 REPORT ping-pongs; syslog (ep 2) INIT (32 entries x 96 B) and buffer request at 0x28de8c000 (AP does not answer, firmware-owned); oslog (ep 8) buffer request size 0xff8 at 0x28de8d000 plus four further type 3/4 messages (undocumented in m1n1/Linux).

SMC endpoint 0x20 (L1242-2369; 92 commands, all but the last answered, ids cycle 0..15):
- `INITIALIZE` (type 0x17, id 0); reply is the whole 64-bit message = address `0x28de90000` (m1n1 `SMCEndpoint.handle_msg`: first reply is the shmem address).
- `READ_KEY #KEY` size 4 -> value 0x2c0e0000, i.e. bytes 00 00 0e 2c, 0x00000e2c (3628 keys) when read big-endian as Linux `macsmc.c` does.
- `GET_KEY_INFO CLKH`, `WKTP`: result 0x84 (non-zero error; 0x84 is the not-found code in Asahi's SMC notes, not checked in this repo).
- `WRITE_KEY NTAP` size 1: ok (notification enable; Linux macsmc writes the same key at probe).
- `GET_KEY_INFO RGEN` ok, `READ_KEY RGEN` size 1 -> 4; `READ_KEY aDC#` size 4 -> 0xe1.
- Then 42 x `RW_KEY aDC?` (rsize 4, wsize 4; the AP writes an index into shmem and the SMC returns a 4-char key name: VP0u, TP0Z, VP0B, TP1d, ...) each followed by `GET_KEY_INFO` of the returned name: 31 of the 45 key-info replies are 0x84, the rest 0x00. This is AppleSMC enumerating the ADC key table, not Linux-relevant for the SEP.
- Counts (A2I): GET_KEY_INFO 45, RW_KEY 42, READ_KEY 3, WRITE_KEY 1, INITIALIZE 1.
- Last message: AP `GET_KEY_INFO VP9l` (id 0xb), L2369, no reply in the window (the guest stopped touching the mailboxes, same cut-off as the SEP).
Every SMC command was answered within a few log lines. INITIALIZE, the `#KEY` read and the `NTAP` write are the same three steps Linux `macsmc.c` does at probe.

## 4. DCP (dcp.mbox)

Non-poll messages (76; full list from `--dev dcp`):
1. `SET_IOP_PWR 0x220`, `HELLO 12/12`, `HELLO_ACK`, `EPMAP` base 0 bitmap 0x11d = eps 0,2,3,4,8; `STARTEP` 2,3,4,8; AP EPMAP replies.
2. `EPMAP` base 1 bitmap 0x00823f3f = eps 0x20-0x25, 0x28-0x2d, 0x31, 0x37 (last).
3. ep 3 (kdebug): AP START, DCP GET_BUFFER (data 0x125d), AP SET_BUFFER0/1 (0x10000000000, 0x1000002c000).
4. ep 4 (ioreport): DCP requests 0x4000 with dva 0, AP gives 0x10000034000; START; 11 REPORT ping-pongs.
5. `IOP_PWR_ACK 0x20`, AP `SET_AP_PWR 0x20`, DCP `SET_AP_PWR 0x20`.
6. ep 2 (syslog): INIT 63 entries x 128 B, buffer request 0x3000 answered with 0x1000003c000; DCP LOG index 0,1,2, each echoed by the AP. ep 8 (oslog): buffer request size 0x5ff8 at 0x1000acc4000 plus four type 3/4 messages.
7. **IOMFB start**: AP `STARTEP 0x37` at L1947 is the only ep-0x37 event. There is **no message on ep 0x37 in either direction** and no start of eps 0x20-0x2d/0x31. In m1n1 `DCPEndpoint.initialize()` the AP sends `SET_SHMEM` (type 0, DVA<<16) first and waits for `INIT_COMPLETE` (type 1); neither occurs here.
8. The last DCP message is syslog LOG index 2 (L1969, acked L1971). After that the AP sends 18 `mgmt type 0xf` messages (`0x00f0000000000000`; not defined in m1n1 or Linux; lines 2372, 3142, 4580, 6733, 9622, 13242, 17560, 22578, 28372, 34923, 43166, 51154, 51525, 51898, 52270, 52643, 53015, 53387).

### The long poll of +0x114 = 0x27701
`0x27701` = ENABLE 1, EMPTY (bit 17) 1, FULL 0, OVERFLOW 0, FIFOCNT 0, RPTR 7, WPTR 7: the I2A FIFO is empty and nothing is queued. The guest (PC `AppleA7IOP::_reg` read in `AppleASCWrapV6`) polls I2A_CTRL waiting for EMPTY to clear, i.e. for any message from the DCP. About 51,000 reads, from L2375 to the end of the log (L53738), all return the same value.
- Pointer arithmetic closes: the DCP I2A FIFO started at rptr=wptr=10 (first poll, 0x2aa01); 29 messages were popped; (10+29) mod 16 = 7. Every DCP message was read; none is left unread.
- The loop is poll-then-resend: a poll run (767, 1435, 2149, 2886, 3617, 4315, 5015, 5791, 6548, 8240, 7984 reads, then a steady ~370) ends with the next `type 0xf` send. The DCP does consume them: A2I_CTRL after each send shows cnt=1 with RPTR advanced by exactly one since the previous send (rptr 11, 12, 13, 14, 15, 0, 1, ...). So the DCP's mailbox hardware is alive and consuming.
- **The DCP never answers**: no I2A message after L1969. What the guest waits for is not decodable from the log; the only protocol-level gap visible is the missing AP `SET_SHMEM` on ep 0x37 that m1n1 and Linux (`dcp.c`) send right after `STARTEP 0x37`.

## 5. What this means for the Linux SEP attach (T6050)

Compared against `drivers/soc/apple/{proto,sep,xarm,shmem,profile}.rs` in `/Volumes/linux-cs/wt-series` and `contrib/pending/platform/touchid-sep/{FEASIBILITY,RUNG-A}.md`.

### What the Linux driver must send first, and expect
1. Enable the I2A FIFO (`+0x114`, ENABLE) then **exactly one** message: `msg0 = 0xFE | (size/0x1000) << 16 | (iova/0x1000) << 32`, `msg1 = 0` (`proto.rs::encode_registration_msg0`). macOS sent precisely this form on this SEP: `0x100005dc001c00fe`. No ack; the answer is the burst below.
2. Expect on ep 0xFD, in this order for this machine: hibe 0x14, stac 0x18, cntl 0x00, xars 0x10, xarm 0x13, pnon 0x15, hdcp 0x0e (descriptor type 0 then config type 1 each). Linux `on_discovery` already accepts type 0 and 1 and records `param`, so the count reads 7 at the first quiet point (the ladder start that RUNG-A expects: "7 -> 11 -> 12").
3. Expect, inside the same burst and before the AP has sent anything: an xarm request `tag 0x02, opcode 0x0e (QUERY_PROTECTED), len 0` (L1687) and control-endpoint messages of type 0x0d and 0x29. Linux's `on_control` drops anything but type 0x01, and its `on_xarm` defers the QUERY_PROTECTED reply until the xarm OOL buffers are registered (`deferred_query`, released in `tick_attach`), which is consistent with macOS having registered xarm OOL before it was due to answer.
4. Control endpoint: replies are type 0x01 with the request's tag and data in 63:32 (`CONTROL_REPLY_TYPE`), as Linux assumes. `SECMODE` (type 0x14) replied data 3; `GET_ENTROPY` (0x36) replied one word. OOL registration order per endpoint (IN_SIZE, IN_ADDR, OUT_SIZE, OUT_ADDR; data = len or IOVA>>12) is the same as `register_ool`; xarm 0x8000/0x8000 equals `OOL_SIZE_XARM`.

### Match / mismatch table
| item | macOS 27.3 on this machine (capture) | Linux plan (repo) | status |
|---|---|---|---|
| bootstrap | warm registration only; no 0xFF boot-ROM traffic, no TZ0/IMG4 | `Bootstrap::WarmRegister` (T6040 clone) | match |
| registration format | ep 0xFE, size in 23:16, iova>>12 in 63:32, msg1 0 | same | match |
| registration size | **0x1c000** (field 0x1c) | profile capacity **0x40000** (field 0x40), size field = allocation size (`shmem.rs`) | **differs**; unknown whether the SEP checks the size against the table. The table macOS registers (0x1c000) is larger than the 0x14000 that m1n1's M1-era `hw/sep.py` layout (header + CINP + OPLA + IPIS) occupies, so it may hold another item or more padding; its contents are not in the capture. A wrong size is the "parks the SEP until a cold boot" case |
| DART window | every IOVA macOS used (table 0x100005dc000, OOL 0x10000004000..0x10000060000) is inside `0x10000004000 + 0xffff0000` | `apple,dma-range = <0x10000004000 0xffff0000>` (RUNG-A) | match, independent confirmation of the ADT-derived window |
| endpoints known to Linux | 0x00 cntl, 0x13 xarm present | EP_CONTROL, EP_XARM 0x13 | match |
| endpoints macOS uses that Linux does not | hdcp 0x0e (OOL 0x4000 + 14-step exchange), stac 0x18 (OOL 0x8000 + 0xfc echo/0x0b), xars 0x10 (OOL 0x8000 + one message 0x170610), hibe 0x14, pnon 0x15 (no traffic) | none planned; unhandled endpoints are only logged | **gap**; whether the SEP needs any of this before it advertises sbio/skdl/sse/scrd/sks is unknown from this capture (the capture ends before that step) |
| later endpoints | sbio, skdl, sse, scrd, sks never advertised in the window (macOS list in FEASIBILITY: 12 total); their indices are not in the capture | sbio 0x08, scrd 0x0a, sks 0x12 | unverified for T6050 |
| control probe | no NOPs (params 0x00, 0x01, 0xff); first control op `GET_ENTROPY`, then OOL, `SECMODE` | `control_survey`: NOP x3 then SECMODE, then xarm OOL | NOP untested here; harmless on other SoCs, unseen on this one |
| entropy tag | tag 0x08 | reserved tag 0xE7 (pool 0x01..0x7e otherwise) | tag 0xE7 not observed; low tags are |
| pipelining | several control requests in flight (tags 4-8) | one request at a time | fine, replies are tag-matched |

### Honest limits of this capture
- It stops after the first 7 endpoints and about 2,400 log lines into boot because the guest stopped servicing the mailboxes (DCP wait loop), so the 7 -> 11 -> 12 steps of the ladder and the key store (EP 0x12) are not observed on T6050.
- The xarm QUERY_PROTECTED request was never answered by macOS inside the window; the SEP's reaction to that is unknown.
- `GET_ENTROPY` replies exist in the capture but are not reproduced here.
