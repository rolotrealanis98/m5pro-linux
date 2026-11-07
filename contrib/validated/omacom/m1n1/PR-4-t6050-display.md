kboot: T6050: internal display hand-off for the firmware-27 DCP driver, opt-in (stacked on PR-3)

Base: PR-3 (`omacom/t6050-gpu`). This PR adds four commits. They touch `src/firmware.[ch]` and the display part of `src/kboot.c` only, and cherry-pick onto PR-1 or #30 unchanged. Branch: `omacom/t6050-display`.

The T6050 firmware-27 DCP driver (aurora-silicon/linux #1012, with the 27.3 method table in #1174) adopts the DCP iBoot leaves running, together with its boot-locked DARTs. It has no hand-off marker. It expects the loader to describe the framebuffer, name the DCP firmware and enable the display nodes, and it refuses a firmware-compat it has no table for before it touches the DCP. On integration/aurora, a T6050 boot ends in "unknown compatible, skip display reserved-memory setup" and publishes nothing for the display.

How this fits the J714c: #30 adds nothing for the display either. His DCP runs from the kernel side on 27.2 firmware, with m1n1's T6050 path unchanged. So this PR does nothing for the display unless asked. The exceptions are two fail-soft items that run on every T6050 boot (commit 2 and the read-only log in commit 3); see "Effect on a J714c" below.

1. `firmware: add the 27.2 and 27.3 beta 1 stub iBoot strings`. `mBoot-20457.41.3` becomes V27_2 (Aura #61) and `mBoot-20457.60.65.0.1` becomes V27_3B1 (27.2.98.1, the J716s's 26C5035r stub; its DCP firmware is AppleDCP-1317.60.10, SDK 27.3). None of the `os_firmware.version` users takes a new branch on T6050.
2. `kboot: t6050: reserve the running coprocessors' __OS_LOG segments`. iBoot puts the `__OS_LOG` segment (segment-ranges flags 0xa) of each coprocessor it leaves running into DRAM that m1n1 hands to the OS, and those coprocessors keep writing it. On the J716s that is dcp, dcpext0-3, aop, mtp and auss-cpu0: about 1.1 MiB, all inside the usable RAM.
   - Each segment is reserved no-map from the ADT of every `/arm-io` device and its nubs.
   - A segment that overlaps an existing reservation is skipped and logged.
   - It is one transaction: if one reservation fails, none is added.
   - T6050 no longer reaches the generic display path. `dart-disp0` is locked as before.
3. `kboot: t6050: hand the internal display to the firmware-27 DCP driver`. Every T6050 boot reads and logs the state iBoot left the display in, behind exception guards, and writes nothing: the DCP's CPU control and status, the PROTECT registers of dart-dcp and dart-disp0, and the TCR/TTBR of the three streams the ADT gives page tables (DCP SID 23, scanout SID 0, PIODMA SID 16), each compared with the ADT's `l1-tt-N`.

   The hand-off itself runs only with `chosen.asahi,t6050-display=1` and a known OS firmware, and only if all of these hold: the DCP runs, both DARTs are locked, the three streams translate on four-level tables at the ADT's roots, the DT's dcp, DARTs, mailbox and piodma are the ADT's devices, and `/vram` lies above the OS's RAM. Then it:
   - reserves `/vram` no-map as `framebuffer` and gives it to the dcp node and the display subsystem;
   - sets `apple,firmware-version` and `-compat` on the dcp node;
   - enables the dcp, its mailbox, both DARTs and the display subsystem.

   It is one transaction: if any step fails, the DT is left as it was. The DARTs are never initialised, walked or shut down. `chosen.asahi,t6050-dcp-compat=27.0.0` publishes `<27 0 0>` instead, for experiments only.
4. `kboot: t6050: publish DCP firmware-compat 27.3.0 for the 27.3 beta 1 stub`. The 27.3 beta 1 DCP firmware implements 27.2's interface plus one IOMFB method (A521) and a larger IOMFBSwap. The compat is published as 27.3.0, as 13.5 beta 4 publishes 13.5.0. With a 27.2 stub the compat is the stub's own 27.2.0, which is what a 27.2 kernel table expects.

Why not the T8142 (M5) path: `dt_carveout_reserved_regions()` and `dt_reserve_m5_display_segments()` initialise the DCP's DART and translate through it, and `kboot_display_handoff.c` walks two-level tables. On T6050 the running DCP depends on those DARTs, and their tables are four-level. On the J716s the DCP firmware segments and the DART tables already lie outside the RAM m1n1 publishes, so the only reservations needed are `/vram` and the `__OS_LOG` segments.

The names follow omacom's `chosen.asahi,*` switches. Our stage 2 used `chosen.m5,t6050-display` for the same code.

Effect on a J714c: the `__OS_LOG` reservations (commit 2) and the read-only state log (commit 3) run on every T6050 boot. Unarmed, nothing is enabled and no firmware property is written. If the J714c's stub reports `mBoot-20457.41.3` (27.2), `os_firmware` becomes 27.2 instead of unknown.

### Testing

MacBook Pro 16-inch, M5 Pro (J716s, Mac17,8), macOS 27.3 beta 1 stub (26C5035r, `mBoot-20457.60.65.0.1`).

**This stack on hardware (2026-11-07):** the full stack, built on #26 before #30 replaced it, booted the J716s on the first pass. The DT had no display nodes and `chosen.asahi,t6050-display` was not set, so the hand-off was present but not armed. The parts that run on every T6050 boot (the `__OS_LOG` reservations and the read-only state log) were in that loader, and Linux came up on 18 CPUs with Wi-Fi. The rebase onto #30 has not booted.

The hand-off itself ran in our own stage 2 (with the GPU hand-off code in the same image). On 2026-11-07:
- DCP-A (unarmed): `__OS_LOG` segments reserved (`mtp`, `auss-cpu0`, ...). Linux booted, self-test passed. The first boot of the freshly written file fell back once, as about one in four freshly written payloads did that day; the retry booted.
- DCP-B0 (armed, daily kernel without DRM_APPLE, DT with the display nodes): the log read `dcp at 0x48ae00000: CPU_CONTROL 0x10 (running)`, `dart-dcp SID 23, dart-disp0 SIDs 0 and 16: four-level, the ADT's table`, `reserved 8 coprocessor __OS_LOG segments`, `dcp handed off: vram 0x10bd15f4000+0x72c4000 reserved as its framebuffer; firmware-version 27.3 beta, firmware-compat 27.3.0`. The dcp node was `okay` in Linux and the panel kept working on simpledrm: pass (twice).
- DCP-B (armed, kernel with DRM_APPLE and the 27.3 table): same loader lines. The DARTs probe as locked, then `apple-dcp ... Incompatible devicetree`. That is expected: the panel's `apple,bw-scratch` was not in that DT yet. The refusal happens before any DCP register access, with no DART fault: pass.

This branch:
- Boot-test payload rebuilt on #30: the daily's kernel and the DCP-B0 DT, with `chosen.asahi,t6050-n1=4` and `chosen.asahi,t6050-display=1`, self-test on. This loader disables the stage 1 watchdog, so the boot has to be attended.
- Each commit builds with `make` and `make CHAINLOADING=1`: no new warnings against #30. Sizes are unchanged (0x410000 / 0x420000), and the CHAINLOADING=1 file part still ends at 0x120000. CI's pytest set (Linux): all pass. `git clang-format`: clean.

Dependencies: aurora-silicon/linux #1012 and #1174 (27.3 IOMFB table and swap layout), plus the J716s display nodes with the panel's `apple,bw-scratch`.

Questions:
- @edimoldovan: does your J714c kernel's DCP take `apple,firmware-compat` from the DT, or does it ignore it? Would a 27.2 hand-off through this path help you, or do you want T6050 to stay unarmed by default as it is here?
- Should the `__OS_LOG` reservations also be opt-in? They protect memory the coprocessors keep writing, so I made them unconditional.
- Your J714c report lists system firmware 20457.60.65.0.1 with macOS 27.2 (26B123). On the J716s, `mBoot-20457.60.65.0.1` is the OS firmware of the 27.3 beta 1 stub. What does m1n1 print as "OS FW version" on your machine?
