drm/asahi: M5: InitData for the macOS 27.2 and 27.3 firmware (G17S bring-up on J716s)

## What this is

Stacked on #1012 (base: `funkzy/t6050-gpu-on-integration` at b1615e3fca90), so the diff shows only these 13 commits. It lets the M5 GPU driver build the InitData graph that the macOS 27.2 (26B123) and 27.3 beta 1 (26C5035r) GPU firmware checks, and runs the M5 Pro (G17S) on bare metal with J716s tables. On a J716s with 27.3 beta 1 firmware, both InitData are acknowledged and the DRM device registers.

## The problem

- #1012 builds only the 26A428 (27.0) graph. A 27.2+ firmware checks a different root version word and larger policy and status-config objects, so it would reject the graph ("Host and FW Interface is mismatched") or misread it.
- The M5 Pro had no bare-metal tables (`M5NoBareMetalTables`) and admitted no firmware image (`Firmware::Identified(&[])`).
- Our J716s needs the 27.3 boot firmware: an older stub leaves Linux on one CPU.

## Method

Every offset and constant comes from Apple's binaries, and each commit names the instruction or table address it was read from:
- the AGXG17X kext in the kernelcache of the public Mac17,8 27.0 (26A428) and 27.2 (26B123) IPSWs, and of the 27.3 beta 1 (26C5035r) restore bundle: the root version word (movk sequences), the u64[24] allocation size table, and the kext's stores into each object, compared build to build;
- the GPU firmware (`armfw_g17x.im4p`, `armfw1_g17x.im4p`, variant a010): its accesses to the same objects, compared function by function;
- the J716s ADT for the board tables and mailboxes.

Scripts check each claim against those inputs and against the driver source, compiled with rustc outside the kernel (see Checks). They print only offsets, constants and digests.

## Layout changes

| Item | 27.0 (26A428) | 27.2 (26B123) | 27.3 beta 1 (26C5035r) |
|---|---|---|---|
| root+0 version word | 0x0c8e_0339_8728_04c0 | 0x0c8e_4339_8728_04c0 (bit 46) | as 27.2 |
| Power policy (size table entry 4) | 0x126b0 | 0x12728: 5 inserts (2 accumulators at 0x4910, a fourth threshold at 0x492c, residency table 37 -> 40 entries); state/AON PTD pointers 0x8254/0x11a1c -> 0x8284/0x11a4c | as 27.2 |
| Status config (entry 13) | 0x780 | 0x790: two controller blocks 0x5c -> 0x64 bytes (override slot +0x28, value +0x58); tail, link word and submission history +0x10 | as 27.2 |
| Shared cluster | 0x34000 | everything after the policy +0x80; same total | as 27.2 |
| Private cluster | 0x178000 | everything after the status config +0x40; same total | as 27.2 |
| HW data | 340 stores | as 27.0 | u32 at 0x2720 (forced-idle timeout, ms), 0x2720..0x284c +4 |
| Controller words (core types 0x18/0x19) | 0x49fc = 500 | 0x492c = 5000, 0x4a14 = 1600 | as 27.2 |

27.2 and 27.3 share the version word, so only the firmware identity (fwid) tells them apart. That is why there are two variants, `V26B123_M5` and `V26C5035_M5`. The runtime structures (submission, rings, events, buffer manager) did not change from 27.0 to 27.2 or 27.3. 27.2 adds a command type (0x14, UMA sync node, never emitted by the driver) and recovery reason 5, and 27.3 adds reason 6. Neither is used here.

## Commits

1. Refuse an M5 firmware whose InitData layouts the graph can't build (`Variant::m5_layouts`, `V26B123_M5`).
2. Identify the M5 Pro's G17S builds: 27.3 beta 1, 27.2 and 27.0 digests, plus a fwid KUnit test.
3. J716s board table and the M5 Max/Ultra bare-metal profile for the M5 Pro; `M5NoBareMetalTables` goes.
4. and 5. `apple,t6050-native-ascwrap-v6`: the GPU mailboxes at the native wrapper/VBAR addresses m1n1 leaves in place.
6. The 26B123 graph: `M5Layout`, version word, shared and private cluster offsets.
7. The 26C5035r HW data band and the 0x2720 word.
8. and 9. The power-policy map and in-place relayout.
10. to 12. The status-config map, chosen by the root profile.
13. Wiring: policy and status-config layouts from the firmware build, compile-time size checks. Gpu::new() admits 27.2+ only here, so no earlier commit hands a firmware a partly converted graph.

