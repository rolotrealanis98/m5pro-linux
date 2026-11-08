# Hardware ProRes on the J716s (M5 Pro, T6050) under Linux: feasibility (2026-11-08)

Studio-only study: code and local artefacts read, nothing booted, nothing committed. Sources are
cited by path. Tags: [tree] the aurora-silicon kernel checkouts under `/Volumes/linux-cs*`;
[ADT] the J716s runtime device tree (node names, property names, offsets and sizes only);
[kext] macOS 27.3 kernel collection strings and IORegistry text (names only); [m1n1]
`~/Work/m1n1/proxyclient`; [knowledge] not verified against a local source.

## Bottom line

- The README row "ProRes: only a device-tree binding exists, no driver" is stale. The daily
  tree carries a V4L2 memory-to-memory **ProRes encoder** driver for the T8140 (A18 Pro) and an
  unmerged Aurora branch adds the T6000 (M1 Pro) engine. Neither knows the T6050. [tree]
- The J716s has one ProRes engine, `/arm-io/apr0`, a new generation (`apr,n0`), laid out like
  the M4 Max's (three register windows, one DART stream, SCODEC power state that is also the
  reset). It is a pure MMIO descriptor-ring engine: **no firmware, no per-unit data**. [ADT][kext]
- Step (a), power the block up and observe it, is cheap and safe enough for the loop: five
  patches against the daily are drafted and compile-tested (below). Steps (b) decode and (c)
  encode need the n0 generation's tunables and descriptor format, which exist only inside
  macOS's `AppleProResHW`; that is weeks of reverse engineering with no Linux userspace that
  could use the result. **Recommendation: do (a) now as a one-boot observation, then stop;
  revisit (c) encode only if Aurora lands a T6041 (M4 Max) variant, which shares the layout.**

## 1. What exists today

### Kernel (daily `j716s-daily-dcp-recovery2`, `12c445fa5371`, and the integration tip)

- `drivers/media/platform/apple/prores/` (`apple-prores-drv.c` 1192 lines, `apple-prores-desc.c`
  422, `apple-prores.h` 122, KUnit test 268) and `tools/asahi/prores-enc.c`: Ryan Murray's
  **encoder** for `apple,t8140-prores`, Aurora PRs #835 (2026-11-02), #840 (rate control),
  #848 (PMP performance request), #899 (DRAM floor). Register map and descriptor fields follow
  the m1n1 experiment; the T8140 descriptor "version 1" (frame header moved from 0x58 to 0x7c)
  came from Acelogic's J700 work (header comment of `apple-prores.h`). One job at a time, 128 KiB
  ring, 0x180-byte descriptors, completion by IRQ with a polling watchdog, reset through the
  power domain. Probe already powers the engine up and reads its ID and statistics-capacity
  registers. `of_match` is **T8140 only** on the daily and on `aurora/integration/aurora`
  (`e636747d9cdf`, 2026-11-08). [tree]
- Binding `Documentation/devicetree/bindings/media/apple,prores.yaml`: the daily has
  `const: apple,t8140-prores`; the integration tip (`fcae20144e24`, 2026-11-07 and later) has a
  generic `"apple,<soc>-prores", "apple,prores"` union for t6000, t6020-22, t6030-32, t6041,
  t8112, t8122, t8132 with 2-3 `reg` windows (core, wrapper, aux). [tree]
- DT nodes on the tip, all `status = "disabled"` except where a board enables them:
  `t600x-die0.dtsi`, `t602x-die0.dtsi`, `t6030/t6031/t6032-peripherals.dtsi`,
  `t6040-peripherals.dtsi` (T6041 `apr0`: core 0x4000, wrapper 16 MiB, aux at core + 0xc0000,
  one IRQ, `iommus = <&apr0_dart 1>`, `ps_scodec` power and reset), `t8112-peripherals.dtsi`
  (two DARTs), `t8122-peripherals.dtsi`, `t8140.dtsi` (wrapper 0x8000, SID 0, `ps_prores` plus a
  `pmp_report_prores` performance domain). [tree]
