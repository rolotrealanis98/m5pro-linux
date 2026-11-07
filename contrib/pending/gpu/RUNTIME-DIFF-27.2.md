# GPU runtime interface: 27.0 (26A428) vs 27.2 (26B123) vs 27.3 beta 1

2026-11-07. Agent E of the 27.2+ GPU port. Analysis only. Target: J716s, G17S firmware variant `a010`.
Driver reference: Aurora PR #1012 at `b1615e3fca90`, `drivers/gpu/drm/asahi/g17`.

## Verdict

- **27.0 → 27.2: no runtime structure that Aurora builds or parses changed.** 0 of 24 structures in the table have
  a different layout. The firmware code that reads them is byte-identical apart from relocation.
- **Two additive changes in 27.2:**
  1. A new command type, **0x14** ("UMA sync node", 0x48 bytes). Aurora never emits it.
  2. A new firmware-recovery reason, **5** ("DSF Pause Timeout"). Aurora's M5 path doesn't read the reason.
- **27.3b1 = 27.2 for every runtime structure.** 27.3 adds one more recovery reason (6, "Sleep Forced Idle Timeout").
- **Correction to ANALYSIS-27.3 §1.3: 27.3b1 ≠ 27.2 in InitData.** The HW-data change (a u32 inserted at 0x2720,
  tail +4) is **27.3-only**. The 27.2 kext and firmware use the 27.0 HW-data layout. Both builds still carry the
  same version word `0x0c8e_4339_8728_04c0`.
  - So the firmware's interface check can't tell 27.2 from 27.3. A "27.2+" profile needs two HW-data variants,
    chosen by the firmware identity (`fwid`), not by the version word.
  - The policy and status-config changes are 27.0 → 27.2 and unchanged in 27.3, as §1.3 says.
  - The policy and status-config verdicts come only from the secondary-image function diff, which agrees with
    §1.3. This agent didn't verify them field by field.
- **What Aurora must change for runtime work on 27.2/27.3: nothing.** Optional: decode the new recovery reasons.
  Required elsewhere (InitData, agent covering it): the 27.3 HW-data band.

## Method

1. **Firmware side (the consumer of every runtime structure).**
   - Carved the `a010` Mach-O out of `armfw_g17x.im4p` (primary) and `armfw1_g17x.im4p` (secondary) for 27.0, 27.2
     and 27.3b1, using the rkosftab table from `hwdata/fw-layout.py`.
   - Disassembled `__TEXT,__text` and diffed function by function.
   - Normalization: adrp page offsets, branch targets and PAC discriminators are masked.
   - For every changed function, compared the multiset of non-stack memory offsets and immediates. Register
     allocation then drops out.
2. **Kext side (the host builder in macOS).**
   - Same diff for the `com.apple.AGXG17X` kexts. Named functions were found through their assert and
     `__PRETTY_FUNCTION__` strings: `AGX{TA,3D,CL}ChannelSKSM::submitBuffer`, `AGXChannel::writeChannelCommandPointer`,
     `encodeNops`, `submitNop`, `prepareNopResources`, `AGXFirmware::drainFirmwareEventRing`,
     `AGXFirmwareRingValidator`, `AGXStatistics::recordStatisticsEntryFromFW`,
     `AGXAcceleratorRing<DeviceControlEntry>`, parameter-buffer management, and the FW resource pools.
3. **Limit.**
   - The TA/3D/compute descriptor bodies and their register arrays are written by userspace (AGXMetal). Userspace
     isn't in the inputs, and the kext never touches e.g. 3D +0x2198/+0x2209/+0x222f.
   - For those, the evidence is the firmware's reading code. The register arrays are executed by the GPU hardware,
     which doesn't change with the OS build.
4. **Scripts:** `~/Work/agents/gpu-port/e-runtime/tools/`: `fwcarve.py`, `fdiff2.py`, `memsig.py`, `regdiff.py`,
   `realdiff.py`, `basefields.py`, `kxref.py`, `kstatus.py`. Outputs in `work/`.

### Global numbers

| Image | Functions (27.0 / 27.2) | Byte-identical after normalization | Changed |
|---|---|---|---|
| Primary GFX fw (`armfw`, a010) | 415 / 415 | 406 | 9: listed below |
| Secondary GFX fw (`armfw1`, a010) | 435 / 434 | 368 | power, CLPC, CRE, PTD, perf counters (InitData policy/status consumers + firmware-global relocation) |
| AGXG17X kext | 4852 / 4888 | 3797 | 996 offset-only (driver C++ objects grew +8/+0x10/+0x30/+0x48), 59/95 structural |

The 9 changed primary functions:

