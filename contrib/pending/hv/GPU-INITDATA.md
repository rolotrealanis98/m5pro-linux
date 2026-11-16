# GPU InitData of macOS 27.3 under the hypervisor (for aurora-silicon/linux#1173)

Prepared 2026-11-16 on the Studio only; nothing has run on the MacBook. Attended request:
`/Volumes/m5pro/bench/requests/hv-gpu-initdata-1.md` (private bench; hashes, ssh steps, abort table).

## Why

#1173 ("drm/asahi: M5: InitData for the macOS 27.2 and 27.3 firmware", head d8ca53c82e52) marks 11 items on 12
comment lines "not yet confirmed from captured InitData". The maintainers want those confirmed from a running
system and published as a redacted field summary, not taken from the kext or firmware code. This captures the graph
macOS 27.3 beta 1 (26C5035r) itself builds for the G17S firmware.

| item | file:line (d8ca53c82e52) | PR value | how the capture tests it |
|---|---|---|---|
| `M5_26B123_STATUS_CONFIG_BANDS` | g17/fw/m5/initdata.rs:1488 | 0x780 -> 0x790, blocks 0x5c -> 0x64, link 0x784/0x788 | pointer at 0x788 (not 0x778), block word pattern at stride 0x64 |
| `M5_26B123_STATUS_CONFIG_INSERTED` | :1503 | 0x5dc=0, 0x60c=5000, 0x640=0, 0x670=0 | the four words |
| `M5_26B123_INITDATA_VERSION_WORD` | :1743 | 0x0c8e_4339_8728_04c0 | root+0 of both roots |
| `ABI_ALLOCATION_SIZES_26B123_M5` | :1756 | policy 0x12728, status config 0x790 | distances between the objects (13 spacings, 8 of which differ between 27.0 and 27.2+ if macOS packs like the driver), last nonzero byte |
| `M5_26C5035_HW_DATA_BANDS` | :1775 | +4 from 0x2720 | 7 anchors: chip id, 0x96 at 0x271c, completion table at 0x2740, QoS and kick-shared pointers at 0x27d8/0x27e0, the two 1s at 0x2846/0x284a, zero tail |
| `M5_26C5035_HW_FORCED_IDLE_TIMEOUT` | :1783 | u32 at 0x2720 | position and value (the meaning is not observable from a dump) |
| `M5_GPU_TIMEOUT_SECONDS` | :1786-1787 | 5 -> 5000 at 0x2720 | the value |
| `M5_26B123_POLICY_BANDS` | :2280 | +0x10..+0x78 from 0x4910 | state/AON pointers at 0x8284/0x11a4c (not 0x8254/0x11a1c), 40-entry table at 0x12320 |
| `M5_26B123_POLICY_CONTROLLER_WORDS` | :2299 | 0x492c=5000, 0x4a14=1600 | the two words (what macOS writes on a J716s) |
| `M5_26B123_POLICY_CONTROLLER_WORDS_G17D` | :2306 | G17D words | not observable on a G17S part |
| `M5Layouts` (V26C5035) | g17/fw/variant.rs:40 | the 27.3 beta 1 graph | aggregate, plus the firmware's acknowledgement of macOS's graph |

## Does rung iii-a (no SSD) reach InitData?

Likely yes; not yet observed.
- The GPU stack is in the Boot Kernel Collection the guest runs: `com.apple.AGXG17X`,
  `com.apple.AGXFirmwareKextG17XRTBuddy`, `com.apple.AGXFirmwareKextRTBuddy64` and `com.apple.iokit.IOGPUFamily` are
  fileset entries of the 26C5035r BootKC (`tools/kc-entries.py`), at the same unslid addresses the native
  `kextstat` shows.
- Their personalities match hardware nubs only: `AGXAcceleratorG17X` on `IONameMatch gpu,t6050`
  (`AppleARMIODevice`), `AGXFirmwareKextG17RTBuddy` on `RTBuddyService` role GFX / GFX1. Nothing in them waits for a
  root-volume resource (`tools/kc-personalities.py`, Info.plist metadata only).
