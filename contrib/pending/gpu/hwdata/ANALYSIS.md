# M5 Pro (J716s) GPU: what Aurora's M5 driver needs, what is missing, the PMP, and a plan

2026-11-07. Studio-only research: no ssh, no builds, no pushes. Read: aurora-silicon/linux#1012 at its
current head, the J716s ADT, the macOS 27.3 scan, the 27.3 GPU/PMP firmware headers and strings,
edimoldovan's notes, our earlier GPU/PMP reports.

## Verdict

1. A probe attempt this month is realistic. It would read the ID registers, map the regions and measure
   the firmware, then refuse cleanly. A running GPU this month is unlikely.
2. The blocker is the firmware build, not the hwdata. #1012 supports only the 27.0 (26A428) M5 firmware.
   It writes interface word 0x0c8e_0339_8728_04c0. Our 27.3 stub loads G17S firmware whose init code
   compares root+0 with 0x0c8e_4339_8728_04c0. Nobody has published whether anything else changed.
3. The hwdata already exists. The J714 (M5 Pro) board table is in #1012. J716s matches it except for
   its own voltage bins, which come from our ADT. The "bare-metal tables" the Pro lacks are the Max's
   bare-metal profile plus the identity of the G17S firmware: about 40 lines, drafted here.
4. The PMP is not a GPU prerequisite in #1012: no G17 code talks to it. On T6050, iBoot loads the PMP
   but does not start it. Aurora's t6050/pmp driver starts it from the host, so it is not a
   secure-boot-only coprocessor.
5. Missing on our side:
   - an m1n1 T6050 GPU handoff (six reserved regions, fw-text and fw-data built from segment-ranges)
   - GPU, mailbox and PMGR DT nodes
   - a mailbox role table for the real physical addresses
   - a Rust build: #1012 merges onto j716s-series with one overlapping file

## 0. Sources and refs used below

- #1012 is open, head `b1615e3fca90` (2026-11-06, 136 commits on integration/aurora `33bec4016c46`).
  I fetched it read-only into `/Volumes/linux-cs/linux` as `refs/remotes/aurora-ro/pr1012-latest`, with
  `aurora-ro/integration` and `aurora-ro/pr945-latest`.
  The old local ref `refs/dcp-aurora/pr1012` (`d078ca18`) is a pre-rebase posting. It still refuses
  the M5 Max ("M5 Pro/Max bare-metal ...").
  Since then #1056 (erikwb, commit `0625c9f2f97d`) runs the M5 Max (J716c) on bare metal. The message
  now reads "M5 Pro bare-metal GPU tables not yet available".
- Paths `asahi/...` = `drivers/gpu/drm/asahi/...` in that ref. Line numbers are for that tree.
- `/Volumes/linux-cs/wt-series` (j716s-series, `4f630b11`) is based on the same `33bec4016c46`. It has
  58 commits on top, and none touch `drivers/gpu/drm/asahi`, `drivers/soc/apple/mailbox.c` or `rust/`.
  The only file both trees change is `drivers/hwmon/macsmc-hwmon.c`.

## 1. What #1012's driver needs per SoC/GPU variant

### 1.1 Probe and selection
- OF match: `gpu,t6050` and `apple,agx-g17s` both go to `ProbeConfig::G17M5` (`asahi/driver.rs:175-182`).
- `probe_g17_m5` (`asahi/driver.rs:406-422`) maps `sgx` (`asahi/regs.rs:585`) and reads the ID
  registers (`asahi/regs.rs:719`). It then picks the Config by family/variant/dies (`asahi/hw/t6050.rs:222`).
  If the profile is `M5NoBareMetalTables` it refuses with the message above.
  The M5 Pro `CONFIG` (`asahi/hw/t6050.rs:18-58`) still has that profile. It also has
  `secondary_root_offset: None`, `CrashBuffers::Fixed(J714 VAs)`, `UatQuirks::DEFAULT` and
  `Firmware::Identified(&[])`.
- `Gpu::new` (`asahi/g17/mod.rs:1451`):
  1. Identifies the firmware first: `firmware_variant` (`:1668`) → `identify_image` (`:1701`) →
     `fwid::identify` (`asahi/fwid.rs:290`). This only copies fw-text and makes no GPU writes.
  2. Checks the ID registers against `identity`.
  3. Checks the board's cluster/slot counts (`:1491`).
  On M5 the board's perf table, not DT OPPs, gives the max clock (`:1512`).