| 27.2 address | What | Runtime-relevant |
|---|---|---|
| 0x0 | image header word | no |
| 0x6780 | `AGFAcceleratorGetStampInfoForCommand` / recovery info: type bitmask gains 0x14 | type 0x14 only |
| 0xf9f4 | `agfaRecoverySkipKickEntry`: type bitmask gains 0x14 | type 0x14 only |
| 0xb560 | scheduling-pause timeout: writes reason 5 to report view 3 +0x48 | new reason value |
| 0xbfc0 | KSM completion / command handler: new case 0x14 | type 0x14 only |
| 0x21548 | interface word `…0339…` → `…4339…` | no (known) |
| 0x33f18 | register allocation only | no |
| 0x389b8, 0x38b8c | RTKit thread PAC signing | no |

All of these are byte-identical 27.0 → 27.2:
- the item-ring command dispatcher (`agfaProcessChannelCommand`, 0x12528, switch over tags 0..0x12);
- the kick-parent dump (0xbd5c);
- the timestamp-queue processor (0x18aec);
- the statistics producer (0x9ff4);
- the PM OOM / parameter-buffer handlers (0x25984, 0x1fd98);
- every UMA context function.

## Structure table

Verdict for 27.0 → 27.2. 27.3b1 is identical to 27.2 on every row; that was checked the same way, see the
27.3 section.

| # | Structure (Aurora) | Size | Verdict | Evidence | Confidence |
|---|---|---|---|---|---|
| 1 | `KickEntry` (fw/kick.rs) | 0x200 stride, 256 slots | unchanged | Consumed by KSM hardware. Firmware readers (parent dump 0xbd5c, completion handler header decode) identical. Kext `writeChannelCommandPointer` and the three `submitBuffer`s change only driver-object offsets and line numbers. | high |
| 2 | `RegisterArray` / `RegisterWrite` / `McacheRange` / bindings | 0x720 / 0xc / 0x10 | unchanged | Hardware-consumed. `mcacheApertureBufferSetup` changes only driver offsets. | high |
| 3 | TA descriptor (type 0, M5; fw maps 0x9a0) | 0x990 written | unchanged | All 122 descriptor-relative offsets the firmware reads (base x26) are identical. Per-type stamp tables (0x8b6/0x8ba) identical. | high (fw-read fields); hardware-read fields n/a |
| 4 | TA descriptor (type 2, G17P; fw maps 0x9e0) | 0x9c0 | unchanged | same | high |
| 5 | 3D/fragment descriptor (type 1) | 0x2240 | unchanged | Same set, incl. 0x2140 tail, 0x2168 key, 0x2198, 0x2209, 0x222f, 0x21c8. Stamp table 0x2150/0x2154. | high |
| 6 | Compute descriptor (type 3; fw maps 0x1040) | 0x1000 prefix / 0x4000 buffer | unchanged | Same set, incl. 0xf0a, 0xf40 tail, 0xf68, 0xfac, 0xff9. Stamp table 0xf50/0xf54. | high |
| 7 | Other kick-handled types 7, 9, 0xd, 0x11 | 0x60/0x88/–/0x28 | unchanged | Sizes and stamp offsets identical. | high |
| 8 | Item-ring commands: `QueueConfig` (0x0f, 0xc0), `KickAnnounce` (0x0e, 0x18), `KickPredecessor` (0x10, 0x12) / M5 `Notification` (24 B), `InitBufferManager` (5, 0x18) | — | unchanged | Dispatcher 0x12528 exact (switch bound 0x12 in both). | high |
| 9 | `PointerBlock` (producer 0x40, recovery target 0x50) | 0x80 | unchanged | Its readers are exact. | high |
| 10 | M5 `QueueRecord` (channel state) | 0x80 | unchanged | Firmware readers exact. The kext `AGFIChannelState` pool code gained one extra pool and its vtable grew, but all channel-state field offsets are uniform driver shifts. | high |
| 11 | Work-ring `WorkSlot` | 0x18 | unchanged | Firmware scheduler exact. | high |
| 12 | Device-control records + opcodes (0x08, 0x0a, 0x13/0x14, 0x29, 0x2e, opening 0x16/0x2a, register 0x20) | 0x40 | unchanged | Firmware control-ring and scheduler code exact. Kext `AGXAcceleratorRing<DeviceControlEntry>` changes only driver offsets. | high |
| 13 | Event ring records (tags 1, 4, 6, 7, 12, 13) | 0x48 | unchanged | Kext `peekNextEntry` and snapshot exact. `drainFirmwareEventRing` switch over types 0..15 has the same 16 case bodies (fingerprinted). The only semantic change is the recovery-reason mapping (row 21). Firmware emitters exact. | high |
| 14 | Firmware-log / trace ring (512 slots) | — | unchanged | Kext trace reader (`AGXSTrace` validator) changes only driver offsets. Firmware log code exact. | high |
| 15 | Statistics ring (types 0x5fff_0000, M5 tag 32) | — | unchanged | Firmware producer 0x9ff4 exact. Kext `recordStatisticsEntryFromFW` changes are all +0x48/+8 driver-object shifts. | high |
| 16 | Stamps, timestamps (`stamp_value`, per-QID timestamp table, view 4) | — | unchanged | Timestamp-queue processor exact. `updateStampWrapCount` exact. | high |
| 17 | Buffer manager `Graph` (`State` 0xc0, `Scene` 0x80, `Control` 0x80, block/page tables) | 0x48000 | unchanged | PM OOM handler and parameter-buffer free-list code exact. Kext `AGXHWParamBufferManager` and `AGXParameterBufferBlockVirtual` exact. `updateAndValidateCookie`, `growImmediately` and `createParameterBufferBlock` change only driver offsets. | high |
| 18 | Free-list `PoolTables` / TVB grow request and reply | — | unchanged | Same handlers. Kext UMA grow engine exact. | high |
| 19 | Context: `Scheduler`, `WorkNode`, `WorkHead`, compute `QueueContextItem` (0x200) | — | unchanged | UMA context functions and scheduler exact. Kext `AGFICmdQueueSchedState` change is a vtable slot (0x350 → 0x358) plus +8 user-args shift. | high |
| 20 | `Qos` | — | unchanged | — | medium-high |
| 21 | Recovery report (report view 3, status B 0x4a9c–0x4ab8) | — | **additive value** | 27.2 firmware writes reason **5** to view3+0x48 on a scheduling-pause timeout, then the halt flag view3+0xc = 1. The reason is copied to status B +0x4aac. Kext maps 5 → "DSF Pause Timeout". 27.3 adds 6 → "Sleep Forced Idle Timeout". | high |
| 22 | Command type **0x14** (UMA sync node) | 0x48 | **new** | New firmware case and stamp-table entries. New kext class `AGXUMASyncNodeCommandDescriptor`. `submitNop`/`prepareNopResources` accept it. | high (existence and fw-read fields) |
| 23 | Microsequence | — | n/a | The G17 path has none (`microseq.rs` is the older-generation path). The item-ring commands replace it. | — |
| 24 | `Variant` rules for 26A428_M5 (pointer layout, qid_floor 0, MCache, fragment_busy, lead_commands = false, registration) | — | unchanged | Every firmware routine behind them is exact. | high |