- Unmerged: `aurora/prores/t6000-apr-a0` (`186ce02e0e6f`, 2026-11-08) adds a `struct apr_variant`
  selected by compatible (descriptor builder, statistics register offsets, IRQ count, tunable
  tables), the T6000 "a0" descriptor v0 and the 48 engine RMWs from m1n1, and
  `t6000-qualification.rst`: a bounded first-job plan (one 320x240 Standard 4:2:2 frame,
  software-decoded and compared) with prerequisites (DMA-ownership repair of PR #925, PMP
  report provider for the SCODEC request, trial DTB with boot fallback). This is the template
  for any T6050 variant. [tree]
- Our own video series (`contrib/pending/video/patches/linux/`, worktree
  `/Volumes/linux-cs/wt-video` on `a0f2f30c967b`): 0007 adds `apple,t6050-prores` to the generic
  binding and 0008 (`t6050-media.dtsi`) already describes `apr0` and `apr0_dart`, disabled, with
  the note that no driver binds. The daily does not have that series, nor the generic binding.
- Userspace API: `V4L2_PIX_FMT_PRORES` (`'PRES'`), `V4L2_CID_MPEG_VIDEO_PRORES_PROFILE`
  (`+658`), P216/P416 input formats, Aurora-local (not in mainline). `tools/asahi/prores-enc`
  is the only client. [tree]

### m1n1 experiments

`~/Work/m1n1/proxyclient/experiments/prores.py` and `m1n1/hw/prores.py` (2022-04, author "R";
the same files are in every m1n1 checkout under `~/Work/agents/*`). Encode only, on the M1 Pro's
`/arm-io/apr0` through `dart-apr0`: powers the node through the ADT gates, applies 48 RMW
tunables to the engine, installs a 16 KiB descriptor ring, writes the five quantisation
matrices, submits one 1920x1080 NV24 frame and polls `IRQ_STATUS`; writes a hand-made `.mov`.
No decode, no T8112/T6041/T6050, no register names beyond ID, MODE, IRQ, ST0/ST1 and the ring.
m1n1 relicensed to GPLv2 on 2026-09-30 (`ce2b8a43`); Aurora cites the pre-relicense MIT commit
`f3ac615e` for the constants it copied. [m1n1][tree]

### How Asahi and Aurora drove it