### 1.2 Per-variant tables (all compile-time, no DT input)
- `hw/t6050.rs` `Config` (`asahi/g17/mod.rs:203`):
  - identity
  - UAT ias/oas 42
  - `secondary_root_offset`
  - `crash_buffers` (`:271`)
  - `profile` (`:167`)
  - `uat_quirks` (`asahi/mmu.rs:208-248`)
  - `firmware` (build identity)
  - `core_layout` (operand-state / deflake buffers per cluster count)
  - `m5` → the board table.
- Board table `asahi/g17/fw/m5/initdata.rs:1757` (`Board`). Instances: J714 `:1802`, J716C `:1824`,
  J775D `:1851`. Fields:
  - clusters and core slots
  - core type/revision written to HW data 0x10d4/0x10d8
  - 14 main perf states × up to 8 voltage tables, core and SRAM (`:1940`)
  - 14 aux (AFR/CS) states (`:1476`)
  - relative-frequency curve (computed from the perf states)
  - the three AON-PTD records (`:1609`)
  - the register-window map (`:2026`, 30 slots for J714)
  - min parameter buffer
  - render pool geometry
  - leakage calibration words + controller defaults
  - idle standby
  - MCC mask
  - topology words
  - fan curve start
  - G17D encodings flag
  The HW data / policy blob is assembled from these in `encode_m5_hw_data` (`:2232-2316`). Its layout
  is the PR's "26A428/25G83" graph: `ABI_ALLOCATION_SIZES_26A428_M5` (`:1658`), `M5_ROOT_SIZE` 0xc8
  (`:1656`), version word (`:1654`).
- This replaces what edimoldovan calls the hwdata gap: his G17P-derived HwData +0x128 insertion
  (`GPU-g17c-hwdata-gap.md`). #1012 relocates the HW data with `COMMON26_HW_DATA_BANDS` plus an 8-byte
  insert at 0x267c (`initdata.rs:1391-1409`, `:1752`).

### 1.3 Firmware the driver expects
- Only 27.0 builds: the Max `Build` "27.0 (26A428), G17C" (`asahi/hw/t6050.rs:96-118`, TEXT 0xa4000,
  DATA 0x184000) and the Ultra "26A428 for T6050" (`:174-199`, TEXT 0xa8000).
- Identity = SHA-256 of fw-text with the GKTS/ECAP entropy bytes and the boot-filled ranges zeroed,
  plus sizes (`asahi/fwid.rs:1-12, 100-148`).
- The root version word is 0x0c8e_0339_8728_04c0 for every T6050 board
  (`initdata.rs:1654`, used via `RootProfile::J714G17S26A428` at `asahi/g17/initdata/m5.rs:210`).
- Our firmware is different (12-firmware.txt and the im4p headers):
  - bundle 27.3 26C5035r, iBoot `mBoot-20457.60.65.0.1`, both images `RTKit ... 3514.60.8`
  - sha256 `ae7f35b1…` (armfw_g17x) and `da8ff3fb…` (armfw1_g17x), matching the bundle
  - each im4p is an `rkosftab` with three variants: a010 = g17s, a000 = g17c, a020 = g17d (from the
    "FW Build variant:" strings at file 0x4ed8f / 0x16c8af / 0x28a3cf)
  - g17s layout (Mach-O headers, `fw-layout.py`): TEXT 0x50000 + 0x54000 = 0xa4000, DATA 0x184000
    (same sizes as the Max). Entropy records `[[0x49eac,0x49f8f],[0x9d92c,0x9da0f]]`. Boot-filled
    sections `_rtk_tunables` / `_rtk_patchbay` at 0x4976c/0x49eac and 0x9d1ec/0x9d92c.
  - The g17d variant has the same structure as the PR's 26A428 Ultra entries, shifted. That
    cross-checks the method.
  - The init path compares `root+0` with 0x0c8e_4339_8728_04c0: movz/movk/cmp at armfw_g17x file
    0x25509-0x25521. The same immediates appear in all six variant images, and no 0x0339 immediate
    appears anywhere.
  - So #1012 as published would fail the firmware identity (refused before any write). With a
    digest added, it would fail the interface gate ("Host and FW Interface is mismatched").
  - edimoldovan saw 0x4339 on J714c with mBoot 41.3 and 60.65 (`GPU.md:52-55`, `:490`). The change
    therefore predates 27.3: it lies between 26A428 and the 41.x firmware.

