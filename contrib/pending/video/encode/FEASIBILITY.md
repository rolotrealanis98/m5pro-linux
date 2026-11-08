# Hardware video encode (AVE, H.264/HEVC) on the J716s: feasibility

Desk study, 2026-11-08, on the Mac Studio only; nothing booted. Covers the Apple
video encoder (`AVE`, ADT `/arm-io/ave0`, macOS `AppleAVE2`). ProRes (`apr0`) is a
sibling study; the overlap is listed at the end. No per-unit values are in this
file or in the patches (node and property names, sizes and register offsets only).

## Findings, shortest form

1. **The T6050 AVE is a firmware coprocessor, not a register-driven block and not an
   RTKit ASC.** It boots its firmware through a private mailbox/scratch protocol
   (boot magic, a boot-config block, a code-base register, two shared-memory command
   rings), the same family as the A18 Pro (T8140) and M4 Pro (T6041) encoders. Its
   firmware is **preloaded by iBoot** into DRAM below the OS: the ADT node is
   `pre-loaded = 1`, `segment-names = "__TEXT;__DATA"`, TEXT 0x158000 and DATA
   0x134000 bytes (larger than T6041's 0x14c000/0x12c000 and T8140's 0x14c000/0x130000).
   The build in the J716s firmware bundle is `AppleAVE2FW-9013.55.1.release`
   (`~/Work/studio-artifacts/j716s-fw/Firmware/ave/AppleAVE2FW_H17D.im4p`); the macOS
   27.3 (26C5035r) kext is `com.apple.driver.AppleAVE2` 913.63.1, classes
   `AppleAVE2Driver` / `AppleAVE2UserClient` (`macos-27.3/m5-kextstat.txt`,
   `m5-ioreg-l.txt`).
2. **No firmware blob is needed anywhere in Linux**: the loader reserves the two
   preloaded segments and hands them to the kernel (`memory-region` +
   `iommu-addresses` + two CRC32 strings under `/chosen`); the driver builds every
   command itself. That is the same arrangement as DCP/ISP/ANE and is compatible with
   the project's no-blobs rule. The build iBoot preloads follows the stub's macOS
   version (aurora's M4 Pro note: a 25G83 stub preloads the 25G83 build), so our
   J716s stub (27.3 beta 1, `docs/boot-and-recovery.md`) decides the build, not
   anything we ship.
3. **The "probe-only driver" of the README is a misreading of the situation.** The
   aurora-silicon `apple-ave` driver (`drivers/media/platform/apple/ave/`, ~7.9 k
   lines, Ryan Murray / Acelogic, Oct-Nov 2026) is a complete V4L2 stateful
   memory-to-memory encoder: H.264 (Baseline/Main/High) and HEVC Main (and Main 10
   from P010), NV12 input, B-frames, VBR/CBR, 320x240 to 2560x1600, up to two
   streams, runtime PM, system sleep, firmware recovery, KUnit and host tests. It
   encodes on T8140 (MacBook Neo, firmware 9003.78.0) and on T6041 (M4 Pro, the
   25G83 build) in aurora's PR branches. **Only the T6050 *variant* is probe-only**,
   and that variant is ours (`contrib/pending/video/patches/linux/0006`). The daily
   kernel already builds `apple-ave.ko`
   (`~/Work/agents/gpu-recovery/kbuild-r2/config.daily-dcp`: `CONFIG_VIDEO_APPLE_AVE=m`;
   `targets-daily.txt`). It never binds today because the J716s DT has no node and
   m1n1 performs no hand-off.
4. **Two things gate everything beyond probe, and both are data, not code:**
   - the T6050's *boot identity*: `boot_device_id` and `device_type` in the variant
     table (`ave-drv.c`: T8140 29/27, T6041 27/25, T8112 15/13, T6000 11/9; T6050
     unknown). Without them `boot_qualified` stays false and `ave_fw_check_boot()`
     returns `-EOPNOTSUPP` before anything touches the coprocessor;
   - a *command layout* for the firmware's TEXT CRC (`ave-layout.c`,
     `ave_layout_for_crc()`): 9003.78.0 (two CRCs, T8140 and T6041's 25G83 build)
     encodes; 6070.11.1 (T6000/T8112) is lifecycle-only; a layout "observed on J616s
     with macOS 27.0 26A428" exists but is keyed to no CRC. 9013.55.1 has none.
     Layouts come from captures of macOS's commands (aurora compared debugfs dumps
     of the built Start/Process images against reference captures); the M4 Pro
     case shows that once a build's layout is known, a new SoC is a ~20-line patch
     (`d6c1322d85e3 media: apple: ave: encode on the M4 Pro`).