Asahi: the 2022 experiment above, nothing in their kernel. Aurora: the T8140 encoder, written
from that experiment plus Acelogic's J700 diagnostic, qualified on J700 hardware; the T6000
port is paper-only (compile and KUnit, "the APR and its DART remain disabled in the shipped
DT"). Nobody has driven the M4 or M5 engines. [tree]

## 2. What the J716s ADT says

Read offline from `~/Work/studio-artifacts/adt-runtime-j716s.bin` with a 100-line standalone
parser (no values beyond the hardware description are reproduced here). [ADT]

- `/arm-io/apr0`: `compatible = "apr,n0"`, `device_type = "apr"`. Properties: `reg` (five
  windows), `interrupts` (two), `iommu-parent` (one phandle, `mapper-apr0`), `clock-gates` (one
  gate), `function-device_reset`, `function-bw_req_interrupt`, `function-set_perf_state_floor`,
  `function-get_valid_perf_states`, `coprovider-group`. **No** `pre-loaded`, `segment-names`,
  `firmware-*`, `tunables` or `iboot-*` property: a bare MMIO engine, no firmware, no per-unit
  table.
- Register windows (arm-io relative, translated through `ranges[0]` by +0x200000000):
  engine `0x48d000000` + 0x4000, wrapper `0x48c000000` + 0x1000000, auxiliary `0x48d0c0000` +
  0x4000 (engine + 0xc0000, where the T6041's third window sits), plus two 16 KiB windows at
  engine + 0x70000 and + 0x71000 that no other SoC's DT describes (role unknown; possibly the
  "AXI2AF" tunable block the macOS driver logs).
- Interrupts: two AIC lines 37 apart, the same spacing as the T8112, T6030 and T8122 pairs
  (the T6041 node lists one, the T8140's two are adjacent). The second is probably the
  bandwidth-request interrupt the ADT function points at SCODEC.
- Power (`/arm-io/pmgr` device table, decoded with m1n1's record layout): the engine's gate is
  `SCODEC_V`, the DART's `SCODEC_DART`, both virtual (no PS register) children of `SCODEC`
  (group 1 = pmgr `reg[1]` at `0x280900000`, offset `+0x190`, `notify_pmp`), whose parent
  `FAB7_SOC` (`+0x178`) is critical. `function-device_reset` and `function-bw_req_interrupt`
  name SCODEC; `function-set_perf_state_floor` names `SCODEC_V`. There is also a `PRORES` state
  (group 4 = pmgr `reg[46]`, `0x2380600000` `+0x1e0`, parent `FAB1_SOC`, `notify_pmp`) with
  children `PRORES_V` and `PRORES_DART`; on the J716s it gates only `/arm-io/dart-apr1`.
- DARTs: `/arm-io/dart-apr0` (`dart,t8110`, `real-time`, `sid = 1` = `mapper-apr0`,
  `vm-base 0x10000000000`, `vm-size 0x30000000000`, at `0x48d020000` + 0xc000, one IRQ) is
  apr0's. `/arm-io/dart-apr1` (`sid = 0`, three windows, the first at `0x230b020000` next to the
  AVD's DART, powered by `PRORES_DART`) has no engine: there is no `/arm-io/apr1` node.
  Reading: the M5 Pro die has the second engine's DART and power state but not the engine
  (the kext handles `/arm-io/apr0..apr3` and "Detected %d cores"); the M5 Max likely populates
  `apr1`. [ADT][kext] [inferred]
- Same block or new? The layout (windows, SID 1, SCODEC power = reset, wrapper at engine -
  16 MiB) is the T6041's, not the T8140's (wrapper 0x8000, SID 0, `PRORES` power, PMP perf
  request). The compatible `apr,n0` is a new generation name; `AppleProResHW` matches
  `apr,a0`, `apr,a1`, `apr,a2`, `apr,n0`, `apr,n1`, `apr,n2` (IONameMatch strings in
  `~/Work/studio-artifacts/macos-27.3/derived/kc.macho`) and logs "DevID %d, devVer %d,
  devRev %d" decoded from the ID register. Whether the T6041 is also `apr,n0` cannot be seen
  from here (no M4 ADT locally); the Aurora `adt-coverage` files name only the T8112 and T8140
  nodes. [tree][kext]
- macOS: `com.apple.driver.AppleProResHW` is loaded (`m5-kextstat.txt`, index 159, text
  0x7afab bytes) and publishes `IOProResHWDecode = 1` and `IOProResHWEncode = 1`
  (`m5-ioreg-l.txt`). Its strings show a descriptor ring (DRHead/DRTail/DRMemSize), separate
  `EncodeYCbCr`, `DecodeYCbCr` and `DecodeRaw` (ProRes RAW) command words, per-DevID
  "(ProRes) tunables", "SCODEC_PS(scodec_{sys, ced, ssw}) tunables", "(AXI2AF) tunables are set
  at iBoot", a PMP dashboard write, two reset paths ("Legacy" and "PSD"), DART error reporting
  and a hang detector reading st0/st1/st2. [kext]

## 3. Feasibility ladder

| Step | What | Effort | Risk |
|---|---|---|---|
| (a) observe | DT node + SCODEC/FAB7_SOC power states + DART; a Kconfig-gated probe that powers the engine up once, reads ID/MODE/IRQ/ring registers, powers down. No ring, no IRQ, no V4L2 node. | Drafted here (5 patches, compile-tested). One loop boot with the module blacklisted and loaded by hand: ~1 h including the payload. | Low. Reads stay in the first 0x120 bytes of the engine window, present on every known generation. Powering a `notify_pmp` state without the PMP: the ISP states were powered the same way in CAMERA I1 and passed. The DART binds as a plain `apple,t8110-dart`. Worst case is an SError on a read or a hung power-on, which the A/B stage 1 recovers. |
| (c) encode | A T6050 `apr_variant` in the existing driver: n0 engine (and wrapper, SCODEC) tunables, descriptor version, statistics register offsets, then Aurora's bounded first job and qualification list. | 2-4 weeks with a source for the constants; open-ended without one. The code side is small (the T6000 branch is ~460 lines); the constants are the work. | The T8140 tables must not be tried blind on n0 (unknown writes into a running DRAM client). Sources: a macOS trace (no m1n1 hypervisor for the T6050 in this project) or the kext's per-DevID tables (`kc.macho`, offline disassembly; Aurora's tree asks for clean-room provenance, so only register offsets/mask lists could be reused, and the repo rule allows names and offsets only). PMP: the engine's bandwidth request and perf floor go through SCODEC; Linux has no PMP on the T6050, so full-rate encode may throttle or stall. DMA ownership on timeout (PR #925) is still open upstream. |
| (b) decode | A V4L2 decoder that runs a known ProRes bitstream through the engine. | Months. Nothing in Linux or m1n1 knows the decode descriptor; it has to be reconstructed from scratch (macOS `DecodeYCbCr` command words, output surface layout, alpha/RAW variants), then a V4L2 stateful decoder model for a codec V4L2 has no decode format for. | Highest. Also the least useful first target: a software ProRes decoder on the 14 M5 Pro cores already decodes 4K in real time; the engine's value on Linux is encode power efficiency, not capability. |

Order: (a), then (c), then (b). The task's (b)/(c) order assumed decode is the simpler data
path; here it is the harder one, because the only published knowledge is encode.

### Is a Linux userspace path useful without ffmpeg/GStreamer plumbing?

No. Today only `tools/asahi/prores-enc` speaks the interface (raw NV16/P216/NV24/P416 frames in,
bare ProRes frames out, muxed by hand). ffmpeg's V4L2 m2m encoder wrappers cover h263, h264,
hevc, mpeg4 and vp8; GStreamer's `v4l2` plugin instantiates encoder elements only for coded
formats it knows; neither has `'PRES'`, P216 or P416. [knowledge] Needed for a usable path: an
ffmpeg `prores_v4l2m2m` encoder (fourcc map, profile control, 16-bit semi-planar input) or a
GStreamer element, the Aurora uapi additions upstreamed or carried in those projects, and a
muxer that accepts the frames. That is a userspace project of its own and is the reason (c)
should wait for a second consumer (Aurora's M4 Max or the Asahi M1/M2 users).

## 4. Private data, firmware, the "no blobs" rule

- Calibration or per-unit data: none. The ADT node has no tunables or calibration properties;
  the macOS driver's tables are per device ID (`SetProResTunablesByDevID`) and the AXI2AF
  tunables are written by iBoot before the OS. Nothing in a patch would be per machine. [ADT][kext]
- Firmware: none. No preloaded segments in the ADT, no firmware bundle in the kext's strings,
  and the Aurora binding states "It has no firmware". The repo's no-blob rule is not touched by
  any step; the AVE encoder (iBoot-preloaded firmware) is the one with that problem, not APR.
- What is private: register write lists (tunables) and descriptor layouts for n0, if taken from
  the kext rather than a trace. Offsets, masks and names can be cited; the repo keeps no dumps.

## 5. Recommendation

**Do (a) now, as a single observation boot; not now for (c); never plan (b) first.**

First concrete step: build a test payload from the daily plus
`contrib/pending/video/prores/patches/0001-0005`, boot it with `module_blacklist=apple_prores`,
then by hand:

```
dmesg -w &                               # watch for DART faults and SErrors
modprobe apple_prores                    # observe_stats=1 adds the T8140/T6000 stats offsets
dmesg | grep -i 'prores\|apr0\|dart'     # expect: "observing the ProRes engine", 11 registers
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary | grep -i 'scodec\|fab7'   # scodec off again after 0.5 s
```

Pass: the DART at `48d020000` binds, the engine logs its registers, `scodec` returns to off, no
fault, lid sleep and resume still work with the module loaded. Record the ID word in the
results (it is a per-SoC value, fine to publish) and send it to Aurora's T6000 thread: if it
matches what their M4 Max users read, the T6041 and T6050 variants can share tables and the
cost of (c) halves. Fail or hang: leave the row at "observed, no data path" and stop.

If the video series lands in the daily first, drop 0001 and 0002 here (0007/0008 there carry
the same binding entry and nodes with the same labels) and keep 0003-0005.

## 6. What was written where

- `contrib/pending/video/prores/FEASIBILITY.md`: this file.
- `contrib/pending/video/prores/patches/` (against the daily, `12c445fa5371`; each checked
  with `git apply --check` on the clean daily worktree; no commit anywhere):
  - `0001-dt-bindings-media-apple-prores-Add-T6050.patch`: `"apple,t6050-prores", "apple,prores"`
    with three named windows and a required reset; T8140 unchanged.
  - `0002-arm64-dts-apple-t6050-Add-the-ProRes-engine.patch`: new `t6050-prores.dtsi` (included
    from `t6050-max.dtsi`): `ps_fab7_soc` and `ps_scodec` in `pmgr1`, `apr0_dart` and `apr0` in
    `die0`, both disabled. ADT provenance in the file comment.
  - `0003-media-apple-prores-Observe-the-T6050-engine-probe-only.patch`:
    `VIDEO_APPLE_PRORES_T6050_OBSERVE` (bool, default n) and an `observe_only` variant: the
    probe stops after power-up and register reads; `observe_stats` module parameter; system
    sleep and remove skip the V4L2 objects that were never created.
  - `0004-arm64-dts-apple-t6050-j716s-Enable-the-ProRes-engine-for-observation.patch`: both
    nodes `okay` on the board (test payload only).
  - `0005-arm64-configs-j716s-Build-the-ProRes-observer.patch`: `CONFIG_VIDEO_APPLE_PRORES=m`,
    `CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y` in `j716s.config`.
- Compile test (2026-11-08, the `build-kernel-r2.sh` container recipe: Fedora 43, clang 21.1.8,
  rustc 1.99.1, aurora bindgen 0.73.2, the daily-dcp `.config` whose only difference after
  `olddefconfig` is the new bool): `drivers/media/platform/apple/prores/` builds with `W=1` and
  no warnings with `VIDEO_APPLE_PRORES_T6050_OBSERVE=y` and `=n`; `apple/t6050-j716s.dtb`
  builds with no dtc warnings; `dt_binding_check DT_SCHEMA_FILES=media/apple,prores.yaml` and
  `CHECK_DTBS=y` on the J716s DTB pass (the schema complaints in the log are pre-existing
  `apple,tunable*` ones in other bindings); `checkpatch --strict` is clean apart from the
  "new file, MAINTAINERS?" note on 0002. Four minutes of build, no Image. Logs:
  `/Volumes/linux-cs-gpurec/wt-prores-out/log/`.
- Scratch left on disk (safe to delete): `/Volumes/linux-cs-gpurec/wt-prores` (alternates-backed
  checkout of the daily commit with the patches applied, uncommitted) and
  `/Volumes/linux-cs-gpurec/wt-prores-out` (objects and `log/`). Nothing was written to
  `/Volumes/linux-cs` (14 GiB free, under the 15 GiB floor).
- Not touched: the README status row (stale, see above), the video series, the MacBook.