- The no-SSD guest of 2026-11-08 16:12 logged `RTBuddy(GFX1): start` and `RTBuddy(GFX): start` before root mount, and
  the single-core PTD capture of 2026-11-09 (`captures/DECODE-PTD-20261109.md`, request #11) shows macOS turning on the
  AGX power domain.
- No run has traced the GPU mailbox, so the INITDATA word itself has not been seen. If macOS sends it only after root
  mount, the session shows that directly and the next step is rung iii-b (an owner decision, PLAN-27.3.md section 0).

## Method

- Recipe of the working 2026-11-09 captures: single-core guest (`cpus=1`), ANS stripped, tracers installed from
  SPTM's first AMCC read (`hv27-trace-late.py`, then this module chained onto its hook), the 2026-11-09 client
  patch (CLPC `S3_7_C15_C{11,13,15}` NOP, TLBI barriers, BRK guard; it was never committed, recovered from the
  harvest bundle `hv27-m1n1-uncommitted.patch` and applied on 63e6053c).
- `tools/hv27-gpu-initdata.py` traces only the mailbox page of `/arm-io/gfx-asc` and `/arm-io/gfx1-asc`
  (reg0 + 0x8000, SYNC, the same mode the DCP RPC capture used with 0 errors). At the host's store of the
  firmware-endpoint word `0x81 << 48 | root` (the message #1173's driver sends), the guest is stopped and the word has
  not reached the firmware, so the module reads the root and what it reaches: main config, HW data, bundle views,
  region A/C, status A/B, the secondary's status config and extra 1, the power policy (secondary main config +0x481).
  GPU VAs go through the UAT (TTBAT = ADT `sgx` `gpu-region-base`, context 0: TTBR by VA bit 42, levels 41:36 /
  35:25 / 24:14), all reads in guest memory. A second snapshot at the firmware's acknowledgement shows which words the
  firmware writes. Raw objects are the primary artifact.
- `tools/initdata-compare.py` reads the expectations from the PR source, compares, and writes a private JSON and a
  public markdown summary that names offsets, sizes and the values at the PR's sites only. Pointers appear as
  "pointer"/"null"; sizes come from distances, never addresses. A redaction scan (address-like hex, UUID, hash run,
  MAC, serial-like token, local path) refuses to write the public file on any hit.

## Dry run (offline, 2026-11-16)

- `run-hv27-gpu.sh check`: payload 3ea65595 (`v2.0.0-132-g63e6053c`), guest files, proxyclient imports and the
  assembler (clang 23 here), all modules compile. `run_guest.py` with the full argument list gets as far as opening
  the serial port.
- `tools/dryrun-synthetic.py` (real J716s ADT, real m1n1 `DictRangeMap`/`TraceMode`, mock hv, synthetic graph mapped
  through synthetic UAT tables at the ADT's TTBAT, the AMCC hook fired, an RTKit bring-up replayed through the SYNC
  callbacks): PR layout -> all 10 observable items CONFIRMED/CONSISTENT, G17D not observable; 27.0 layout (negative
  control) -> all CONTRADICTED. 0 handler errors; redaction scan passed on both summaries.
- Not tested offline: the module on hardware (SYNC on the GPU pages, the UAT format of a live 27.3 system), and
  whether the single-core guest reaches GPU init before it stalls elsewhere.

## Open risks

1. InitData may come only after root mount (then iii-b).
2. The single-core guest stalled in AppleCentauriManager's loop on 2026-11-09; if GPU init comes after that, it never
   arrives here. Multi-core traced guests deadlocked on the first traced access, so going multi-core is not an option
   with this tracer.
3. SYNC on the GPU mailbox stalls the guest per access; a firmware handshake timeout is possible (the DCP one survived).
4. The live UAT may not match the M1-M3 TTBAT layout; then the root does not translate, the module saves the
   TTBAT/handoff pages and the walk is redone offline (or forced with `HV27_GPU_TTB1`).
5. The size check relies on macOS packing objects like the driver; if it does not, those spacings read "not
   observable" and only the extents remain.