## Details for implementers

### 1. Command type 0x14: UMA sync node (new in 27.2, optional for Linux)

What the firmware reads, from the primary handler at 0xc6c8 (27.2) and the per-type tables at TEXT 0x48828/0x488d0:

| Offset | Type | Meaning (by analogy with types 0/1/3) |
|---|---|---|
| +0x00 | u32 | tag = 0x14 |
| +0x04 | u64 | GPU VA of the queue's work-state / scheduler record. The firmware maps 0xc8 bytes. Same role as compute +0x10, TA +0x10, 3D +0x20. |
| +0x0c | u32 | UAT context ID (compute has it at +0x0c) |
| +0x10 | u64 | completion key: TA +0x8ce, 3D +0x2168, compute +0xf68 |
| +0x18..+0x23 | — | not read by the firmware handler |
| +0x24 | `completion_tail` | stamp_addresses[2] (+0x24, +0x2c), stamp (+0x34), queue_index (+0x38), ordinal (+0x3c), has_wait (+0x40) |
| +0x44 | u32 | not read |

- The stamp table lists offset +0x34 (stamp) and +0x38 (queue index) for type 0x14. For comparison: TA 0x8b6/0x8ba,
  3D 0x2150/0x2154, compute 0xf50/0xf54, types 7/9 0x40/0x44, 0xd 0x30/0x34, 0x11 0x14/0x18.
- Valid kick-completion types become 0, 1, 2, 3, 7, 9, 0xd, 0x11, **0x14** (bitmask 0x2228f → 0x12228f, bound
  0x11 → 0x14). Types 0x12/0x13 stay invalid.
- The kext's NOP path accepts types {0, 1, 3, 7, 9, **0x14**}. Its NOP flag byte is at command-object offset
  0x191, or 0xe6d for type 0. Those offsets are the kext's own staging object, not firmware layout.
- Linux doesn't need it unless it implements macOS-style UMA (USC private memory) pool sync.

### 2. Recovery reason codes (additive)

Firmware record (primary, 27.2):
- `main_config + 0x26c` = bundle view 3 (`M5_BUNDLE_VIEW_OFFSETS[3]`).
- view3 +0x00 is the state word.
- On a scheduling-pause timeout, view3 +0x48 = reason and view3 +0xc = 1 (halt).
- The recovery-info routine copies them into status B:

