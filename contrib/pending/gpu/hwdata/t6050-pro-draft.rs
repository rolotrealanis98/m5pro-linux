// SPDX-License-Identifier: GPL-2.0-only OR MIT
//! DRAFT, not built. The 16-inch M5 Pro (J716s) for aurora-silicon/linux#1012
//! (head b1615e3fca90, local ref refs/remotes/aurora-ro/pr1012-latest in /Volumes/linux-cs/linux).
//!
//! Two pieces, in the shape the PR uses:
//!   A. a board table for drivers/gpu/drm/asahi/g17/fw/m5/initdata.rs (beside J714/J716C/J775D,
//!      initdata.rs:1757-1879), and
//!   B. a bare-metal Config for drivers/gpu/drm/asahi/hw/t6050.rs (replacing CONFIG at
//!      t6050.rs:18-58, modelled on CONFIG_MAX at t6050.rs:61-127 = commit 0625c9f2f97d).
//!   C. the root version word the 27.3 firmware checks (initdata.rs:29-55, 1654).
//!
//! Source tags on every value:
//!   [ADT]        J716s runtime ADT ~/Work/studio-artifacts/adt-runtime-j716s.bin (mBoot-20457.41.2)
//!   [SCAN]       macOS 27.3 ioreg, ~/Work/m5scan/redacted/04-gpu.txt
//!   [MACHO]      rkosftab table + Mach-O load commands of agx/armfw{,1}_g17x.im4p (27.3 26C5035r),
//!                printed by fw-layout.py in this folder
//!   [FW]         a string or immediate in the same images (offsets given)
//!   [J714-SAME]  the PR's J714 value; J716s is the same T6050 G17S part (2x10 cores, 4 AMCCs)
//!   [MAX-SCALED] the M5 Max / Ultra bare-metal profile value (0625c9f2f97d, 10c4b54099bc); these
//!                are profile-level, not core-count-scaled
//!   [CODE]       computed by the PR's own const fns / asserts
//!   [UNKNOWN]    needs a boot, a trace or an Aurora answer (list at the end)

// ---------------------------------------------------------------------------------------------
// A. Board table (g17/fw/m5/initdata.rs)
// ---------------------------------------------------------------------------------------------

// [ADT] sgx perf-states (table 0 = entries 0..13, table 1 = entries 14..27 = perf-states1) and
// perf-states-sram / perf-states-sram1, MHz and mV. SRAM = max(775, core) as on J714.
// Differs from J714_GPU_PERF_STATES (initdata.rs:1940) in every active state: voltages are
// per-part bins, not a board constant.
pub(crate) const J716S_GPU_PERF_STATES: [M5PerfState; 14] = two_tables([
    // (MHz, core0, core1, sram0, sram1)
    (0, 125, 125, 775, 775),            // ADT freq 0 (J714 also 0)
    (338, 600, 600, 775, 775),
    (486, 630, 630, 775, 775),
    (636, 665, 665, 775, 775),
    (796, 715, 715, 775, 775),
    (888, 725, 725, 775, 775),
    (988, 755, 755, 775, 775),
    (1084, 780, 780, 780, 780),
    (1182, 810, 810, 810, 810),
    (1278, 865, 850, 865, 850),
    (1374, 905, 875, 905, 875),
    (1470, 950, 920, 950, 920),
    (1578, 1025, 995, 1025, 995),
    (1620, 1050, 1035, 1050, 1035),
]);

// [ADT] sgx afr-perf-states (dies = 1, count = 14; identical to cs-perf-states), min_sram_volt
// 775000. SRAM column = max(775, core), the rule J714_AUX_PERF_STATES (initdata.rs:1476) and the
// J716c comment (initdata.rs:1483) state.
const J716S_AUX_PERF_STATES: [M5AuxPerfState; 14] = one_lane([
    (24, 125, 775), (338, 585, 775), (486, 630, 775), (636, 655, 775),
    (796, 680, 775), (888, 695, 775), (988, 740, 775), (1084, 760, 775),
    (1182, 790, 790), (1278, 840, 840), (1374, 870, 870),
    (1470, 905, 905), (1578, 980, 980), (1620, 1000, 1000),
]);

