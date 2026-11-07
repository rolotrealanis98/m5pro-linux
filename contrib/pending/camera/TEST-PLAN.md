# J716s camera (T6050 ISP): test plan

Nothing here has run on the M5. Every stage after I0 needs the MacBook.

## Safety rules

- **Watchdog and fallback.** The A/B stage-1 (installed 2026-11-07, 150 s watchdog) boots
  `boot.bin.prev` after a failed or hung boot. That makes a crash before root mounts recoverable
  without anyone at the machine. The risky part, the ISP driver, loads only after boot, once,
  from `tools/isp-oneshot.sh`. A crash there reboots, and the next run refuses to load the
  driver again while its marker exists.
- **Module blacklist.** Install the ISP module with `/etc/modprobe.d/apple-isp.conf` containing
  `blacklist apple_isp`. udev then never loads it, but `modprobe apple_isp` still does.
- **Things that run before root mounts.** In I1 these run at every boot of the test payload:
  - The ISP DARTs probe. Their registers sit in the same block whose address filter m1n1
    programs from the ADT at every boot.
  - The eight ISP power states are read. Two of them (ISP_SYS, ISPSENS0) are ones m1n1 already
    switches. The other six are inferred offsets: they are read, never written, unless they
    are found on.
- **Privacy.** A captured frame is a picture of the room. Never commit it, and never post it.
- **Indicator light.** If the notch camera light stays off while frames arrive, stop and report
  it. No driver here may defeat the indicator.

## I0: Studio checks (done 2026-11-07)

- DTBs compile with dtc 1.8.1 and no warnings: t6050-j716s, j716c, j714c, j775d. The two test
  DTBs (`dt/`) give only unit-name warnings, for their placeholder region nodes.
- Patches 0001 and 0003 apply to `j716s-series` a0f2f30c967b (`git apply --check`). Patch 0004
  applies as well. 0002, 0005 and 0006 target the isp/t6050 tree; on the series, use
  `dt/t6050-j716s-camera-series.dtsi` and `tools/camera.config` instead.
- m1n1 0029: `clang -fsyntax-only` with m1n1's warning flags is clean for `isp.c` and `kboot.c`.
  It has not been built.

## I1: kernel and DTB, the ISP left unloaded (loop-safe)

**Build (Studio).**

1. Kernel: the daily series tree, plus patches 0001 and 0003.
   ```
   make defconfig asahi.config j716s.config camera.config
   make Image.gz modules
   make modules_install INSTALL_MOD_PATH=<stage>
   ```
   Copy `<stage>/lib/modules/<ver>` to the root and run `depmod <ver>`. That carries apple-isp
   and the videobuf2 modules.
2. DTB: the series `dt/t6050-j716s.dts` with `#include "t6050-j716s-camera-series.dtsi"`
   appended.
3. Payload:
   ```
   mk-daily.py --label isp-i1 --kernel <Image.gz> --dtb <dtb> --force
   ```
   Keep selftest on.

**Before booting**, check that the firmware has not moved. isp0 `segment-ranges` must still
read TEXT 0xc1c000 @ 0x10001094000 and DATA 0x13d0000 @ 0x1000269c000. To check:
- Dump the ADT on the running daily from the MTD labelled "adt" (`cat /proc/mtd`) to the
  Studio, then run `tools/adt-isp.py` on it. Keep the dump private.
- Or, from macOS, run `ioreg -l -p IODeviceTree -n isp0`.

If either address changed, edit `dt/*-camera-*.dts*` before you build.

**Pass:**
- It boots like the daily.
- `dmesg` shows the three `apple-dart 5828c0000.iommu` / `5828e0000` / `582900000` DARTs
  probing, with no fault and no SError.
- `/sys/kernel/debug/pm_genpd/pm_genpd_summary` lists isp_sys, isp_cpu, isp_fe, isp_dprx,
  isp_secure, isp_be, isp_clr and ispsens0.
- The domains read off, or on with auto-PM.
- No `apple_isp` in `lsmod`.

## I2: load the ISP once (post-boot; `tools/isp-oneshot.sh`)

Copy the script to `/boot`, then run `bash /boot/isp-oneshot.sh`. It loads the driver with
`dyndbg=+p`.

**Pass:**
- `dmesg` shows the three handshake lines, in order:
  - `got first magic number from firmware`
  - then the second
  - then the third
- The firmware's log lines follow.
- `found sensor 958 on ch 0`, and the `sensor config N: input ... output ...` table appears.
- `/dev/video0` exists, and `v4l2-ctl --list-devices` names "FaceTime HD Camera".
- No `apple-dart ... fault` and no DAPF readback error.
- The logs are in `/boot/r1-logs/isp-*/`.

## I3: formats and one frame

1. List the formats:
   ```
   v4l2-ctl -d /dev/video0 --list-formats-ext
   ```
   Expect NV12 at 1920x1080 and 1280x720. More sizes appear from the firmware's own
   configurations, and P010 if the extended reply works.