## 27.0 is unchanged

For 26A428 builds (the only ones the M5 Max and M5 Ultra identify), every map is the identity, and the graph is byte-identical to #1012's:
- `check_layout.py` compiles `g17/fw/m5/initdata.rs` before and after with rustc. It compares the HW data of every board (J714, J716C, J716S, J775D), the private cluster, the bundle policy, both roots and both main configs.
- `verify_policy.py` checks the 26A428 policy byte for byte after the relayout, for J714, J716C and J775D.
- `rustcheck.py` checks that the 26A428 status config (0x780 bytes) is the same as `write_relocated_words()` with `COMMON26_STATUS_CONFIG_BANDS`.

## Hardware result (J716s, 27.3 beta 1 firmware)

Kernel: our J716s tree (integration/aurora plus the T6050 board PRs) with #1012 merged and this series on top. The GPU code that ran is these 13 commits. The only later change is the fwid KUnit test that commit 7 now updates. The device tree describes the GPU, and m1n1 hands the GPU over (both out of tree). One boot, unattended:

```
aurora 2300000000.gpu: GPU firmware build: 26C5035r for T6050 G17S, primary then secondary
aurora 2300000000.gpu: GPU firmware: 27.3 (26C5035r), G17S
aurora 2300000000.gpu: RTKit: Initializing (protocol version 12)
aurora 2300000000.gpu: RTKit: Initializing (protocol version 12)
aurora 2300000000.gpu: M5 firmware graph ready: private +0x178000, shared +0x34000
aurora 2300000000.gpu: M5 primary initdata acknowledged
aurora 2300000000.gpu: M5 secondary initdata acknowledged
aurora 2300000000.gpu: M5 firmware opening records retired
[drm] Initialized aurora 1.0.0 for 2300000000.gpu on minor 1
```

- Both GPU mailboxes bound, `/dev/dri/renderD128` present, power domains gfx/afr/gpx on, no deferred devices.
- No coprocessor crash, SError, DART or UAT fault, or RCU stall in the 2+ minutes the system ran.
- No userspace work was submitted.

## What is inferred, not measured

- **J716s board (commit 3), taken from J714:**
  - core revision 4;
  - the register-window slots the ADT does not describe (4, 14 and the PTD block);
  - the 2 MiB minimum parameter buffer and 4 MiB render blocks in a 4 GiB inventory;
  - the fan curve start;
  - `os_version` [27,3,0].
- **Bare-metal profile, inferred from code identity:** `secondary_root_offset` 0x40000, crash buffers in `fw-data`, and the Ultra's UAT quirks. The G17S GXF code is the G17C image's except for one call's displacement. The GXF section grew from 0x4f40 to 0x50a0 bytes in 27.2, so the UAT quirks are unverified on 27.2+ for every board. The hardware run above exercised initialization only.
- **J716s `controller_defaults`/`calibration`: None.** No controller configuration has been measured on a J716s part, so the firmware keeps its own power budget. The 27.2 controller words (0x492c, 0x4a14) are not written on J716s. That matches what #1012 does for 27.0.
- **The 27.3 word at HW data 0x2720 = 5000:** IOGPU's `waitForGPUTimeoutSeconds` default (5) times 1000. This comes from the kext's defaults, not read from a running macOS. The 27.3 kext also reads a new `gpu-fa-idle-tolerance` property, which is not modelled.
- **G17D (J775D) controller words on 26B123** (2500/800/1100/0/1600) are read from the kext only.

## Not covered

- **27.2+ identity entries for the M5 Max and M5 Ultra.** Measured the same way, and offered if you want them in this PR (fwid digests):
  - 27.2 G17C (a000): `6648ece7e8c6b7b82844368f0e075a2180a08ca35feed0b6e3f548710d4ddb81`
  - 27.2 G17D (a020): `54c528199710711b27119bd06db016ecee4232ff1a0b6ed8025a6146646e3b03`
  - 27.3 beta 1 G17C (a000): `543f7cf9bda372d9bc24b34013b05854409eced9f8019334f509ce6472c9e912`
  - 27.3 beta 1 G17D (a020): `f33b3f64960973d73942abf5794ec9d765313f1cef63bd38537b06d2f8c61f36`
  - Entropy and boot-filled ranges as G17S, with a020's secondary at 0xa192c/0xa11ec.