### 1.4 PMP dependency
- None in the G17 path. Nothing under `asahi/g17`, `asahi/driver.rs`, `asahi/regs.rs` or `asahi/mmu.rs`
  references the PMP.
- `apple_pmp_set_device_power()` (`drivers/soc/apple/pmp-export.c:59-97`) has two callers, both in
  the G15 (M3) glue: `asahi/g15/glue.c:179/195`, device 5.
- It rejects `device_id > 15` (`pmp-export.c:64`). J716s GFX has PMGR id1 16 (§3), so joshuaswarren's
  point holds only for code that would route T6050 GFX power through it. #1012 does not.
- `DRM_ASAHI` selects `APPLE_PMP_REPORT` (Kconfig).
- #1012 has no T6050 PMP driver: the `pmp.rs` OF table lists t8132/t8140/t8142/t6041/t6000.

### 1.5 DT nodes
- GPU node (pattern of `t604x-j614-j616.dtsi:100-150, 4520-4533`):
  - `compatible = "apple,agx-g17s"`
  - `reg-names = "sgx"`, at least 16 MiB (`SGX_SIZE`, `asahi/regs.rs:41`)
  - `mboxes` = two ASCWrap v6 mailboxes, roles GFX and GFX1 (`asahi/regs.rs:230-260`)
  - `power-domains = <&ps_gfx>`
  - six memory regions by name:
    - `ttbs`, `handoff` (`asahi/mmu.rs:4022-4023`)
    - `pagetables`, `l2-pagetables` (`:4085-4098`, no-map, the firmware builds its tables there)
    - `fw-text`, `fw-data` (`asahi/g17/mod.rs:1703-1704`; `asahi/g17/data_segment.rs:37`)
  - optional: `apple,firmware-version`, `apple,leakage-calibration-words`
    (`asahi/g17/initdata/m5.rs:185`), `apple,idle-off-delay-ms`. No OPP table is needed on M5.
- Mailbox nodes: `wrapper` (0x88000) + `iop-vbar` (0x8), `apple,firmware-role`. The provider checks
  the addresses against a per-SoC role table (`drivers/soc/apple/mailbox.c:1340-1344`).
  - The T6050 tables (`:1641-1657`) expect GFX at 0x8_0260_0000 / 0x8_0205_0000 (T8140 base
    + 0x3_8000_0000; `:63-69`). The J716s ADT has 0x23_0260_0000 / 0x23_0205_0000.
  - The comment says "Aura grants these complete wrapper/VBAR windows in the retained GPU aperture",
    so these are the addresses as Linux sees them under Aurora's internal loader.
  - #1056 lists "The T6050 GPU mailbox ... filed separately" as a dependency (not public).
  - On our m1n1 boot the mailboxes need a role table with native addresses.
- No DART: the GPU uses its own UAT. No `apple,pmp`.
- Power: PMGR ps group 3 at 0x23_00e8_0000 (GPX +0x0, AFR +0x100, CS +0x108, GFX +0x110). None of
  these are in our T6050 DTs today: 17 power controllers in die0, none for the GPU.
- Draft: `t6050-j716s-gpu-draft.dtsi`.

### 1.6 What the loader must hand off
#1056: "The boot loader fills in the GPU's reservations and its leakage calibration words, and accepts
`apple,agx-g17s` (aura-internal)". On J716s:
- `ttbs` ← sgx `gpu-region` (0x4000), `pagetables` ← `gfx-shared-region` (0x80000), `l2-pagetables` ←
  `gfx-shared-l2-region` (0x4000), `handoff` ← `gfx-handoff` (0x4000). In the 41.2 capture all sit at
  0x10b_fff2_0000..0x10b_fffa_c000, above Linux RAM.
- `fw-text`: from the start of the gfx-asc TEXT segment to the end of the gfx1-asc TEXT segment.
  `fw-data`: from the start of the gfx-asc DATA segment to the end of the gfx1-asc DATA_SHARED_RO
  segment. Both come from `segment-ranges` (32-byte entries {phys, va, phys, size u32, flags u32}).
  - In the 41.2 capture: TEXT 0x100_00ff_0000+0x50000 then 0x100_0104_0000+0x54000; DATA
    0x100_0251_8000 .. 0x100_0269_c000. Both contiguous.
  - In the macOS 27.3 scan gfx1-data-base is 0x100_025e_8000 and its RO at 0x100_0269_c000, 0x8000
    higher than in the 41.2 capture. m1n1 must read these per boot and check contiguity.