2. Capture one frame:
   ```
   v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=NV12 \
       --stream-mmap --stream-count=1 --stream-to=/tmp/f.raw
   ```
   Or run `isp-oneshot.sh capture`.
3. **Pass:**
   - `/tmp/f.raw` is 3110400 bytes.
   - `ffmpeg -f rawvideo -pix_fmt nv12 -s 1920x1080 -i f.raw f.png` on the Studio shows a
     picture.
   - The notch light is on while it streams.
4. Without the setfile, colours and shading are untuned. Extract
   `apple/isp_2224_01XX.dat` from macOS `appleh16camerad` (present on the Studio's macOS 27.2)
   into `/lib/firmware/apple/` on the root. Never put it in the repo.

## I4: PipeWire

1. With pipewire and wireplumber running for the desktop user, run `wpctl status`. "Video >
   Sources" lists "FaceTime HD Camera (V4L2)".
2. Stream through PipeWire:
   ```
   gst-launch-1.0 pipewiresrc num-buffers=60 ! videoconvert ! fakesink
   ```
   Then try a portal app, such as Firefox on a webcam test page.
3. Optional: aurora-silicon/camera-denoise adds a filtered node with the same name. Its levels
   are keyed by DT compatible, and there is no `apple,j716s` entry yet, so J716s gets the
   temporal filter only.

## I5: the loader path (m1n1 0029) instead of the static DTB

This is a loader change. Run it under the A/B watchdog, the first time with someone at the
machine.

**Setup:**
- m1n1: the m1n1-r2 lineage plus 0029.
- DTB: the isp/t6050 `t6050-j716s.dts` (or a series DT carrying its placeholders and the `isp`
  alias), with no static fill.
- Payload variable: `chosen.m5pro,isp=1`, appended the way `chosen.asahi,show-notch=1` is.

**Expected on the panel:**
```
isp: T6050: pre-loaded TEXT 0xc1c000 @ 0x10001094000, DATA 0x13d0000 @ 0x1000269c000
FDT: ISP enabled (chosen.m5pro,isp=1)
```

**Pass:**
- `/proc/device-tree/reserved-memory/isp-firmware-{text,data}/reg` holds those values.
- I2 to I4 pass again.

**Without the variable:**
- The panel shows `FDT: ISP firmware regions filled; chosen.m5pro,isp=1 enables the camera`.
- The ISP stays disabled.
- The daily is otherwise unchanged: m1n1 no longer leaves ISP_SYS and ISPSENS0 on, and the
  "isp: Unsupported SoC" line is gone.

## What a failure, or a firmware-version mismatch, looks like

The H17 driver does not compare version numbers. A 27.x firmware with a changed interface fails
at one of these checks, in this order:

| dmesg (apple-isp) | Meaning | Next |
|---|---|---|
| `reset vector 0x... is not the firmware at 0x10000000000` | The text is not where the DT says (stale static DTB), or RVBAR did not survive ISP_SYS off | Re-check segment-ranges; use I5 |
| `coprocessor already started (control 0x...)` | Something ran it before Linux | Check the loader; no reset path exists |
| `DAPF window N (...) failed readback` | Address filter word 2 (0xcc3) does not read back as written | Relax the CTRL2 readback, or drop `dapf_ctrl2` |
| `never received first magic number from firmware` | The firmware did not boot. Causes: domains, DAPF, the boot mode, or a new handshake | Check the genpd states; try PMP_CTRL_SET (below) |
| `firmware did not request the H16 boot descriptor` / `invalid IPC channel count` / `invalid ipc chan ...` / `never received second/third magic number` | **Boot interface changed in this firmware** (ABI mismatch) | Compare with T6040's 26.x layout; needs a new ABI variant |
| `metadata sizes 0x.../0x..., expected 0x4d00/0x0` | **H17 command layouts changed** (ABI mismatch) | Same |
| `invalid sensor version: 0x...` / `ch 0: unsupported sensor` | Not an IMX958 | Add the sensor and its setfile |
| `ignoring WxH preset: config 5, firmware has N` / `no usable sensor presets` | The firmware's configuration list differs from the J616s's | Use the logged table; J813's IMX958 uses config 7 (3040x2880) with crops |
| `apple-dart 5828c0000.iommu: ... fault` at a PMGR/PMP/DSID address | The firmware reaches a window that is not mapped | Add the window; check the DSID base (the J813 convention is end-0x2fc) |
| Frames stall at a fixed count | Capture watchdog gate | Try the EIC `mmio-wd-isp` window 0x5c3b50000+0x8000 as `wdt` |

**Fallbacks, not committed:**
- PMP_CTRL_SET with T6040-analogue offsets: `clock_scratch` 0x284250fa8 and
  `bandwidth_scratch` 0x286724000, both size 8.
- DSID bases at window+0x12000 (J813) instead of +0x10000.