/// M5 Pro, 16-inch: two clusters of ten cores.
pub(crate) const J716S: Board = Board {
    // [ADT] perf-state-table-count 2; [SCAN] num_mgpus 2, core_mask_list (1023, 1023)
    clusters: 2,
    // [SCAN] gpu-core-count 20, num_cores 20 (all 20 enabled on this unit)
    gpu_cores: 20,
    // [J714-SAME] core type 0x18 follows ID variant 3 (Max 4 -> 0x19, Ultra 6 -> 0x1a).
    // Revision 4 assumes the raw silicon revision of the J714/J716c parts (ID_VERSION 0x..1100);
    // [UNKNOWN-1] confirm from "GPU ID registers:" at probe (expect 0x0b031100).
    core_revision: (0x18, 4),
    perf_states: &J716S_GPU_PERF_STATES,
    // [ADT] perf-state-table-count 2
    perf_tables: 2,
    aux_perf_states: &J716S_AUX_PERF_STATES,
    // [CODE] floor 1 = [ADT] gpu-perf-base-pstate 1 (J714 uses 1 too)
    relative_frequency: relative_frequency(&J716S_GPU_PERF_STATES, 1),
    // [ADT] /arm-io/aon-ptd ptd_data_table: RT0g {0x6730_5452, 0x0079_0001, 0x0000_1401} at
    // +0x318, RT1g {.., 0x00bc_0001, ..} at +0x3c0, RT0r {0x7230_5452, 0x00ce_0001, ..} at
    // +0x6e4: byte-identical to J714_AON_RECORDS (initdata.rs:1609), so reuse them.
    aon_records: &J714_AON_RECORDS,
    // [J714-SAME], checked against [ADT] where a node exists:
    //   slot 0  0x2_8041_4000  = sgx meta-sw-interrupt 0x2_8041_4084 (page)
    //   slot 3  0x22_2{0,2,4,6}10_4000 = mcc reg[14..17] + 0x104000; mcc amcc-enable-mask 0xf
    //   slot 9  0x2_8425_0000  = pmp0 reg[3] (ptd-update-reg-index 3) = mcc reg[3]
    //   slot 10 0x2_8424_0000  = mcc reg[2] (pmp_ptd_db_reg_idx 2)
    //   slot 11 0x2_8425_8000  = PTD interrupt block (aperture 0x2_8424_0000 + 0x18000)
    //   slot 12 0x5_0965_c000  inside ane0 reg[0] 0x5_0800_0000 + 0x2000000
    //   slot 15 0x2_8cdc_0000  = aon-ptd reg[0]
    //   slot 17.. 0x23_0000_0000 + offsets = sgx reg[0]
    //   slots 4, 14 (0x2_8046_8000, 0x23_8030_0000): SoC-level, not cross-checked
    register_windows: &J714_REGISTER_WINDOWS,
    // [CODE] min_parameter_buffer_pages(2) << 15 (assert at initdata.rs:1875-1879)
    min_parameter_buffer: 0x0020_0000,
    // [J714-SAME] 4 MiB blocks, 4 GiB inventory: the two-cluster geometry (28c9c8bc772e)
    render_pool: (0x40_0000, 1 << 32),
    // [UNKNOWN-7] J714's leakage words. This unit's efuse words will not match, so
    // controller_defaults is skipped and the firmware keeps its default budget (initdata/m5.rs:
    // 178-196). Correct per-part words come from the loader (apple,leakage-calibration-words).
    calibration: Some([0xd2035701, 0xac3a1280, 0x0a281d81]),
    // [J714-SAME] applied only when the calibration matches (see above)
    controller_defaults: Some(encode_m5_policy_controller_defaults),
    // [J714-SAME] the image's 1500 us
    idle_standby_us: None,
    // [ADT] sgx active-mcc-bit-vector 15 = the inherited 0xf
    mcc_mask: None,
    // [J714-SAME] the inherited words (only the Max sets (16, 40), dea8af373b1a)
    topology_words: None,
    // [UNKNOWN-8] J714 (14-inch) value; the 16-inch chassis has larger fans. The governor is
    // opt-in and off by default, so this is not on the probe path.
    fan_curve_start_mc: 84_000,
    // [J714-SAME] G17S host encodings
    g17d_forms: false,
};