- The firmware is already loaded: iBoot loads GFX/GFX1 (`IsLoadedByiBoot`, nub `pre-loaded = 1`). The
  driver only measures it. The page tables are the firmware's own, published at boot
  (`M5PublishedRoots`): the driver adopts them; m1n1 builds none.
- No current m1n1 does this for T6050: ours (`src/kboot_gpu.c:504-527`, "unsupported chip"), upstream,
  aurora-silicon/m1n1 main/aurora-wip, omacom/edimoldovan default branches.
- Templates:
  - aurora-wip `src/kboot_gpu.c` `g15_get_fw_segs*` (~1505-1900), which builds fw-text/fw-data from
    segment-ranges
  - `dt_set_region()` for the four UAT regions
  - edimoldovan's `dt_set_gpu_g17()` (GPU.md:123-125, "built, not boot-tested")
  - This is why his J714c failed at "MMU init -22" on our m1n1: the `handoff`/`ttbs` regions were
    missing (`mmu.rs:4022`).

## 2. M5-Pro-specific values: present, derivable, or missing

J716s is the same G17S part as J714. The scan shows gpu-core-count 20, num_mgpus 2,
core_mask_list (1023,1023) and gpu_var S. The ADT shows 2 perf tables and active-mcc 0xf. Every
J716s value is in `t6050-pro-draft.rs` with its tag.

| Field | J716s value / source | Status |
|---|---|---|
| identity (0xb, variant 3, 1 die, S, usc 3, HAL 300) | J714 config + [SCAN] | present; confirm ID at probe |
| clusters / cores 2 / 20 | [ADT][SCAN] | present (= J714) |
| core_revision (0x18, 4) | J714 | assumed; ID_VERSION at probe |
| perf_states (2 tables) | [ADT] perf-states/-1, -sram/-sram1 | derivable now, differs from J714 (per-part bins) |
| aux_perf_states | [ADT] afr-perf-states (= cs) | derivable now |
| relative_frequency | computed, base pstate 1 [ADT] | derivable now |
| aon_records | [ADT] aon-ptd ptd_data_table: 0x79/0xbc/0xce | present, identical to J714 |
| register_windows | J714's; checked against ADT (sgx, mcc, pmp0, aon-ptd, ane0, AIC) | present |
| min PB 2 MiB, render pool 4 MiB/4 GiB, operand/deflake TWO | 2-cluster values | present |
| mcc_mask / topology words | inherited 0xf [ADT] / J714 None | present |
| secondary_root_offset 0x40000 | Max/Ultra; ADT shared region 0x80000 fits | [MAX-SCALED] |
| crash_buffers FirmwareData | Max/Ultra; ADT RO follows DATA | [MAX-SCALED] |
| profile M5PublishedRoots, uat_quirks | Max/Ultra | [MAX-SCALED] |
| firmware sizes/entropy/boot-filled | [MACHO] fw-layout.py | derivable now |
| firmware text_sha256 | one refused probe or `--digest` | derivable with one step |
| header load fields 0x224/0x23c | 26A428 value | assumed |
| interface word | 0x0c8e_4339_8728_04c0 [FW] | derivable now; the PR differs |
| 26A428 graph valid on 27.3? | unknown | blocker: an Aurora answer, a 27.0 stub, or a 27.3 trace/RE |
| calibration words + controller defaults | per-part efuse; J714's won't match → default budget | missing; safe fallback |
| fan curve, thermal keys | J714 14-inch values | missing; governor off by default |

Derivable by scaling: nothing core-count-scaled is missing, because the 2-cluster values already
exist for J714. The Max/Ultra values copied here are profile-level.

Needs a trace of macOS driving the GPU:
- only if Aurora cannot say what changed between 26A428 and 26B/26C. The m1n1 hypervisor cannot run
  macOS 27 on M5 today (GPU-t6050-dt-config.md, hv feasibility).
- the per-part power-controller defaults; optional.

## 3. The PMP