- **J714s (14-inch M5 Pro) voltages.** It reports the same ID variant and takes the J716s tables, but its voltage bins have not been read.
- **The 27.0 stub on G17S.** A 27.0 (26A428) stub on the M5 Pro would now run the 26A428 graph. It has never been booted.
- **Not exercised yet:** the 27.2 firmware on hardware, rendering from userspace, the forced-idle sleep path, and the new recovery reasons.
- **Builds and tests:**
  - The kernel was built at the tip only (defconfig-based config with `DRM_ASAHI=y`). It gave no warnings beyond the existing ones.
  - Intermediate commits are type-checked for `g17/fw/m5/initdata.rs` only.
  - KUnit not run; `dtbs_check` not run (no dt-schema here).

## Checks

The scripts and their outputs are in [rolotrealanis98/m5pro-linux `contrib/validated/aurora/prs/gpu-27.2/checks/`](https://github.com/rolotrealanis98/m5pro-linux/tree/main/contrib/validated/aurora/prs/gpu-27.2/checks). The README there lists the inputs. All pass on this branch's head:

| Script | What it checks | Needs |
|---|---|---|
| `check_layout.py <tree> <5th commit>` | 26A428 byte identity; 27.2+ sizes and offsets; 26C5035r HW data = 26B123 kext stores relocated + 5000 | tree, rustc |
| `rustcheck.py <initdata.rs> <dir>` | 26A428 status config byte identity; 26B123 words | tree, rustc |
| `verify_policy.py <initdata.rs> <dir>` | policy bands vs all kext stores (363/364) and GFX1 accesses (209/219); driver relayout vs an independent relocation | store lists (in the repo), GFX1 disassembly |
| `verify_statuscfg.py --kext0/--kext2/--fw0/--fw2 ...` | every status-config store and firmware read, 27.0 -> 27.2 and 27.0 -> 27.3 | kext and armfw1 disassemblies |
| `check_fwid.py <hw/t6050.rs>` | the three G17S digests; reproduces #1012's G17C and G17D 26A428 pins | firmware images |
| `check_board.py`, `check_mailbox.py` | J716s tables and mailbox addresses vs the ADT | ADT, m1n1 proxyclient |

- The in-tree host tests that read the touched files pass on this branch: `g17-firmware-selection-tests.py`, and `g17-telemetry-integration-tests.py` with all 10 mutations killed. The asahi-m4 suite gives the same results as on #1012's head; this macOS host can't build 6 of its tests.
- `checkpatch.pl --strict`: 0 errors, 0 warnings, 0 checks on all 13 patches.
- rustfmt (the tree's `.rustfmt.toml`): 13 added lines are not rustfmt-clean, all in `g17/fw/m5/initdata.rs` (5) and `g17/initdata/m5.rs` (8). They follow the style around them. Neither file was rustfmt-clean before, and the series lowers rustfmt's change count in both (329 -> 317 and 73 -> 71).

## Questions

1. **Base:** is stacking on `funkzy/t6050-gpu-on-integration` right? Or would you rather fold this into #1012, or retarget it to integration/aurora once #1012 merges?
2. **27.3 beta 1:** can a beta build's identity and HW-data band (26C5035r) stay in-tree? Or should only 27.2 stay until 27.3 ships? The J716s needs the 27.3 boot firmware either way.
3. **M5 Max/Ultra 27.2+:** should the four digests above go in now, untested on hardware, with their boards on `V26B123_M5`/`V26C5035_M5`? Or should they wait until someone boots them?
4. **Two 27.0 differences we found and left as they are:**
   - The status-config words `COMMON26_STATUS_CONFIG_BANDS` writes from 0x5a4 sit 0x4c below where the 27.0 M5 kext stores them (0x5f0..0x604). Those bands look measured on G18G's 0x6d0-byte object.
   - On J716C (variant 0x19), the kext writes 2000 at policy 0x4918, where the driver's defaults write 3000.
   - Are these intended, or should they get a separate fix on #1012?
5. **Mailboxes:** is a separate compatible (`apple,t6050-native-ascwrap-v6`) the right way to describe the native layout? Or should the existing T6050 provider accept either layout?
6. **Tooling:** `check_layout.py` and `rustcheck.py` need only the tree and rustc. Would you like them as `tools/asahi` host tests in `run-host-tests.py`, with controls? The others need Apple's kernelcache, firmware and an ADT, so they would stay out of tree.