## What the ADT says (J716s, `/arm-io/ave0`, `dart-ave0`, `pmgr`)

Source: `~/Work/studio-artifacts/adt-runtime-j716s.bin` (parsed with m1n1's `adt.py`)
and the DT plane of `macos-27.3/m5-ioreg-dt.txt`. Addresses are on the
`soc@2280000000` bus that `0008-arm64-dts-apple-t6050-Add-the-media-engines.patch`
introduces (ADT `arm-io` ranges add 0x2_0000_0000).

| Item | Value (names, sizes, offsets) |
|---|---|
| `compatible`, `device_type`, `soc-id` | `ave2`, `ave`, `t6050`; `coprovider-group = "ave"` |
| `reg` | codec 0x45c000 @ 0x2283100000; coproc 0x800000 @ 0x2283800000; mailbox 0x4000 @ 0x2283050000; a 0x7e64 window at pmgr4 + 0x1c0 (the VENC0_SYS power-state register, as the five-`reg` T602x bindings describe it as `pmgr`); a 0x8000 window @ 0x2282000000 (`fabric`/`pio` class). The DT uses the first three, like T8140/T6041 (binding `maxItems: 3`). |
| `interrupts` | 2435 (mailbox), 2790, 2789, 2792, 2791 (codec, handled by the firmware); AIC die 0 |
| `power-gates` = `clock-gates` | ids 651, 527, 528, 529, 530, 526 = VENC0_SYS_V, VENC0_PIPE4, PIPE5, ME0, ME1, VENC0_DMA. Parents: VENC0_DMA -> VENC0_SYS (387) -> FAB0_SOC (384, critical). ME1's parent is ME0. VENC0_SYS_V (651) and VENC0_SYS_DART (650, the DART's gate) have no PS register; VENC0_FAST 647, VENC0_MEM_FAST 648, VENC0_SOC_VMAX 649 are PS-less voters. A full VENC1_* set exists with no PS registers (second encoder of larger dies; absent as a node on the J716s). |
| perf floor | `function-set_perf_state_floor` / `function-get_valid_perf_states` -> `/arm-io/pmgr`, entity 651 (VENC0_SYS_V), arg 0x20. This is the T6050 form of the binding's optional `perf` power domain (T8140 uses a PMP report domain; the daily driver holds `perf` while powered). Not wired in the DT yet: probe does not need it, full-speed encoding will. Related PMP tunables `ave0-af-bw-*` appear in the ioreg (see `contrib/pending/gpu/pmp/PMP-J716S.md`). |
| `segment-ranges` | two entries, TEXT size 0x158000 remapped at the DART window base, DATA size 0x134000 remapped right after TEXT. The DT's `apple,dma-range` (base + 0x4000, 4 GiB) therefore overlaps the firmware, which the loader's `iommu-addresses` reservations carve out, exactly as on T8140. |
| `dart-ave0` | `dart,t8110`, `dart-id` 36, interrupt 2432, `page-size` 16 KiB, `sid-count` 16, `sid = <0 12>`, **`bypass-12`** (SID 12 runs in bypass under macOS), `vm-base` 1 TiB, `vm-size` 3 TiB, `remap`, `flush-by-dva`, `avoid-tlbi-in-map`, `dapf-instance-0`, `piogw-ps-protection`, `dart-tunables-instance-0/1`. Two `TRAD` instances: 0 `CPUDART` at +0xa0000, 1 `DART` at +0x80000 (0008 has them this way round; T8140's DT numbers them the other way: harmless for probe, to be checked before (c)). `mapper-ave0` SID 0 is the only mapper. |

`bypass-12` matters later: the driver refuses to start the firmware while any
stream of either AVE DART bypasses (`cc334311860c`), because the DMA window is
numerically the first 4 GiB of DRAM. apple-dart resets the streams at probe, so
this does not block (a); whether SID 12 is a stream the firmware itself drives
is a question for (c).

## The existing driver, and what is missing to "encodes one frame"

Read in `/Volumes/linux-cs/wt-video` (branch `video/t6050`, integration/aurora +
the video series) and `aurora/integration/aurora`:

| Layer | State | File |
|---|---|---|
| Hand-off check (segments, sizes, overlap, IOMMU mapping, TEXT/DATA CRCs vs `/chosen`) | done, generic | `ave-fw.c: ave_fw_probe()` |
| Coprocessor boot (VCBAR, boot config block, scratch magic, CTRL run, hello, 7-channel ring discovery) | done for the v40 register family (T8140/T6041); T6050 assumed v40 | `ave-fw.c: ave_fw_boot()`, `ave-ipc.c`, `ave-regs.h` |
| Config/Open/Start/Process/Complete/Close/Halt, replies, recovery | done (9003 ABI); 6070 lifecycle-only | `ave-cmd.c`, `ave-sess.c`, `ave-abi.c`, `ave-writer.c` |
| Command layouts | 9003.78.0 (two CRCs), 6070.11.1, 26A428 (unkeyed) | `ave-layout.c`, `ave-image.c` |
| V4L2 m2m (NV12/P010 -> H.264/HEVC Annex B, controls, vb2) | done | `ave-v4l2.c`, `ave-vb2.c` |
| Docs, tests | admin guide, `abi.rst`, KUnit, host tests | `Documentation/admin-guide/media/apple-ave.rst` (integration tip), `ave/tests/` |
| T6050 variant | probe-only (sizes, v40 regs, no identity, `boot_qualified` unset) | our `0006` |
| T6050 DT nodes (pmgr4, VENC states, two DARTs, `ave`) | written, disabled | our `0008` (`t6050-media.dtsi`) |
| J716s enable, config | **new, this directory** | `patches/linux/0001`, `0002` |
| Loader hand-off | aura: yes (`dt_set_ave_node`, our `patches/aura/0001` adds t6050); **m1n1: none until `patches/m1n1/0001` here** | `~/Work/agents/aurora-prs-2/ref/aura/src/kboot.c`, `~/Work/m1n1/src/kboot.c` |
| Reverse-engineering notes | aurora's derived ledgers (SPEC-6070-lifecycle.md) are not in the tree; no m1n1 `proxyclient/experiments` for the AVE exist anywhere under `~/Work` (only `avd*.py`) | |

Missing between probe and one frame, in order: the T6050 boot identity; the
9013.55.1 TEXT CRC keyed to a layout; that layout itself (Start ~0x3000-0x14000
bytes and Process images, about 150 named fields per codec plus constant words);
qualification of the boot-config words, DMA aperture and slice-header/metadata
extraction for a 27.x build (the 26A428 notes list exactly these as open).

## Feasibility ladder

| Step | What | Effort | Risk | Blockers |
|---|---|---|---|---|
| (a) probe-only bind | m1n1 hand-off + `0005/0006/0008` + the two patches here. Expected: m1n1 `FDT: /soc@.../video-codec@2283100000: AVE firmware TEXT ...`, kernel `apple-ave ...: probe only: firmware TEXT <crc> DATA <crc> needs qualification`, `/dev/videoN` present, any `VIDIOC_STREAMON` fails with `ENOTSUPP`. | written; one attended boot (it fits the AVD/JPEG test slot: same DTB, same series) | low: a 2.7 MB no-map reservation and two DARTs powered through VENC0_SYS; the driver registers nothing that starts the coprocessor | none |
| (b) boot + hello | fill `boot_device_id`/`device_type`, add a lifecycle-only layout entry for the 9013.55.1 CRC, set `boot_qualified`, run the hello and ring discovery, then Halt. | 1-3 sessions once the identity is known | medium: a firmware that does not answer keeps the VENC domains on and the driver marks it broken (reboot clears it); wrong identity may hang the coprocessor | the identity. Sources: (1) an m1n1 hypervisor trace of macOS starting the encoder (the project already boots macOS under m1n1 hv for DCP/GPU; the boot-config block and scratch writes give the numbers directly); (2) the `AppleAVE2` kext in `macos-27.3/kernelcache/kernelcache.release.mac17j` (per-SoC table; disassembly, names and offsets only). Guessing from the T8140/T6041 pattern is not acceptable. |
| (c) one H.264 frame via V4L2 | the 9013.55.1 command layout and its qualification (if it is the 26A428 family, keying + the open items; if not, a new ledger) | weeks, with macOS command captures; the T8140 work took aurora about a month with captures | medium-high: corruption class bugs (the DART-bypass audit exists for a reason); `bypass-12` | captures from the MacBook under m1n1 hv (VTCompressionSession, H.264 and HEVC, 1080p, with and without B-frames) |
| (d) usable for OBS/ffmpeg | nothing new in the kernel once (c) holds; the `perf` floor domain (VENC0_SYS_V) for full speed; the 2560x1600 limit vs the 3456x2234 panel (aurora's `ave/4k-window` branch) | days of userspace plumbing | low | (c) |

Userspace glue for (d) on Omarchy (Arch): ffmpeg's `h264_v4l2m2m`/`hevc_v4l2m2m`
(Arch builds ffmpeg with `v4l2_m2m`), GStreamer `v4l2h264enc`/`v4l2h265enc`
(gst-plugins-good), `wf-recorder -c h264_v4l2m2m`. OBS has no V4L2 M2M encoder
plugin: recording goes through its FFmpeg custom output with `h264_v4l2m2m`.
Browsers (Firefox/Chromium WebRTC) use VA-API only on desktop Linux: **video calls
get nothing from this encoder** without a VA-API shim that does not exist.
Zero-copy from the GPU needs DMA-BUF import into the encoder's DART (vb2
dma-contig behind an IOMMU maps scatter lists to one IOVA range, so it is
plausible, untested anywhere on Apple hardware).

## Worth it? AVE vs ProRes vs software on 18 cores

- **Software encode**: x264 `veryfast`/`faster` does 1080p60 screen recording on a
  few of the 18 cores and 4K30 realtime with headroom; the cost is power, fans and
  CPU stolen from the thing being recorded. Video calls are 720p/1080p VP8/VP9/AV1
  in software anyway: no hardware encoder on Linux helps them today.
- **AVE**: the win is long battery-powered screen recording and 4K/retina captures
  at a watt or two instead of 20-40 W; the standard V4L2 API means every tool
  works once it works. It is the one media block whose driver is otherwise
  complete.
- **ProRes** (`apr0`, SCODEC): binding only, "the ProRes driver programs only
  T8140's engine"; its users are editing workflows that are not on Linux/arm64.
  Farther away and less useful here.
- Verdict: for this machine the AVE is worth (a) now (cheap, informative) and
  worth (b)/(c) only as a capture-and-hand-to-aurora effort, not as our own
  reverse-engineering project. Both encoders sit behind GPU, display and power
  work in priority; the README row can stay "not realistic for now" with the
  text "probe-only prepared: loader hand-off and DT written, nothing beyond".

## Overlap with the ProRes study (coordinate)

- `0008` is shared: `t6050-media.dtsi` holds both `ave` and `apr0`, the
  `soc@2280000000` container and the `pmgr4` block; one patch, two owners.
- Power: no shared domain. AVE: VENC0_DMA/PIPE4/PIPE5/ME0/ME1 under VENC0_SYS
  under FAB0_SOC (pmgr4). ProRes: SCODEC under FAB7_SOC (`pmgr1`). The
  perf-floor mechanism (`function-set_perf_state_floor` into pmgr) is the same
  shape on both (`apr0` names entity 643, the AVE 651).
- DARTs: separate (`dart-ave0` id 36, two instances; `dart-apr0` id 37, one
  instance, SID 1, `clamp-tlimits`, `trans-idle-timeout`).
- The attended test slot: both probe-only tests can share one boot.

## Recommendation and first step

Build the next video test kernel/DTB with the video series plus
`encode/patches/linux/0001-0002`, and the test m1n1 with `encode/patches/m1n1/0001`;
boot it attended, collect three lines (m1n1's `FDT: ... AVE firmware ... CRC`,
the driver's `probe only: firmware TEXT ... DATA ...`, and `v4l2-ctl --list-devices`)
plus `dmesg | grep -i -E 'ave|dart'`. The TEXT CRC is the datum everything else
keys on; send it, with the ADT facts above, to aurora's AVE lead (the T6041 and
26A428 work is theirs) and ask whether 9013.55.1 is in the 26A428 family. Only
then decide on (b): the hypervisor trace is the right tool for the identity and
the captures at once, and the project already has the hv patches for the T6050.

## What is in this directory

- `patches/m1n1/0001-kboot-Hand-over-the-preloaded-AVE-encoder-firmware.patch`:
  the m1n1 port of aura's `dt_set_ave_node` (compatibles t6000/t6041/t6050/t8112/
  t8140; `dt_reserve_asc_firmware()` with the remap addresses; `tinf_crc32` of
  both segments before anything maps them; `/chosen/aurora,ave-{text,data}-crc32`;
  node disabled with a reason on failure). Applies to `~/Work/m1n1` `m5-t6050`
  (459a3af2); `kboot.o` compiles with the Homebrew clang toolchain and the file is
  clang-format clean. The full image was not linked here (this shell's rustup has
  no `aarch64-unknown-none-softfloat`). It touches the same `kboot_prepare_dt`
  lines as `contrib/pending/ane/patches/m1n1/0001`; apply either first, the other
  with an offset.