- What is on J716s [ADT, PMP-J716S.md]: pmp0 ASC 0x2_84e0_0000, SRAM 0x2_8450_0000 (1 MiB, nub
  `firmware-name = t6050pmp`, `pre-loaded = 1`), dart-pmp0 with a DAPF, PTD window
  0x2_8424_0000/0x2_8425_0000. PMGR GFX (id2 362) has `notify_pmp` and id1 16; on J716s CS has
  neither. The restore manifest marks PMP `IsLoadedByiBoot`. The im4p strings include "PMP started",
  `RTKit_armv8_chinook_Oz_flto-3514.60.8`.
- "Not started by mBoot": edimoldovan (J714c, 41.3 and 60.65) found the PMP SRAM static. PMP-STATUS,
  SOC-DEV-PS-REQ/ACK, PMP-TO-GFX and GFX-TO-SMC all read 0. After opening the dart-pmp0 DAPF from the
  proxy, CPU_CONTROL read 0 at handover (GPU.md:435-474 and 481-486; the CPU_CONTROL value is from
  his #293 comment, as recorded in contrib/pending/gpu/pmp/PMP-J716S.md). So iBoot loads the PMP and leaves it
  stopped. The early SYNC faults on the ASC were the DAPF, not a security lock.
- How the M5 Ultra/Max path handles it: #1012 neither starts nor adopts the PMP. Its J716c/J775D
  results ("the desktop runs on the GPU through zink and Vulkan") come with no PMP code in the GPU
  driver. Whether Aurora's internal loader starts the PMP is not public. The "bare-metal M5 firmware
  powers the cores for work by its own policy" (commit `10c4b54099bc`).
  - edimoldovan's compute stall (CS off, KSM pause never acknowledged) happened with his G17P-derived
    init data, not the M5 graph. Inference: the PMP is not needed for probe, init or first jobs. It
    probably matters for DVFS requests through the PTD dashboard: the GFX1 image has "Invalid AFR perf
    state request received from PMP firmware (via dashboard)".
- Can the host start it? Yes, as far as public code shows. Aurora `t6050/pmp`, one commit, "soc:
  apple: Add T6050 PMP registry-v2 support", `drivers/soc/apple/pmp.rs`, compatible
  `apple,t6050-pmp-v2`. Its steps:
  - require an attached IOMMU domain (dart-pmp0)
  - check the cold state: CPU_RUN clear, SRAM +0x7bcd8 == 0xfeed1b00, zeros at +0x7bcc0..+0x7bce0
  - patch the bootargs in SRAM (BDID, DVID required; optional others)
  - set CPU_RUN and run RTKit (registry-v2, opcode 0x36)
  So no Image4 loading: the image is already in SRAM. Starting is a host-side bootargs patch plus
  CPU_RUN, which m1n1 could also do (aura's `kboot_pmp_t8122.c` / `pmp_init.py` does it on M3).
- Recommendation: do it in Linux with that driver, after the GPU probe works, not in m1n1. The PMP must
  be serviced over RTKit for its whole life, and a started PMP that nobody services is worse than a
  stopped one.
- `t6050pmp.im4p` needs no handling by m1n1.
- Readback addition for `contrib/pending/integration/r1/pmp-readback.sh`: a "stage 1b" reading the
  SRAM cold-marker words 0x2_8457_bcc0..0x2_8457_bce4 (eight 32-bit loads). These are SRAM, not ASC
  registers; edimoldovan read that range from the proxy without trouble. They show whether the
  t6050/pmp driver would accept the PMP as cold on our stub. Expect 0xfeed1b00 at +0x7bcd8 and zeros
  elsewhere.

## 4. Plan: smallest experiment sequence on J716s

Every step boots as the B payload. The A/B stage-1 watchdog resets a hang after 150 s and boots the
previous payload. Keep GPU nodes disabled in the default DTB and enable them only in the test DTB.

| Step | What | Rust | Expected | Capture |
|---|---|---|---|---|
| E0 | `pmp-readback.sh` (+stage 1b), and read the GFX/AFR/CS/GPX PS words 0x23_00e8_0000/0x100/0x108/0x110 through /dev/mem | no | PMP stopped + cold; GFX 0x0f040300 (off, auto) | `values.tsv`, genpd summary |
| E1 | m1n1: `dt_set_gpu_t6050()` fills the six regions + status okay. Kernel: wt-series + merge of `pr1012-latest`, DT draft with mailboxes disabled, unmodified #1012 driver | yes | dmesg `GPU ID registers: 0xb031100 …`, `Core masks: [0x3ff, 0x3ff …]`, then "M5 Pro bare-metal GPU tables not yet available"; no GPU write beyond power-on | dmesg, `/sys/kernel/debug/pm_genpd/*`, `/proc/iomem` (six no-map regions) |
| E2 | Apply `t6050-pro-draft.rs` A+B with `text_sha256 = 0` | yes | `Gpu::new` refuses at the firmware identity before any GPU write, printing the measured identity (digest + record offsets) | the digest → paste into the draft; confirms 0xa4000/0x184000 and the 0x224/0x23c assumption |
| E3 | Real digest, a 27.x RootProfile returning 0x0c8e_4339_8728_04c0, the native-PA mailbox table, mailboxes enabled | yes | UAT init, lower links, both ASCs start, RTKit HELLO, crash-buffer requests in fw-data, published roots, then either the InitData ACK or a firmware "interface mismatch" / crash | full dmesg with `drm.debug=0x1ff` and the asahi debug parameters, RTKit syslog lines, crash log text (rtkit-crashlog), PS words after |
| E4 | Only if E3 acknowledges: Mesa `ASAHI_M5_BRINGUP=1` (G17S/0x6050 is admitted there), one compute dispatch | yes | job completes, or a timeout with a firmware trace | dmesg, firmware trace ring |

If E3 dies at the interface or in the InitData layout, the choice is:
- (a) a 27.0 (26A428) stub. This needs Apple to still sign 27.0 for J716s, and costs SMP: raw-boot
  multicore came with 27.3.
- (b) Aurora porting the M5 graph to 27.x.
- (c) our own 27.3 diff, without a hypervisor trace.

Rust:
- Everything in E1-E4 needs `CONFIG_RUST=y`, `CONFIG_DRM_ASAHI=y` (built in; the root FS has no
  modules), `RUST_APPLE_RTKIT`, `APPLE_PMP_REPORT`, DRM=y, 16K pages, IOMMU_SUPPORT.
- Build it with the container recipe `~/Work/agents/audio-aurora/build-audio-container.sh` (Fedora 43,
  rustc 1.99.1, `tools/aurora-bindgen`). Point it at a new worktree (wt-series + `pr1012-latest`;
  expect the one `macsmc-hwmon.c` conflict) and a seed config of `j716s.config` with RUST on.
- m1n1 stays C.

Risks:
- Touching sgx with GFX off can SError or hang the fabric. Mitigations: ps_gfx with its AFR/GPX
  parents, `apple,always-on`, the genpd state checked in E0/E1 before the driver binds.
- E3 lets the GPU DMA through UAT tables the firmware built in `pagetables`. A wrong offset or quirk
  can corrupt RAM: the Max/Ultra quirks are untested on G17S.
- A firmware crash stays inside the coprocessor (edimoldovan's crashes did not take the SoC down).
- A real hang hits the 150 s watchdog. ramoops is still `=m`, so the last dmesg goes to the ESP log or
  the USB console.
- simpledrm uses DCP's power tree, not GFX: the console should survive a GPU crash (inferred).
- Don't run E3 with the PMP started (two moving parts).

## 5. The draft

- `t6050-pro-draft.rs`: the J716S board table, the bare-metal Config and the 27.3 root version word,
  every value tagged [ADT]/[SCAN]/[MACHO]/[FW]/[J714-SAME]/[MAX-SCALED]/[CODE]/[UNKNOWN].
- The concrete ask for the community (UNKNOWN list at the end of the file):
  1. ID_VERSION / core revision of a J716s part.
  2. The 27.3 G17S TEXT digest (E2 gets it).
  3. Whether 0x224/0x23c are still the boot-filled header fields.
  4. **Whether the 26A428 M5 InitData graph holds for 27.x firmware; the version word moved
     0x0339 → 0x4339. Which macOS builds do the J716c/J775D stubs run?**
  5. `secondary_root_offset` on G17S.
  6. The UAT quirks on G17S.
  7. Per-part leakage calibration words and the matching controller defaults.
  8. 16-inch fan curve and thermal keys.
  9. The native-PA T6050 mailbox role table (what Aura's "retained GPU aperture" maps).

## Files

See `SHA256SUMS`. `fw-layout.py` reads only the rkosftab table, the Mach-O load commands and the
8-byte entropy record headers. `--digest` (not run here) hashes TEXT in memory and writes nothing.
