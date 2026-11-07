drm/apple: firmware 27.3 IOMFB method table and swap layout

Stacked on #1012 (`funkzy/t6050-gpu-on-integration`, b1615e3fca90), like #1135 and #1173. It carries two commits:

1. **Jeff's "drm/apple: dcp: Choose the firmware 27 method table by firmware build"** from #894 (6728f8c61c59), cherry-picked with his authorship. It adds `dcp_methods_27_2` and `iomfb_v27_methods()`. On #1012 it needed two context fixes and one rename, noted in the commit: #1012's method enum has no `dcpep_pipe_set_428`, so the 27.2 entry A478 (27.0 A428) uses #1012's name for that slot, `iomfbep_set_brightness_correction`. #894 was closed when this moved to the J775D branch, which I can't see. If that branch already has this commit, drop it here and I'll rebase commit 2 onto whatever you point me to.
2. **"drm/apple: Add the firmware 27.3 IOMFB method table and swap layout"**: the table and swap record that the macOS 27.3 beta 1 DCP firmware (AppleDCP-1317.60.10, stub 26C5035r) needs. We run that stub on a J716s (16-inch M5 Pro, T6050). It has to be 27.3 or newer, because the mBoot fix for multicore raw boot on M5 Pro/Max first shipped in 27.3 beta 1.

## What 27.3 changed, compared with 27.2

- **Method tags.** One IOMobileFramebufferAP method is new at A521, so every 27.2 AP tag from A521 up moves up by one. The AP group goes from A450–A542 (93 tags) to A450–A543 (94). The UnifiedPipeline group is the same as in 27.2 (135 tags), and so are the 120 D callbacks. Eight of the driver's 41 entries move. The other 33 keep their 27.2 tags.

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

- **swap_submit (A458) input: 0xff4 → 0x1144 bytes.** The output stays 0xc. IOMFBSwap grows from 0x6e0 to 0x830 bytes, and the surfaces start at 0x830 instead of 0x6e0. The surface stride (0x22c) and everything after the surfaces are unchanged. The extra 0x150 bytes are three blocks that 27.3 inserts into the 27.2 layout. The table gives the inserts at their 27.2 offsets:

  | Insert | 27.2 offsets | 27.2 fields after it move by |
  |---|---|---|
  | 0x40 bytes at 0x98, before swap_id | from 0x98 (swap_id through bg_color) | +0x40 |
  | 0x20 bytes between 0x298 and 0x2cc | from 0x2cc (brightness_update 0x354, brightness_nits 0x35e) | +0x60 |
  | 0xf0 bytes between 0x534 and 0x6b8 | from 0x6b8 | +0x150 |

  The driver fills only the timestamps, swap_id through bg_color, and the brightness fields. Everything else in the swap is zero. So the 27.3 wire record is the 27.2 record with zeros inserted in those three ranges. Exactly where an insert falls inside its range doesn't matter, because the driver sends zeros on both sides. A457, which this driver does not call, grows by the same 0x150 bytes (0x1d30 → 0x1e80). The other 40 methods in the table check the same input and output sizes as in 27.2. The new A521 takes 0x14 in and 0x4 out.

- **SCL verification block.** 27.3 adds a swap verification path. The firmware has strings such as "supports-verification-only" and "verify_swap: region … planeCount", and 23 handler bodies changed between 27.2 and 27.3. As far as we can tell, the inserted bytes belong to that path and all-zero leaves it off. That has not been confirmed on hardware yet.

## How it was measured

- **Inputs.** The DCP firmware (t605xdcp) from Apple's public Mac17,8 IPSWs for 27.0 (26A428) and 27.2 (26B123), and the same image from our 27.3 beta 1 stub. Each was disassembled with llvm-objdump. No firmware bytes are in this PR.
- **Tags.** The firmware resolves a method tag in two compiled switches: the UnifiedPipeline lookup and the IOMobileFramebufferAP lookup. A small emulator runs both switches for every tag A000–A999 and D000–D999 in each build, then handlers are matched across builds by code fingerprint.
  - The method reproduces both existing tables: all 41 tags of #1012's 27.0 table are in the 27.0 dispatch, and all 41 of #894's 27.2 table are in the 27.2 dispatch. It also confirms #894's guessed dfb_ready_query at A385.
  - **41/41 tags of the new table are present in the 27.3 firmware dispatch** (16 UnifiedPipeline, 25 IOMobileFramebufferAP). Each one reaches the handler that its 27.2 tag reaches in 27.2. 36 handlers are identical. Five changed bodies keep their opcode sequence: setup_video_limits, set_create_dfb, commit_dfb_info and first_client_open at similarity 1.00, and swap_submit at 0.98.