- `patches/linux/0001-arm64-dts-apple-t6050-j716s-Enable-the-video-encoder-probe-only.patch`
  and `0002-arm64-configs-j716s-Build-the-video-encoder-driver.patch`: against the
  daily tree (`/Volumes/linux-cs-gpurec/wt-daily-dcp-recovery`, 12c445fa5371) after
  `video/patches/linux/0006` and `0008` (which apply there; `0005`, `0007`,
  `0009-0011` need a rebase onto the daily, they were made on `j716s-series`).
  Compile-tested: the J716s DTB built from the daily sources plus `0008` and `0001`
  with `clang -E` + `dtc` 1.8.1 (the same pipeline reproduces the daily's own
  `t6050-j716s.dtb` with no content difference); `ave`, `ave_dart0`, `ave_dart1`
  come out `okay`. No kernel objects were built (the module is already in the
  daily's configuration and the driver source is unchanged by these patches).

Sources read: `contrib/pending/video/patches/{linux,aura}/*`, `contrib/pending/video/test/*`,
`contrib/pending/ane/patches/m1n1/0001`, `/Volumes/linux-cs/wt-video` (`drivers/media/platform/apple/ave/*`,
`Documentation/devicetree/bindings/media/apple,t8140-ave.yaml`, `arch/arm64/boot/dts/apple/{t8140.dtsi,t604x.dtsi,t6040-j773s.dts,t8140-j700.dts}`,
`git log` of the driver incl. `d6c1322d85e3`, `244eddc0a098`, `cc334311860c`, `90534c57928c`),
`aurora/integration/aurora:Documentation/admin-guide/media/apple-ave.rst`,
`~/Work/agents/aurora-prs-2/ref/aura/src/kboot.c`, `~/Work/m1n1/src/kboot.c`,
`~/Work/studio-artifacts/{adt-runtime-j716s.bin,j716s-fw/Firmware/ave,macos-27.3/*}`,
`~/Work/agents/gpu-recovery/{build-kernel-r2.sh,kbuild-r2/config.daily-dcp,kbuild-r2/targets-daily.txt}`.
