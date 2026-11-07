T6050: reserve the coprocessor logs and hand the internal display to the firmware-27 DCP driver

The T6050 firmware-27 DCP driver in aurora-silicon/linux (#1012, and the 27.3 method table PR stacked on it) adopts the DCP that iBoot leaves running, along with its boot-locked DARTs. It has no handoff marker. It expects the loader to describe the framebuffer, name the DCP firmware in `apple,firmware-version` and `apple,firmware-compat`, and enable the display nodes. It refuses at probe, before it touches the DCP, any firmware-compat it has no method table for. aurora-wip does none of this for T6050: `dt_set_display()` ends in "unknown compatible, skip display reserved-memory setup", and the 27.3 beta 1 stub's iBoot string is not in the firmware table. These four commits add it. They also fix a separate problem found along the way: running coprocessors write their logs into RAM that Linux treats as free.

Depends on: aurora-wip <- pr/t6050-bringup (T6050 bring-up series) <- #65 (N1 hand-off) <- this. The branch is built on #65's current head (4d50f1f) rebased onto the bring-up series. The commits touch nothing those two touch, apart from neighbouring context in `src/kboot.c`. Kernel counterpart: the aurora-silicon/linux PR "drm/apple: firmware 27.3 IOMFB method table and swap layout", stacked on #1012.

1. firmware: add the 27.2 and 27.3 beta 1 stub iBoot strings. The J716s 27.3 beta 1 stub (26C5035r) reports mBoot-20457.60.65.0.1, so `os_firmware` was "unknown". It is added as V27_3B1 (27.2.98.1, the usual beta numbering), and the 27.2 stub's mBoot-20457.41.3 as V27_2. None of the existing `os_firmware.version` users takes a new branch on T6050: the GPU path stops at "unsupported chip" before its firmware switch, the ISP and iBoot-DCP switches only match older versions, and the 26.6.2 checks do not match.
2. kboot: t6050: reserve the running coprocessors' __OS_LOG segments. iBoot leaves the `__OS_LOG` segment (segment-ranges flags 0xa) of every coprocessor it starts in DRAM that m1n1 hands to the OS, and the coprocessors keep writing to it. On the J716s that is dcp, dcpext0..3, aop, mtp and auss-cpu0: about 1.1 MiB at 0x10006020000..0x10006126514, all inside the usable RAM. This commit reserves each one no-map, by physical address, from the ADT of every /arm-io device and its nubs, as one transaction. A segment that overlaps a /memreserve/ entry or another reservation is skipped and logged. It runs on every T6050 boot and writes nothing to the hardware. `kboot_display_handoff.c` reserves only the dcp/dcpextN logs, as part of its per-SoC handoff, so T6050 does not go through it.
3. kboot: t6050: hand the internal display to the firmware-27 DCP driver. On every T6050 boot, this logs the DCP ASC's CPU_CONTROL/CPU_STATUS, the PROTECT register of dart-dcp and dart-disp0, and the TCR/TTBR of DCP SID 23 (dart-dcp), scanout SID 0 and PIODMA SID 16 (dart-disp0), compared with the ADT's `l1-tt-N`. The reads are guarded, and nothing is written. dart-disp0 is locked afterwards, as before. With the boot.bin config line `chosen.m5,t6050-display=1`, the handoff runs only if every one of these holds:
   - the OS firmware is known;
   - the DCP is running;
   - both DARTs are locked;
   - all three streams translate on four-level tables at the ADT's roots;
   - the DT's dcp, DARTs, mailbox and piodma are the ADT's devices;
   - /vram lies above the OS's RAM.

   It then reserves /vram no-map as `framebuffer`, sets it as the "framebuffer" memory-region of the dcp node and the display subsystem, sets firmware-version and firmware-compat on the dcp node, and enables the dcp, its mailbox, both DARTs and the display subsystem. This is one transaction: on any failure the DT stays as it was. The DARTs are never initialised, walked or shut down. `dt_carveout_reserved_regions()` would do all three, and the `kboot_display_handoff.c` walk is written for two-level tables. `chosen.m5,t6050-dcp-compat=27.0.0` publishes <27 0 0> instead, for experiments only.
4. kboot: t6050: publish DCP firmware-compat 27.3.0 for the 27.3 beta 1 stub. The stub's own version, 27.2.98.1, describes no driver table. Its DCP firmware (AppleDCP-1317.60.10) implements 27.2's interface with one more IOMFB method at A521 and a larger IOMFBSwap. This commit publishes that as 27.3.0, the same way 13.5 beta 4 publishes 13.5.0. firmware-version stays the stub's.

Everything after commit 2 needs a device tree that describes the internal display as disabled nodes:
- `apple,t6050-dcp` at 0x48ae00000, with `iommus` on dart-dcp, `mboxes`, and a `piodma` child on dart-disp0;
- `apple,display-subsystem` with `iommus` on dart-disp0;
- dart-dcp at 0x48a340000 and dart-disp0 at 0x48a300000.

No device tree in aurora-silicon/linux has these nodes yet: the T6050 dtsi has only dcpext0 and the J775D display subsystem. Without them the armed handoff logs `DCP: T6050: no DT apple,t6050-dcp at 0x48ae00000 or display subsystem: no handoff` and changes nothing. The driver also requires `apple,bw-scratch` on the dcp node. That value is not yet measured for the internal display.

Expected log lines:
- Not armed (stage A), every T6050 boot:
  - `FDT: T6050: <owner> __OS_LOG 0x...+0x... reserved`, one line per coprocessor, then `FDT: T6050: reserved N coprocessor __OS_LOG segments`
  - `DCP: T6050: dcp at 0x48ae00000: CPU_CONTROL 0x... (running) CPU_STATUS 0x...; PROTECT dart-dcp 0x... dart-disp0 0x...`
  - `DCP: T6050: /arm-io/dart-dcp SID 23: TCR 0x9 TTBR 0x... (root 0x...), ADT l1-tt 0x...: four-level, the ADT's`, and the same line for dart-disp0 SIDs 0 and 16
  - `DCP: T6050: not armed (chosen.m5,t6050-display)`
  - `FDT: unknown compatible, skip display reserved-memory setup` is gone. `/sys/firmware/devicetree/base/reserved-memory/os-log@*` exists in Linux.
- Armed (stage B0, kernel without DRM_APPLE):
  - `DCP: T6050: handed off: framebuffer 0x...+0x..., firmware 27.3 beta, compat 27.3.0, nodes enabled`
  - In Linux: apple-dart reports `locked: 1` for 48a340000 and 48a300000, with no apple-dart fault, and simpledrm unchanged.
- Any failed check prints one `DCP: T6050: ...: no handoff` line, and the DT is unchanged.

Testing:
- Built in the Fedora 43 container with clang/lld 21.1.8 and rustc 1.99.1: aurora-wip (b6b4592), the bring-up + #65 parent, each commit of this series with CHAINLOADING=0, and the tip with a plain `make`. Every build has 15 warnings, the same as aurora-wip, so none is new. The raw image is 4325376 bytes, the same as its parent.
- The log strings share one prefix copy because the raw image's file part is close to the 0x120000 limit in `m1n1-raw.ld`. The limit is reached through the rodata/rela 64 KiB pad. #65 leaves 2104 bytes before the next pad, and this series uses 1616 of them, leaving 488. The next T6050 addition will need room made there.
- The changed lines are clang-format clean.
- Hardware, J716s:
  - stage A (not armed): [to be filled]
  - stage B0 (armed, display DT, kernel without DRM_APPLE): [to be filled]
  - stage B (B0 + the firmware-27 DCP driver and the 27.3 table, without bw-scratch): [to be filled]
  - stage C (panel driven by Linux, after bw-scratch is measured): [to be filled]

Questions:
- The opt-in is `chosen.m5,t6050-display=1` (and `chosen.m5,t6050-dcp-compat`), the names our J716s test plan uses. aurora-wip's opt-ins are `asahi,t6030-dcp`, `asahi,t8122-dcp`, `asahi,t6031-dcp`, and #65 uses `asahi,t6050-n1`. Should these become `asahi,t6050-dcp` and `asahi,t6050-dcp-compat`? I'm happy to rename.
- Would you rather have T6050 as a `struct dcp_soc` entry in `kboot_display_handoff.c`? That would need a four-level page-table walk, a mode that enables the nodes instead of setting a marker, and `__OS_LOG` reservations beyond dcp/dcpextN. I kept it separate because the firmware-27 driver neither looks for a marker nor needs iommu-addresses from a walk.
- Publishing 27.3.0 for the 27.3 beta 1 stub assumes later 27.3 builds keep this DCP interface. Should the compat follow the DCP firmware's interface (as here) or the stub's version, with the kernel mapping betas?
- T6051 (M5 Max) probably has the same display block at other addresses. Everything here is gated on T6050, because I only have T6050 data.
