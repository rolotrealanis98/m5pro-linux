# AVD + JPEG "boot A" test for the J716s (2026-11-08)

One self-reverting test payload that boots the daily kernel plus the T6050 video-decoder (AVD) and JPEG
patches, with both drivers loaded by hand after the boot. Prepared on the Studio; **not booted yet**.
Studio-side builders in `avd-a/`; the runner that drives the MacBook stays private (host address).

## What it is

| piece | value |
|---|---|
| base | the daily kernel `7.3.0-g0933f881d736` (branch `j716s-video-observe`: `j716s-daily-dcp-recovery2` + video 0006/0008 + encode 0001/0002 + prores 0001/0003-0005), payload `daily-dcp-rec-video-20261108-26ca25f0` (the restore target) |
| branch | `j716s-avd-a` in the main repository (`/Volumes/linux-cs/linux`; live sparse worktree `~/Work/agents/avd/wt-tmp`), tip `83dd5fa316b5`; series in `avd-a/SERIES.txt`, resolved patches in `avd-a/patches/0001-0009` |
| patches | Aurora's `media: apple: avd: don't reset the T6041 decoder in recovery` (0c94baf620c7, cherry-picked: it defines `AVD_QUIRK_NO_RECOVERY_RESET`, which 0002 uses and the daily lacks), then video 0001-0004 (AVD and JPEG bindings + drivers: `apple,t6050-avd` with the `apple,t8142-avd` fallback, `AVD_QUIRK_NO_RECOVERY_RESET`; JPEG HWREV `0x110010`), 0009/0010 (the J716s board file enables `avd`, `avd_dart`, `jpeg0`, `jpeg1`, `jpeg_dart`), 0011 (`j716s.config` records `CONFIG_VIDEO_APPLE_AVD=m` / `CONFIG_VIDEO_APPLE_JPEG=m`), plus one comment-only commit recording the ADT windows and the upstream register/interrupt mapping next to the `avd` node. 0005/0007 left out (encoder binding; ProRes binding already replaced in the base); 0006/0008 already in the base. Three hand-resolved conflicts, all end-of-file collisions or a plain enum where the patch expected a `oneOf`; no content changed |
| DT | `t6050-media.dtsi` keeps every media node `status = "disabled"`; `t6050-j716s.dts` turns on the decoder, its DART, both JPEG engines and their DART for this test (AVE probe-only and the ProRes observer stay as in the daily). The built DTB differs from the daily's in exactly those five `status` lines (decompiled diff: 10 lines) |
| config | the daily's `.config` unchanged (`olddefconfig` diff empty): AVD and JPEG were already `=m` and in the module list; the rebuilt `apple-avd.ko` now carries the T6050 variant (`alias of:N*T*Capple,t6050-avd`, `firmware: apple/avd-fw-v5-t2.bin`), `apple-jpeg.ko` the T6050 HWREV |
| kernel | release `7.3.0-g83dd5fa316b5`, built with the daily's container recipe (`avd-a/build-kernel-avd.sh`) from a `git archive` of the branch on the container's own disk (see "Build-host incident"), warnings `20` (daily: 20) |
| loader | `m1n1-plain-n1-dt-gpu-dcp-phfix-ave` (`fb29185c`, pinned): the loader the daily boots with |
| payload | `avd-a-test-20261108-732e0984.bin` sha256 `732e0984fd97d46a98007bad4db7c859d1d3f88008863e65e2287e175349d943`, label `avd-a-test`, built by `avd-a/mk-avd-a-test.py` (the loop-safety `mk-daily.py`): `m5.selftest=1` + `watchdog.open_timeout=300`, the daily's VRR/pause bootargs, the pinned `initramfs-ftab-wdt2`; modules `modules-7.3.0-g83dd5fa316b5.tar.zst` |
| firmware | `apple/avd-fw-v5-t2.bin` sha256 `e3c3c3fa8f7945953342b3de9a58dee0a70faab3dea44827b3a71c416beca440`, 0x12000 bytes, built on the Studio from the local clone of **aurora-silicon/avd-fw** at `ea3a65cc` (`avd-a/build-avd-fw.sh`: Homebrew clang 23 `--target=arm-none-eabi`, ld.lld, llvm-objcopy; two builds byte-identical; the tree's `check-images.py` and host queue test pass). Not a copied Apple image |

## Firmware: what the driver wants and how it ships

- Aurora's `drivers/media/platform/apple/avd` has two backends. `apple,t8142-avd` (and our T6050 copy) is open-firmware only:
  `avd_backend_select()` → `request_firmware("apple/avd-fw-v5-t2.bin")` → the raw CM3 image is copied into the `code`
  window (`memcpy_toio`, must fit 0x14000 on T6050; 0x12000 does) and booted; the Kconfig names
  https://github.com/aurora-silicon/avd-fw as the source. Issue #24 says "Asahi's avd-fw": the Asahi repository is the
  upstream-driver image (different SRAM apertures, no queue ABI 2 info block); Aurora's fork is the one this driver's
  `avd-backend-queue.c` (ABI 2, info block at SRAM +0x7fc0) matches. We built Aurora's.
- Tier: v5 tier 2 is the image whose PIODMA/SRAM aperture is `+0x94000` from the AVD base (made for T6040); T6050's
  SRAM is also at `+0x94000` (ADT: code `+0x1080000`, SRAM `+0x1094000`), so the queued transport should accept it
  (`firmware SRAM aperture ... wrong image tier` in dmesg otherwise, then the legacy transport). The image has no
  `CODECS:` trailer, so the variant's four codecs (HEVC, H.264, VP9, AV1) are all advertised.
- Generation: ADT `avd-version 4` = T8142 (M5) = T6040/T6041 (M4 Pro/Max) generation; the T6041 variant in the daily
  loads the same `avd-fw-v5-t2.bin` (with an Apple-image backend first, which T6050 does not have). The decoder is the
  M4's generation with T8142's VP layout; the VP pool size of T6050 is still inferred (see 0002).
- Shipping: **a file the runner copies to `/lib/firmware/apple/` on the root**, not the initramfs. The module is loaded
  by hand after `switch_root`, when `request_firmware` reads the real root; the pinned initramfs stays the one the daily
  and the observe test booted with, so the boot path of the payload is unchanged. The runner removes the file at the
  end unless it was already there or `KEEP_FW=1`.

## What the boot should show

1. Boot like the daily (same loader, same bootargs plus selftest/watchdog): `uname -r` = `7.3.0-g83dd5fa316b5`, DCP display, Hyprland;
   `/sys/bus/platform/devices/2309080000.avd` and `2281000000.jpeg` / `2281060000.jpeg` present with no driver
   (modprobe.d blacklist); the DARTs `2309020000.iommu` and `2281020000.iommu` bound by `apple-dart` at boot
   (`apple-dart 2309020000.iommu: ...` lines), `avd_sys` and `jpg` domains visible in `pm_genpd_summary`.
2. `modprobe apple_avd`: `avd 2309080000.avd: booting hw version: xxxx` (the CM3 came up), then one of
   `using queue transport (N frames in flight)` (expected; N ≤ 7 on this variant) or
   `no queue info block ... using legacy transport` / `wrong image tier, using legacy transport` (works, slower, one
   frame in flight). Failure signatures: `cm3 did not start: flag0 ...`, `firmware probe boot failed: -ETIMEDOUT`
   (the device still registers; decode would then fail), `Direct firmware load for apple/avd-fw-v5-t2.bin failed`
   (the copy did not land). A `/dev/videoN` whose sysfs device is `2309080000.avd` appears; `v4l2-ctl --list-devices`
   lists it next to the AVE's `/dev/video0`; `--list-formats-out` shows `S264`, `S265`, `VP9F`, `AV1F` (stateless).
3. `modprobe apple_jpeg`: `apple-jpeg 2281000000.jpeg: JPEG encoder, HWREV 0x111010` twice (both engines) and two more
   `/dev/videoN`. `unsupported HWREV` means the ADT value was not what the register reads; the driver refuses, nothing else.
4. Decode: a 2 s 640x360 H.264 clip generated on the root, through GStreamer `v4l2slh264dec` (stateless), md5 against
   `avdec_h264`. `DECODE: PASS bit-exact` is the goal; `hw and sw differ` = frames came out but content differs (VP layout /
   MV size inference wrong); `FAIL (hardware pipeline produced nothing)` with `open firmware error` or a timeout in dmesg =
   the submission path. `ffmpeg -c:v h264_v4l2m2m` is run too and is expected to fail: the AVD is a stateless decoder, the
   stateful API cannot bind it (recorded, not a failure).
5. JPEG: Aurora's `apple-jpeg` is an **encoder** only (NV12M/NV16M → JPEG); "JPEG decode" in #24 is not something this
   driver offers. The test encodes 5 NV12 frames through `v4l2jpegenc` and decodes them back in software.
6. No `apple-dart ... fault`, no `SError`, `MemAvailable` within the daily's band; then the daily is written back and the
   machine reboots into `7.3.0-g0933f881d736`.

Everything on the root is optional and skipped with a note when missing: `gst-plugins-bad` (v4l2codecs:
`v4l2slh264dec`), `gst-libav` (`avdec_h264`), `gst-plugins-good` (`v4l2jpegenc`), `ffmpeg`, `v4l-utils`. The last boot
showed `v4l2-ctl` present; the GStreamer pieces are unknown until the run.

## Risks

- **Self-reverting boot**: `m5.selftest=1` + the watchdog opener + `boot.bin.prev` cover a kernel that does not come up;
  the DTB only enables nodes whose drivers are blacklisted from autoloading, so the boot itself exercises nothing new but
  the two DARTs probing (`apple-dart`, `apple,t8110-dart`, powered through `avd_sys`/`jpg`; the same driver that runs the
  display, ISP and AVE DARTs).
- **The modprobe steps run on a live system**: a hang powering `AVD_SYS` up or booting the CM3 would wedge the running
  kernel, not the boot. The slot would still hold the test payload; after a power cycle it boots the test kernel with the
  drivers blacklisted, and `run-avd-a.sh --restore-only` puts the daily back. The battery driver is on (attended-style
  payload, as the observe tests).
- **Recovery reset**: 0002 sets `AVD_QUIRK_NO_RECOVERY_RESET` (the M4 Max hangs on that reset); a decode timeout retires
  the decoder until the next boot instead. The daily's stock `apple-avd.ko` would have bound through the `t8142` fallback
  *without* the quirk; the rebuilt module is why the payload's modules must be installed first (the runner checks).
- **Inferred values**: T6050 VP pool/slot bases (T8142's), H.264 MV size, JPEG HWREV from the ADT, the JPEG DART
  `apple,dma-range`. Wrong VP values show as differing md5 or firmware errors, not as hangs.
- **Firmware provenance**: built from Aurora's tree at a pinned commit, reproducible; if the T6050's PIODMA header size
  differs (the open question noted in avd-fw's `docs/queue.md`) the queued transport reports it and legacy mode is used.

## What Rolando needs to do

- Nothing before the run; nothing to hold or watch. From the Studio: `~/Work/agents/avd/run-avd-a.sh <payload>`.
  It is unattended-safe in the sense above: the boot self-reverts; a wedge *during* the modprobe/decode steps needs a power
  cycle and then `run-avd-a.sh --restore-only` (or the next loop's restore). Optional on the root beforehand, for a full
  result instead of skipped steps: `gst-plugins-bad gst-plugins-good gst-libav ffmpeg` (Arch names).
- The firmware `make` in #24 is done here (Aurora's tree, not Asahi's); nothing to build on the MacBook.

## Build-host incident (2026-11-08, Studio)

The first build ran in the worktree `/Volumes/linux-cs-gpurec/wt-avd` with the daily's recipe while two other container kernel
builds were running on the Studio. Each such build on a virtiofs share holds 60-110k host file handles
(`com.apple.Virtualization.VirtualMachine`); the host reached `kern.maxfiles` (524288), the build died with "Too many open
files in system", and the disk images behind two shares answered ENXIO (`apfs ... tx_enter() failed: 6` for disk38 =
`linux-cs-gpurec` and disk32 = `linux-cs-capture`). Both volumes stayed mounted but unreadable ("Device not configured");
the gpurec image carries the daily's own worktrees (`wt-daily-dcp-recovery`, `wt-video-observe`, plus other sessions'
`wt-hdr`, `wt-sep`, `wt-aurora-prs`). The branch itself is safe in the main repository (`/Volumes/linux-cs/linux`, healthy).
A fresh sparse bundle made for this build died the same way during its checkout, so the kernel was built from `git archive`
of the branch on the container's own ext4 disk with only the results directory shared. **For Rolando:** `hdiutil detach
-force` + re-attach of `linux-cs-gpurec.sparsebundle` and `linux-cs-capture.sparsebundle` (APFS replays its journal; the
session that wrote this was not allowed to detach them), then `git worktree prune`; and not more than one or two container
kernel builds at a time on this host, or a higher `kern.maxfiles`.

## Open questions

- Is `avd-fw-v5-t2`'s aperture accepted by the T6050 CM3 (queue transport) or does it fall to legacy? The dmesg line says.
- T6050 VP pool size and the `0x2388090000+0x4000` second ADT window (no other ADT node covers it; neither driver uses it).
- The ADT lists only two decoder interrupts (2417, 2418); upstream's binding wants seven named ones for M1-M3. Mapped
  as `mbox0`/`mbox1` in the `t6050-media.dtsi` comment; the other five have no T6050 numbers.
- HEVC/VP9/AV1 decode and the deliberate-timeout test (does the retire path hold without a reset) are the next boots.
