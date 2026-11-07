# GPU and DCP firmware interface: Aurora (27.0) vs our stub (27.3 beta 1)

2026-11-07. Studio-only analysis (agent report, saved by the coordinator; the agent could not write files).

## Recommendation: route (ii), extend Aurora's tables, and target "27.2+" rather than "27.3"

- **GPU:** the public 27.2 build (26B123) and our 27.3 beta 1 (26C5035r) have the same interface. The version word,
  the allocation table and the HW data layout all match.
- **Display (DCP):** 27.3 beta 1 is 27.2 with one extra method. Aurora already has a 27.2 method table in their PR #894,
  which now lives in their J775D branch.
- **Rejected:** (i) a 27.0 stub would put Linux back on one core, because the multicore fix is in the 27.3 stub's mBoot.
  It also leaves the M5 Pro bare-metal gap that Aurora has on 27.0 anyway. (iii) waiting for Aurora has no date, and the
  M5 Pro isn't on their list.
- **Effort:** about a week, plus two attended GPU boots (E2, E3) and one display boot.
- **Biggest unknown:** the GPU's runtime command formats (render/compute submissions, rings, events) were not compared.
- Baseline data downloaded: four members each of Apple's public 27.0 (26A428) and 27.2 (26B123) Mac17,8 IPSWs
  (kernelcache, the two GPU firmware files, the DCP firmware) in `~/Work/studio-artifacts/macos-27.0-26A428/` and
  `macos-27.2-26B123/` (private, never in a repo). Scripts in `~/Work/agents/gpu-27.3/tools/`.

**Inputs**
- Aurora: PR #1012 at `b1615e3fca90`; PR #894 head `e668f77ccf3e` (fetched read-only as `refs/remotes/aurora-ro/pr894`).
- Our 27.3b1 artifacts: `~/Work/studio-artifacts/macos-27.3/` (kernelcache), `j716s-fw/` (GPU and DCP firmware).
- Public Mac17,8 IPSW members (`kernelcache.release.mac17j`, `armfw{,1}_g17x.im4p`, `t605xdcp.im4p`): 27.0 (26A428),
  27.2 (26B123).

**Method**
- Carve `com.apple.AGXG17X` (the GPU kext) out of each kernelcache.
- Disassemble the kext and the DCP firmware with llvm-objdump.
- Diff the three builds against each other and against Aurora's constants.

## 1. GPU

### 1.1 What Aurora checks (PR #1012)

**Board profile gate**
- `asahi/driver.rs:417` (`probe_g17_m5`). The M5 Pro `CONFIG` (`hw/t6050.rs:18-58`) is set to `M5NoBareMetalTables`.
- Result: "M5 Pro bare-metal GPU tables not yet available". Independent of the firmware version.

**Firmware identity gate**
- `g17/mod.rs:1668` `firmware_variant` → `:1701` `identify_image` → `fwid.rs:290` `identify`.
- Hashes the firmware TEXT (SHA-256) with the entropy and boot-filled ranges zeroed.
- The M5 Pro list is `Identified(&[])`, i.e. empty. Only the 27.0 G17C (Max) and G17D (Ultra) builds are pinned, with
  `V26A428_M5`.

**Interface word gate**
- `g17/fw/m5/initdata.rs:643` (`encode_root_for_profile`) writes `M5_INITDATA_VERSION_WORD` (`:1654`) =
  `0x0c8e_0339_8728_04c0`. The profile is selected at `g17/initdata/m5.rs:210` (`RootProfile::J714G17S26A428`).
- The firmware stops with "Host and FW Interface is mismatched" if the word differs.

**How Aurora versions InitData**
- No per-field version. Each firmware build is one fixed graph: a 24-entry allocation size table
  (`ABI_ALLOCATION_SIZES_26A428_M5`, `:1658`) and packed layouts derived from it; fixed root offsets (+0x00 version,
  +0x08 region A, +0x18 main config, +0x20 region C, +0x30 page-table levels, +0xa8/+0xb0 status A/B, +0xb8/+0xc0
  secondary); "band" relocation tables for the HW data and status config (`COMMON26_*_BANDS`, `relocate_by_bands`),
  plus an 8-byte insert at 0x267c.
- A new build therefore needs a new `RootProfile`, size table, bands and `fwid` `Build`.

### 1.2 What our hardware and firmware report