// ---------------------------------------------------------------------------------------------
// B. Config (hw/t6050.rs): the M5 Pro on bare metal, as CONFIG_MAX
// ---------------------------------------------------------------------------------------------

pub(crate) const CONFIG: Config = Config {
    // [ADT] sgx compatible gpu,t6050
    chip_id: 0x6050,
    identity: Identity {
        family: 0xb,                    // [J714-SAME] G17
        variant: 3,                     // [J714-SAME] M5 Pro; [UNKNOWN-1] confirm at probe
        num_dies: 1,                    // [ADT] one die (no gfx on die 1)
        gpu_variant: GpuVariant::S,     // [SCAN] gpu_var "S"; [FW] "FW Build variant: g17s"
        usc_generation: 3,              // [SCAN] usc_gen 3
        hal_generation: 300,            // [J714-SAME]
    },
    uat_ias: 42,                        // [J714-SAME] same SoC
    uat_oas: 42,
    // [MAX-SCALED] both roles publish their kernel roots, the secondary's at 0x40000 in
    // `pagetables`. [ADT] gfx-shared-region-size 0x80000 = room for both. [UNKNOWN-5]
    secondary_root_offset: Some(0x40000),
    // [MAX-SCALED] crash logs inside fw-data. [ADT/MACHO] each role's __DATA_SHARED_RO follows
    // its __DATA inside the one fw-data span (41.2: 0x100_0251_8000..0x100_0269_c000).
    crash_buffers: CrashBuffers::FirmwareData,
    profile: FirmwareProfile::M5PublishedRoots,   // [MAX-SCALED]
    pm_metrics: None,
    windows: &[],
    reserved_slots: &[],
    perf: None,
    opps: 0,
    // [MAX-SCALED] reserved_tables, clean_tables, page_tlbi, no handoff lock, slot 0xffff,
    // unk2 1 (t6050.rs:156-164). [UNKNOWN-6] only qualified on G17C/G17D.
    uat_quirks: CONFIG_ULTRA.uat_quirks,
    region_c: None,
    chip: None,
    m5: Some(&crate::g17::fw::m5::initdata::J716S),
    adopt_root_entries: true,
    fabric_bridge: false,
    recovery_slot_keys: None,
    gpu_generation: GpuGen::G17,
    firmware: crate::g17::fw::variant::Firmware::Identified(&[crate::g17::fw::variant::Build {
        // [FW] the stub's bundle: SystemVersion 27.3 26C5035r, iBoot mBoot-20457.60.65.0.1,
        // RTKit_armv8_lightning_Oz_flto_pac-3514.60.8 in both images.
        os_version: [27, 3, 0],
        name: "27.3 (26C5035r), G17S",
        images: &[crate::fwid::FirmwareBuild {
            name: "26C5035r for T6050 G17S, primary then secondary",
            // [MACHO] variant a010 (g17s): GFX __TEXT 0x50000 + GFX1 __TEXT 0x54000
            text_size: 0xa4000,
            // [MACHO] 0xc0000 + 0x8000 + 0xb4000 + 0x8000 (same as the Max and the Ultra)
            data_size: 0x184000,
            // [MACHO+FW] GKTS/ECAP records found at these TEXT offsets in both images
            entropy: &[[0x49eac, 0x49f8f], [0x9d92c, 0x9da0f]],
            boot_filled: &[
                // [UNKNOWN-3] the image header's two load fields: the offsets every 26A428 build
                // the PR pins uses; not checked for 27.3 (code bytes not read)
                (0x224, 4), (0x23c, 8),
                // [MACHO] __TEXT,_rtk_tunables and __TEXT,_rtk_patchbay of the primary
                (0x4976c, 0x740), (0x49eac, 0x231),
                (0x50224, 4), (0x5023c, 8),
                // [MACHO] the same sections of the secondary (TEXT + 0x50000)
                (0x9d1ec, 0x740), (0x9d92c, 0x231),
            ],
            // [UNKNOWN-2] Run experiment E2 (ANALYSIS.md section 4): with this placeholder the
            // driver refuses the build before any GPU write and prints the measured digest of
            // the live fw-text; or run `fw-layout.py --digest` on the bundle images.
            text_sha256: [0; 32],
        }],
        // [UNKNOWN-4] the 26A428 M5 command set; nobody has run it on 27.x firmware.
        variant: &crate::g17::fw::variant::V26A428_M5,
    }]),
    // [J714-SAME] two clusters of ten core slots (t6050.rs:49-57)
    core_layout: CoreLayout {
        cores: None,
        alternate_core_masks: None,
        operand_state: crate::g17::fw::compute::OperandState::TWO_BY_TEN,
        deflake: crate::g17::fw::render::Deflake::TWO_CLUSTERS,
        compute_blocks: crate::g17::fw::freelist::COMPUTE_BLOCKS,
    },
};