- **Sizes.** The minimum input and output lengths come from the checks each dispatch handler makes on its arguments. This is where the 0xff4 → 0x1144 for swap_submit comes from.
- **Swap offsets.** I aligned the 27.2 and 27.3 versions of four firmware functions that read the swap record, and voted on the offset change of every swap field they access. 35 of 36 accessed offsets fit the three-insert model above. The one vote that doesn't, 0x608 → +0x100, lies inside the zeroed 0x534–0x6b8 range, so it would only split the third insert.
- **Compat string.** For this stub the loader publishes `apple,firmware-compat = <27 3 0>` ("27.3.0") and keeps `apple,firmware-version` as the stub's `<27 2 98 1>` (iBoot mBoot-20457.60.65.0.1). This follows how m1n1 maps 13.5 beta 4 to 13.5.0. m1n1 side: aurora-silicon/m1n1 "T6050: reserve the coprocessor logs and hand the internal display to the firmware-27 DCP driver", on aurora-wip. `iomfb_v27_methods()` accepts "27.3.0" and picks both the 27.3 table and the 27.3 swap layout with it.

## Testing

- **checkpatch --strict** (this tree's script): commit 2 is clean. Commit 1 gets only BAD_SIGN_OFF on its Co-Authored-By trailer, which is unchanged from #894.
- **Compile.** Not a full kernel build. These 25 objects in drivers/gpu/drm/apple include the files these commits touch: afk, connector, apple_drv, dcp*, dptxep, dcpext_*, ibootep, iomfb*, j613_dcp_activate, systemep, parser, plane. They compile with clang 23.1.4 and 0 warnings, using the kbuild command lines from a `DRM_APPLE=y` build of a #1012-based tree. That holds on the base, after commit 1 and after commit 2. The static_asserts hold: the request is 0x1144 bytes, surf is at 0x830, and the 27.2 record plus the three inserts is 0x830.
- **Hardware (J716s, 27.3 beta 1 stub):**
  - Stage A (loader only, display hand-off not armed): [coordinator]
  - Stage B0 (hand-off armed with compat 27.3.0, kernel without DRM_APPLE): [coordinator]
  - Stage B (this series on #1012, `DRM_APPLE=y`, without `apple,bw-scratch`; the probe should stop at "Incompatible devicetree!" before any DCP access, with both DARTs `locked: 1` and no DART faults): [coordinator]
  - Stage C (panel driven by Linux, with `apple,bw-scratch` set; this is the first run of the 27.3 table and swap layout): [coordinator]

## Questions

1. Where should 27.x method tables go now that #894 lives in the J775D branch? Here on top of #1012 as in this PR, in that branch, or somewhere else? I'm happy to retarget.
2. Should the per-build swap layout be a wire function or a struct? This PR uses a small function, `iomfb_v27_swap_wire()`, that copies the 27.2 record into a 27.3-sized buffer with the three zero blocks. That keeps a single `struct dcp_swap_v27` for the fields the driver sets. The alternative is a `struct dcp_swap_v27_3` with named reserved blocks, selected through the template like the 26.6 and 14.7 records. Which would you rather maintain as more 27.x builds arrive?
3. `apple,bw-scratch` for the internal panel: no Aurora T6050 board describes the internal DCP yet. From the 27.0, 27.2 and 27.3 kernelcaches, the internal display's D003 bandwidth reply is the PMC window + 0x20000: BIRQ 0x96 (`bwr-agent` index 0), with the PMC address computed as 0x20000 + 0x4000 × index. Index 3 (DISP_EXT0) gives the +0x2c000 your dcpext0 uses, and your T604x internal DCP also sits at +0x20000. Does that match how you derived the dcpext0 value? Stage C will be the first hardware check.
4. #894 also had 0269fbf1cae8 ("Send firmware 27 surface element sizes in bytes") and e668f77ccf3e (the AP-link dump after a crash), and #1012 has neither. This PR doesn't need them. Should stage C on the internal panel include 0269fbf?