**E0 readback** (RESULTS.md): GFX power state 0x0f040300 (off, auto). AFR and CS off. GPX on. PMP SRAM is not cold;
this doesn't matter for E1. E1 is built but not booted.

**Firmware, G17S variant a010**

| | 27.0 26A428 (public) | 27.2 26B123 (public) | 27.3b1 (ours) |
|---|---|---|---|
| RTKit | release-3514.0.15 | …pac-3514.41.1 | …pac-3514.60.8 |
| TEXT / DATA size | 0xa4000 / 0x184000 | same | same |
| Primary entropy / tunables offset | 0x49e60 / 0x49720 | 0x49ea4 / 0x49764 | 0x49eac / 0x4976c |
| Word the kext writes to root+0 | `0x0c8e_0339_8728_04c0` | `0x0c8e_4339_8728_04c0` | `0x0c8e_4339_8728_04c0` |

- The public 27.0 G17C layout and its digest equal Aurora's pinned "27.0 (26A428), G17C" entry. Aurora's 27.0 is the
  public build.
- The 27.3 firmware compares root+0 with `…4339…`. Only bit 46 differs: 0x0339 → 0x4339. The 26A428 G18G word
  (`0x0c8b_4339_83a0_04c0`) carries the same bit. Inference: a flag, not a layout hash.

### 1.3 What changed in InitData, 27.0 → 27.2/27.3 (read from the kexts)

27.2 and 27.3 are identical on every point below.