| Status B | Contents |
|---|---|
| +0x4a9c | 0 |
| +0x4aa0 | view3 +0x38 |
| +0x4aa4 | 0 |
| +0x4aa8 | stamp word of the faulting command, via the per-type table |
| +0x4aac | **reason** = view3 +0x48 |
| +0x4ab0 | view3 +0x40 |
| +0x4ab8 | slot mask (= Aurora `M5_RECOVERY_SLOT_MASK`) |

The kext's reason → restart-reason mapping:

| fw reason | 27.0 | 27.2 | 27.3b1 |
|---|---|---|---|
| 0 | 2 | 2 | 2 |
| 1 | 2 | unchanged (no store) | unchanged (no store) |
| 2 | 4 | 4 | 4 |
| 3 | 5 | 5 | 5 |
| 4 | 6 | 6 | 6 |
| 5 | (2) | **7 "DSF Pause Timeout"** | 7 |
| 6 | (2) | (2) | **8 "Sleep Forced Idle Timeout"** |

- Aurora's M5 `fault_sources` returns before reading a reason. Its G17P `abi::recovery::REASON` is view3 +0x4c,
  not +0x48.
- Treat 5 and 6 as firmware-initiated recovery causes. No layout change.
- 27.3 also clears view3 +0x20..+0x4f (memset 0x30) when it builds the recovery info.

### 3. 27.3-only HW-data change (for the InitData owner)

Kext HW-data stores, in the same function in all three builds:

| Build | Stores (offsets) | HW data |
|---|---|---|
| 27.0 | 0x2728, 0x272c, 0x2730, 0x2738, 0x27f0, 0x2804, 0x2810 | baseline |
| 27.2 | 0x2728, 0x272c, 0x2730, 0x2738, 0x27f0, 0x2804, 0x2810 | same as 27.0 |
| 27.3b1 | 0x272c, 0x2730, 0x273c, 0x27d8, 0x27e0, 0x27f4, 0x2808 | +4 from 0x2720 |

Firmware agrees:
- 27.0 → 27.2 has no HW-data offset change in either image.
- 27.2 → 27.3 moves every HW-data read ≥ 0x2720 by +4. Examples: 0x27f0 → 0x27f4, 0x2836 → 0x283a,
  0x2842 → 0x2846; the u64 at 0x27d4 → 0x27d8; the 4×0x20 table at 0x273c → 0x2740.
- 27.3 adds a read of the new u32 at 0x2720 in the forced-idle path ("GPU did not reach forced idle within %ums").
- The 27.3 kext adds the string `gpu-fa-idle-tolerance`, the likely source of that value (×1000, saturating).

Consequences:
- The version word is the same in 27.2 and 27.3. ANALYSIS-27.3 §1.3's "27.2 and 27.3 are identical on every point"
  is wrong for HW data.
- The policy (0x126b0 → 0x12728) and status-config (0x780 → 0x790) changes do happen in 27.0 → 27.2 and are
  unchanged in 27.3.

## What the driver has to change

1. **Runtime submission, rings, events, buffer manager: nothing.** `g17/fw/{kick,render,compute,queue,channels,buffer,
   freelist,context,qos}.rs` and `g17/fw/m5/{render*,compute,queue,pool*}.rs` are valid for 27.2 and 27.3b1.
2. **Optional:** in the M5 recovery path, read the reason from status B +0x4aac (or view3 +0x48). Name 5 "DSF pause
   timeout" and 6 "sleep forced-idle timeout". Keep unknown values non-fatal.
3. **Optional:** add `CommandTag` 0x14 (UMA sync node, 0x48 B) to any validator that rejects unknown firmware
   command tags it reads back, e.g. completion attribution. Aurora never emits it.
4. **Required, outside this scope:**
   - a separate 27.3 HW-data band (u32 at 0x2720, tail +4), selected by `fwid` build identity;
   - a 27.2 profile that keeps the 27.0 HW-data layout with the 27.2 policy/status changes;
   - a `Build` entry per image, since the shared version word can't select it.

## Confidence notes

- **Firmware-read fields:** high. Both images are diffed exhaustively. Every changed primary function is accounted
  for above.
- **Hardware-read fields** (register-array contents, kick-entry bits the KSM consumes): not firmware-versioned. Same
  silicon, so unchanged by construction.
- **Not verified:** userspace-only conventions (AGXMetal fills the descriptor bodies). Those affect what macOS writes,
  not what the firmware accepts.
- **Secondary-image changes:** attributed to InitData consumers (policy 0x49e4 → 0x49fc, 0x4ba4 → 0x4bd4, policy size
  low bits 0x26b0 → 0x2728, status-config 0x5e0–0x668 re-layout) and to relocation of firmware globals. None
  touches a runtime ring or command format.