// ---------------------------------------------------------------------------------------------
// C. Root version word (g17/fw/m5/initdata.rs)
// ---------------------------------------------------------------------------------------------
//
// The PR writes M5_INITDATA_VERSION_WORD = 0x0c8e_0339_8728_04c0 (initdata.rs:1654) for every
// T6050 board (RootProfile::J714G17S26A428, initdata/m5.rs:210). The 27.3 images check
// a different word: in armfw_g17x.im4p, variant a010 (g17s), the init path is
//     ldr  x9, [x8]                      ; root + 0x00
//     movz x10, #0x04c0
//     movk x10, #0x8728, lsl #16
//     movk x10, #0x4339, lsl #32
//     movk x10, #0x0c8e, lsl #48
//     cmp  x9, x10 ; b.ne -> "Host and FW Interface is mismatched"
// (file offsets 0x25509-0x25521; the same four immediates sit in the a000/g17c and a020/g17d
// images at 0x143339 / 0x2614dd, and in armfw1_g17x.im4p at 0x2ac29 / 0x140861 / 0x2577c5).
// No 0x0339 immediate exists in either 27.3 file. edimoldovan measured the same 0x4339 word on
// J714c with mBoot-20457.41.3 and 60.65 (GPU.md:52-55, 490).
//
// [FW] 27.3 word:
pub(crate) const M5_27_INITDATA_VERSION_WORD: u64 = 0x0c8e_4339_8728_04c0;
// A 27.x RootProfile would return it from version_word(); every other per-profile constant
// (root size 0xc8, opening opcodes 0x15/0x2a, bundle views, ABI_ALLOCATION_SIZES_26A428_M5) is
// [UNKNOWN-4] for 27.3. edimoldovan's notes (GPU.md:487-492) say the device-control dispatcher
// stayed at the same offsets from 41.3 to 60.65, and his 0xc8 root matches the PR's M5_ROOT_SIZE.

// ---------------------------------------------------------------------------------------------
// The UNKNOWN fields: the concrete ask
// ---------------------------------------------------------------------------------------------
//  1. ID_VERSION / core revision of a J716s part (expect variant 3, revision 0x1100 -> fw rev 4).
//     Cheap: the first probe prints it.
//  2. text_sha256 of the 27.3 G17S build: one refused probe (E2) or fw-layout.py --digest.
//  3. Whether the header load fields (0x224/4, 0x23c/8) are still the boot-filled ones in 27.3.
//     E2 answers it: the live digest must equal the file digest.
//  4. THE BLOCKER. Is the 26A428 M5 InitData graph valid for 27.x firmware (26B/26C, mBoot 41.x
//     and 60.65)? The version word changed (0x0339 -> 0x4339). Which other layouts moved?
//     Ask Aurora (funkzy, DjDeveloperr, erikwb): which macOS builds do their J716c / J775D stubs
//     run, and has anyone driven the M5 graph with 0x0c8e_4339_8728_04c0?
//  5. secondary_root_offset 0x40000 on G17S (Max/Ultra value).
//  6. uat_quirks on G17S (Max/Ultra value).
//  7. This part's leakage calibration words and matching controller defaults (needs a loader
//     that reads the efuse, or Aurora's aura-internal handoff format).
//  8. fan_curve_start_mc and the SMC thermal keys for the 16-inch chassis (governor only).
//  9. (outside this file) The T6050 mailbox role table for native physical addresses, see
//     t6050-j716s-gpu-draft.dtsi.