**Allocation size table** (one u64[24] array in the kext's `__TEXT,__const`)
- 27.0 matches Aurora's `ABI_ALLOCATION_SIZES_26A428_M5` exactly.
- 27.2/27.3 change two entries: index 4, POLICY: 0x126b0 → **0x12728**; index 13, STATUS_CONFIG: 0x780 → **0x790**.
- The other 22 entries are unchanged (HW data 0x2850, main config 0x4c0, status B 0xe730, region C 0x1ca0, AON PTD 0xe4).
- Aurora derives the packed offsets from this table, so this part is mechanical.

**HW data** (0x2850, size unchanged)
- The kext makes 340 stores into it in each build. The 314 stores below 0x2720 are identical.
- 27.3 inserts one u32 at **0x2720**. Its value is a config word × 1000, saturating.
- Everything after it moves by **+4**: 0x2728/0x272c → 0x272c/0x2730; kick-shared pointer 0x27dc → 0x27e0; last field
  0x2846 → 0x284a.
- The 27.3 firmware gained exactly one relevant string, "GPU did not reach forced idle within %ums of the sleep
  request". The new field is probably that timeout (inference).

**Power policy** (cumulative shifts, in 27.0 offsets)
- Unchanged up to 0x490c. +0x10 from 0x4910 (27.3 also has a new word at 0x492c). +0x18 from 0x49b8. +0x30 from
  0x4a98. +0x78 somewhere between 0x122e0 and 0x12670.
- Aurora constants that move: `M5_POLICY_STATE_PTR` 0x8254 → 0x8284; `M5_POLICY_AON_PTD_PTR` 0x11a1c → 0x11a4c; every
  controller-default word above 0x4910.
- Unchanged: 0xa18, the minimum table, and 0xb58–0xb84.

**Status config**
- Unchanged to 0x5b4. 0x5c4–0x5fc: +0x10. 0x600–0x668: re-laid out (about 14 words move by different amounts and 3
  are new, so this needs a field-by-field map, not a band). 0x670–0x778: +0x10. Aurora's link word/pointer
  0x774/0x778 → 0x784/0x788.

**No change found**: root layout; main config, region C, status B. The remaining kext differences are the driver's
own objects (+8 offsets).

**Coverage limits**: the tracker follows stores through the firmware object's member pointers only. The runtime
command and event formats were not compared. Signs the runtime change is small: the 27.0 → 27.3 G17S primary image
grew by only 0x90 bytes, with 4 new strings (the forced-idle error, `_agfUPPLRegisterPages`/`…PageCount`,
`_premap_ranges`, `_gClientFunctions`).

### 1.4 Gaps in every route (also on 27.0)
- J716s board table (draft: `hwdata/t6050-pro-draft.rs`).
- Bare-metal profile: `secondary_root_offset`, UAT quirks, crash buffers.
- A G17S firmware identity.
- The native-address mailbox table.
- The m1n1 handoff (E1 patch 0026).

## 2. DCP

### 2.1 What Aurora checks
- `drm/apple/dcp.c:4942` `dcp_check_firmware_version()`: `apple,firmware-compat` must be byte-exact `"27.0.0"`;
  otherwise `DCP_FIRMWARE_UNKNOWN` and the probe returns `-ENODEV`.
- PR #1012 has one method table (`iomfb_v27.c`, 41 entries, A000–A489).
- PR #894 (closed 2026-11-03, moved to the funkzy/j775d branch of aurora-silicon/linux-aurora): adds
  `dcp_methods_27_2` and `iomfb_v27_methods(compat)` for "27.0.0" and "27.2.0"; in 27.2 the IOMobileFramebufferAP
  methods moved +50; three UnifiedPipeline methods moved +1; an unknown method tag panics the DCP
  ("link_rpc_lookup callback not found").

### 2.2 What the firmware says
- DCP builds: 27.0 AppleDCP-1317.1.1 (SDK 26A411); 27.2 1317.40.16 (SDK 26B106); ours 1317.60.10 (SDK 26C5035e).
- Method tags are 32-bit FourCC values compared in two compiled switches in the DCP firmware: one for the
  UnifiedPipeline group, one for the IOMobileFramebufferAP lookup. Both switches were emulated for A000–A999 and
  D000–D999 in each build, and handlers matched across builds by code fingerprint.

| Tags | 27.0 | 27.2 | 27.3b1 |
|---|---|---|---|
| UnifiedPipeline | …A350–399 (133) | …A350–401 (135) | same as 27.2 |
| IOMobileFramebufferAP | A400–A492 (93) | A450–A542 (93) | **A450–A543 (94)** |
| D callbacks | 120 | same set | same set |

**The method checks out against Aurora's own tables**: all 41 of Aurora's 27.0 tags exist in 27.0; all 41 of PR #894's
27.2 tags exist in 27.2; handlers match 27.0 → 27.2 at +50, as PR #894 says. In the UnifiedPipeline group the 27.2
insertion falls between A375 and A381, confirming PR #894's guessed dfb_ready_query A384 → A385.

**27.2 → 27.3**: UnifiedPipeline group unchanged. One IOMobileFramebufferAP method is **inserted at A521**; every tag
≥ A521 moves +1. Unique anchors: A500, A517 and A520 stay put; A529→A530, A532→A533, A533→A534, A542→A543. The 27.3
table is PR #894's 27.2 table with these 8 entries moved +1; the other 33 are unchanged.

| Method | 27.2 | 27.3 |
|---|---|---|
| set_display_refresh_properties | A525 | A526 |
| flush_supports_power | A528 | A529 |
| abort_swaps_dcp | A529 | A530 |
| register_dfb_surface | A533 | A534 |
| set_power_state | A534 | A535 |
| pipe_query_474 | A535 | A536 |
| pipe_set_476 | A537 | A538 |
| pipe_query_478 | A539 | A540 |

**Payload layouts not verified**: the swap_submit prototype strings are identical in all three builds; 27.3 adds an
"SCL" verification block to the swap path ("supports-verification-only", "verify_swap: region…planeCount"); 23
handler bodies changed between 27.2 and 27.3.

### 2.3 How big the gap is
One new table, derived mechanically from 27.2, plus a compat entry. Not an ABI rewrite. Still open in every route:
the internal panel's `apple,bw-scratch` offset; m1n1 patch 0024 and stages A/B (`contrib/pending/dcp/aurora/ANALYSIS.md`);
Aurora has never driven an internal panel on T6050.

## 3. Routes

**(i) A 27.0 stub next to 27.3**: needs IPSW 26A428 (listed as signed for Mac17,8 today; confirm with a TSS check), a
new stub volume group paired to 27.0 OS firmware (same flow as `host/macos/refresh-stub-firmware.sh`) and a 1TR visit
for its LocalPolicy, then re-running the N1, trackpad, audio and PMP handoffs validated on the 27.3 stub. m1n1 can boot
it, but on the 27.0 mBoot (20457.1.29) raw boot is single-core; the project's own rule is stubs ≥ 27.3b1. Effort 0.5–1
day attended, then days of re-validation; the §1.4 gap stays. Risk: losing 17 of 18 CPUs; Apple can stop signing 27.0.

**(ii) Extend the tables to 27.2+**
- GPU: a `RootProfile` with the new version word; a size table with two entries changed; an HW-data band (+4 from
  0x2720) plus the new field; four policy bands, with the inserted words' values read from the 27.2 kext; a
  status-config field map; a G17S `Build` for our image (fw-layout `--digest` locally, or E2); the §1.4 work.
- DCP: `dcp_methods_27_3` (the 8 moves) on top of PR #894; accept the 27.3 compat; m1n1 publishes an honest "27.3.0".
- Effort: GPU 3–4 days for the InitData changes + 1 day for the board/profile, then E2/E3. DCP about 1 day, plus the
  bw-scratch measurement and stages A/B.
- Risk: sizes, bands and tags are mechanical; the real risk is the unverified runtime structs (E3/E4 will show it)
  and the values of the new fields. A wrong DCP tag gives a named DCP crash: black panel until a cold boot, no damage.

**(iii) Wait for Aurora**: no effort, no date. Aurora's J775D display already runs 27.2, so a GPU 27.2 port is
plausible, but the M5 Pro has no bare-metal tables there.

**Pick (ii), in this order:**
1. Post the community question and offer the port to Aurora as their 27.2 profile.
2. Display: 27.3 table on PR #894 → stages A, B, then C (attended, once bw-scratch is measured).
3. GPU: E1 → E2 (digest) → the 27.2+ InitData profile. Before E3, diff the render/compute submission builders between
   the 27.0 and 27.2 kexts the same way.

## 4. Draft community question (post only after Rolando's go)

> **Title:** M5 Pro (G17S) and DCP on macOS 27.2+ firmware: interest in a 27.2 profile?
>
> Hi all. We're running Linux on a 16-inch M5 Pro (J716s) from an m1n1 stage-2. The stub has to be 27.3 beta 1 or
> newer, because the multicore raw-boot fix arrived in that mBoot. #1012's GPU path and the T6050 DCP path target the
> 27.0 (26A428) firmware, so both refuse our stub. Before we write anything we'd like to line up with you.
>
> What we found comparing the public 27.0 (26A428) and 27.2 (26B123) Mac17,8 IPSWs. 27.3 beta 1 matches 27.2 in all
> of these:
> - GPU: the InitData version word goes from 0x0c8e_0339_8728_04c0 to 0x0c8e_4339_8728_04c0 (one bit). In the kext's
>   allocation-size table, only the power policy (0x126b0 → 0x12728) and the status config (0x780 → 0x790) change. HW
>   data stays 0x2850 but gains a u32 at 0x2720, so its tail moves by 4 (kick-shared pointer → 0x27e0). The policy has
>   insertions near 0x4910, 0x49b8, 0x4a98 and before its last field. The status config's 0x600–0x668 region is
>   re-laid out. The 27.0 kext reproduces your 26A428 tables exactly, so we trust the comparison. We have not compared
>   the runtime command formats.
> - DCP: the 27.2 IOMFB table from #894 matches the 27.2 firmware's dispatch, including dfb_ready_query at A385. 27.3
>   beta 1 inserts one more IOMobileFramebufferAP method at A521, so 27.2 tags from A521 up move by one
>   (set_power_state A535, register_dfb_surface A534, …).
>
> Questions:
> 1. Is anyone already porting the M5 InitData graph to 27.2? Would you take a "27.2+" RootProfile/allocation
>    table/band set as a PR on #1012, or should it wait until that lands?
> 2. Where should a 27.2/27.3 IOMFB table go now that #894 lives in the J775D branch?
> 3. Do the J716c/J775D bare-metal setups run 27.0 or 27.2 GPU firmware? Has anyone compared the TA/3D/compute kick
>    structures between 27.0 and 27.2?
> 4. For the M5 Pro bare-metal profile (`secondary_root_offset`, UAT quirks, crash buffers): are the Max/Ultra values
>    expected to hold for G17S?
>
> We can share the method (it's scripted) and test on the M5 Pro.

The draft names the public board (J716s) but no unit identifiers.

## Files
- `~/Work/agents/gpu-27.3/tools/`: the scripts (kernelcache carving, store tracker, switch emulator, remote-zip fetch).
  They read only the private trees.
- Private, never in a repo: `~/Work/studio-artifacts/macos-27.0-26A428/`, `macos-27.2-26B123/`,
  `macos-27.3/derived/`, `derived-dcp/`.
