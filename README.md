# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-11-27)

**Kept current:** this section is updated with every step forward (a new daily, a feature that starts working, a test
boot built, a PR merged). The capability ledger [`gap-map.csv`](contrib/community/gap-map.csv) was refreshed on
2026-11-23. Older snapshots: [`docs/status-2026-11-23.md`](docs/status-2026-11-23.md), [`docs/status-2026-11-08.md`](docs/status-2026-11-08.md),
[`docs/status-2026-11-06.md`](docs/status-2026-11-06.md). Every change made on the Mac itself is a row in
[`contrib/omarchy-mac/INVENTORY.md`](contrib/omarchy-mac/INVENTORY.md). The capability-by-capability map is
[`contrib/community/FULL-SUPPORT-GAP-MAP.md`](contrib/community/FULL-SUPPORT-GAP-MAP.md) (refreshed 2026-11-17).

**Daily boot:** `daily-20261125-43844987.bin` (**the motion-2 daily**, promoted 2026-11-26; still the quiet and fast boot of 2026-11-23): kernel **7.3.0-g0f96ca644485**
(the previous daily plus the accelerometer, gyroscope and ambient light sensor through the AOP; the guided check is `m5pro-motion-test`), loader **aura 1.0.0b13-gbba0d136**
(silent, no USB host wait), the enrolled silent A/B stage 1, quiet boot arguments (`quiet loglevel=3 logo.nologo systemd.show_status=false`), a quiet
initramfs and a blank tty1. **No text from the Apple logo to the lock screen**; power-on to the lock screen 23.6 s, a restart about 30 s
([`contrib/pending/fast-boot/`](contrib/pending/fast-boot/)). The macOS stub is **27.3 beta (26C5035r)**. Omarchy 4.5 on the root: the stock `omarchy update` now works
behind [`safe-update`](contrib/omarchy-mac/safe-update/)'s holds (`hyprlock` joined the held packages on 2026-11-26). Rollback: `boot.bin.prev` = `daily-20261125-16feafef.bin`
(the previous daily); `touch /etc/m5-verbose` brings the kernel log back on screen. GPU session on **Mesa tip-hwrq6** (`fe6d47e492`, applied 2026-11-26 through
`/etc/mesa-aurora/session.env`): glmark2 6205, and kitty and Qt load EGL without the `GLIBC_TUNABLES` workaround.

| Status | Area | State |
|---|---|---|
| **Works (daily)** | CPU, memory, storage | 18 CPUs, WFI idle, schedutil cpufreq, NVMe root with an e2fsck at every boot. |
| **Works (daily)** | Display | The DCP drives the panel at 120 Hz with VRR. **XDR brightness up to 1600 nits** (`m5pro-xdr`, menu row; owner-tested 800-1600 nits, no flicker) and **HDR video** through Hyprland's `cm_auto_hdr` with `appledrm.fw27_3_edr=1`; the HDR headroom fades out over 2 s as on macOS. [`xdr-brightness/`](contrib/omarchy-mac/xdr-brightness/) |
| **Works (daily)** | Brightness | Automatic brightness from the ambient light sensor for the panel and keyboard light, dimming on inactivity. [`auto-brightness/`](contrib/omarchy-mac/auto-brightness/) |
| **Works (daily)** | GPU | Vulkan and native GL (mesa-aurora) for the Hyprland session, zink per app where native GL still renders wrongly. GPU recoveries no longer take the compositor down. Mesa tip-hwrq6 since 2026-11-26. |
| **Works (daily)** | Keyboard, trackpad | Keyboard and backlight, trackpad with haptics, macOS-feel pointer profiles. Palm rejection patches are staged. |
| **Works (daily)** | Touch ID | sudo, polkit, the lock screen (also at login) and 1Password unlock through the Secure Enclave. [`touchid-omarchy/`](contrib/pending/touchid-omarchy/), [`lock-at-login/`](contrib/omarchy-mac/lock-at-login/) |
| **Works (daily)** | Camera | The FaceTime HD camera through `apple-isp` (owner-tested in Chrome and Meet) with a denoise filter and an on-demand V4L2 "Clean" camera. The spatial and chroma clean-up stage for dim light plus 60 Hz anti-flicker (pkgrel 10) is installed since 2026-11-23. [`camera-denoise/`](contrib/omarchy-mac/camera-denoise/), [`camera-v4l2-bridge/`](contrib/omarchy-mac/camera-v4l2-bridge/) |
| **Works (daily)** | Microphones | The three-capsule array as one microphone in apps. [`mic-array/`](contrib/omarchy-mac/mic-array/) |
| **Partial (daily)** | Speakers | Protected by speakerguardd v2 with PipeWire realtime; a quiet tone plays clean. The listening test at normal volume is still to do. |
| **Works (daily)** | Wi-Fi | The kernel trains the N1; Wi-Fi 2.4/5 GHz works, including open networks. The firmware reports no Wi-Fi 7 (EHT); 6 GHz is enabled (passive scan) but no 6 GHz network has been seen yet. The first 5 GHz association after a boot or wake sometimes fails (firmware status 352) and lands on 2.4 GHz. |
| **Works (daily)** | Bluetooth | AirPods Pro (music, media and volume keys, and **noise control, battery and ear detection** through [`airpods-control/`](contrib/omarchy-mac/airpods-control/)); the iPhone pairs and tethers over Bluetooth (NAP). |
| **Partial (daily)** | USB-C | Both front ports (left-front, right) work as USB3 hosts. The hotplug kernel fix (a port controller missing at probe, a liquid-detection state that never cleared, lost plug events) is in the daily; on 2026-11-27 a plug test on the #3280 test kernel ran 3 clean cycles on each front port, and the lost-event recovery fired once. **The left-rear port (MagSafe side) is a gap:** it showed no event at any level, because its port controller (SPMI 1-08) has no connector node in the J716s device tree and its USB controller (2aa280000) is not enabled. It is also the port the development tether (the m1n1 gadget) uses, so the daily keeps it out of host use. The boot-time re-probe service ([`usb-pd-rebind/`](contrib/omarchy-mac/usb-pd-rebind/)) stays as a belt. |
| **Works (daily)** | Battery, power | Battery and charger, an 80 % charge limit, working power profiles (daemon 0.30-9). |
| **Works (daily)** | Sleep | s2idle on lid close (about 4.3 W on battery). Deep sleep is built, not run. The RTC alarm cannot wake it yet (the PMU RTC has no interrupt wired; SPMI interrupts in progress). |
| **Works (daily)** | Desktop | Omarchy 4.5 (Hyprland, Lua config), Log out, Startup Disk and Reboot into macOS from the menu, and the **Login Items & Restore** app: it reopens every window on its workspace after a reboot and resumes Claude Code, Codex, OpenCode and Gemini terminal sessions (new on 2026-11-19; it leaves muvm and Steam windows alone since 2026-11-27). [`session-restore/`](contrib/omarchy-mac/session-restore/), [`startup-disk/`](contrib/omarchy-mac/startup-disk/) |
| **Works (daily)** | Containers, VMs | KVM, Docker, and x86-64 programs through qemu binfmt. |
| **In progress** | Steam | `m5pro-steam` runs Valve's arm64 client inside a muvm VM with the GPU (`m5pro-muvm-gpu`; zink on the Vulkan driver in the guest), Proton ARM64 is the compatibility tool. Open: the Steam UI scaling is still too small; the first real Proton game has not run yet (paused by the owner). Session restore no longer relaunches the VM after a reboot. [`steam-muvm/`](contrib/omarchy-mac/steam-muvm/), [`muvm-gpu/`](contrib/omarchy-mac/muvm-gpu/) |
| **Works (daily)** | NVRAM, Startup Disk | Read from Linux; the menu's Reboot into macOS (one-time target) and the default startup volume, written in place with read-back checks. |
| **Works (daily)** | Neural Engine | The ANE driver ([aurora-silicon/linux#2293](https://github.com/aurora-silicon/linux/pull/2293) DT + #1957's per-build table) with a code pin for the macOS 27.3 (26C5035r) firmware: `/dev/accel/accel0` at every boot, and the **first H17 compute on Linux** (add/sub/mul/relu programs from mil-hwx-compiler, 15 000 runs, all within 1 ulp, about 100 µs each). Real models wait for the compiler's H17 backend. [`contrib/pending/ane/`](contrib/pending/ane/) |
| **Works (daily)** | Video decode | H.264, HEVC (10-bit), VP9 and AV1 on the AVD through VA-API: ffmpeg output pixel-identical to software, mpv by default, Chrome with 0 dropped frames. [`avd-video/`](contrib/omarchy-mac/avd-video/) |
| **Works (daily)** | DRM video | Widevine L3 in Google Chrome arm64 (its bundled CDM loads on the 16K-page kernel); the Shaka Widevine sample plays. [`widevine/`](contrib/omarchy-mac/widevine/) |
| **In progress** | AirDrop | The N1 firmware starts AWDL and stops after about 11 s; Taildrop is the fallback for iPhone sharing. [`airdrop/`](contrib/omarchy-mac/airdrop/) |
| **Test kernels** | Thunderbolt/USB4, external displays | Both routers bring up a TB3 link and a PCIe tunnel on a test kernel; not on the daily, so no docks or DisplayPort yet. HDMI is lined up on the newest test stack (`j716s-t2-hdmi`), and deep sleep after it (`j716s-t2-sleep`, attended). [`contrib/pending/thunderbolt/`](contrib/pending/thunderbolt/) |
| **Prepared** | SD card reader | The GL9755 reader on PCIe port 1: device tree node, SD power line, reset pin and DART, plus the PCI SDHCI driver (branch `j716s-sdxc`, DTBs compile). Link tunables are copied from the J714s/K116s; one self-reverting boot checks it. |
| **Works (daily)** | Fan control | The J716s device tree gives both fans a manual target ([aurora-silicon/linux#3281](https://github.com/aurora-silicon/linux/pull/3281)): `fan1/2_target` are writable, the SMC takes the target and hands the fan back on 0. The driver enforces a 120 s lease and a 90 C guard (fans at maximum, released at 80 C). `m5pro-fan-lead` is installed and runs the fans ahead of the die heat on AC in the performance profile; the `m5pro-fan` command and menu row are built, not installed. [`fan-lead/`](contrib/omarchy-mac/fan-lead/), [`fan-control/`](contrib/omarchy-mac/fan-control/) |

**Test boots:** 2026-11-23 `pmu-edac1` (the CPU PMU counts on both core types, EDAC monitors 12 + 23 error sources with no errors, the AES engine times out at probe) and
`gpupm-observed` (macOS's GPU power values: +8.5 % glmark at the same idle power). 2026-11-27: the #3280 plug test (above). **Waiting for hardware or the owner:** HDMI with HDMI audio
(`extdisp-chain`, needs an HDMI display), the encrypted-root unlock (`encryption-2`; the scratch-file test passed on 2026-11-23), the first Proton game. AirDrop is being rebuilt on the
daily kernel. Distribution work in progress: package recipes and an `m5pro-boot` CLI ([`contrib/distro/`](contrib/distro/)), and omarchy-mac-installer support for the J716s (simulation only).

**Upstream** (`aurora-silicon/linux`): merged #1082, #1083, #1084, #1152, #1160, #1167 (the J716s device tree), #1174, #1182, #1183, #1240, #1241, #1242. **Opened on 2026-11-26/27:**
**#3280** (tipd hotplug: survive probe-time read errors, recover lost plug events; plug row posted), **#3281** (J716s device tree: Touch ID, fans, the left-front USB4 router),
**#3282** (Wi-Fi: join open networks; open-network row posted, ready), **#3283** (DCP: refuse panel brightness after a display-processor crash). **#2070** (refuse deep sleep where the
27.x display sleep is unknown) has main merged in and carries a hardware row; **#2293** (Neural Engine) has its row posted; **#1173** (M5 GPU InitData) is open. aura: **#503** and **#504** updated;
**#502** failed its hardware boot on 2026-11-27 before the hand-off (`SMP: boot CPU RVBAR check failed`: aura main lacks the J716s RVBAR relay; not #502's change); **#274** (the J716s boot) is open.
Stale omacom PRs were closed as superseded, and test-result comments were posted on 15 PRs by other people. For the Omarchy project:
[omacom/linux-aurora #413](https://github.com/omacom/linux-aurora/pull/413) and omacom/omarchy-mac-pkgs #103. [`contrib/validated/aurora/prs/`](contrib/validated/aurora/prs/)

## Quick start: build and install a payload

The payload is one file: m1n1 (0x400000 bytes) | boot arguments | `Image.gz` | device tree | initramfs.
[`mk-daily.py`](contrib/validated/aurora/tools/mk-daily.py) builds it from named, hash-pinned ingredients and
prints the commands for the swap; it never touches the machine. What may sit on the ESP, and how a failed test
returns to the last good payload, is in [`ESP-POLICY.md`](contrib/validated/aurora/tools/ESP-POLICY.md): read it first.

```bash
# 1. kernel: a worktree of aurora-silicon/linux at 33bec4016c46 + the series, then build it (recipe: series/SERIES.md)
git am contrib/validated/aurora/series/patches/*.patch
# the daily adds, in this order: Aurora #1012 and the 27.2+ GPU port (contrib/pending/gpu/patches/kernel-27.2/), the N1 training
# (contrib/pending/wireless/patches/linux/0004-0010), peripherals 0007 (F6) and nvram 0001 (contrib/pending/)
make LLVM=1 ARCH=arm64 defconfig asahi.config j716s.config && make LLVM=1 ARCH=arm64 -j Image.gz dtbs

# 2. check the ingredients, then build a test payload (it reverts itself if the network does not come up)
python3 -I contrib/validated/aurora/tools/mk-daily.py --list      # edit INGREDIENTS (paths, pins) for your machine first
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --label my-test

# 3. print the ESP swap, read it, run it yourself; boot the test with the Ethernet adapter attached
#    (leave the machine idle for 60 s after any large write before rebooting: docs/boot-and-recovery.md)
python3 -I contrib/validated/aurora/tools/mk-daily.py --deploy-plan --payload DIR/my-test-<date>-<hash>.bin --host root@<linux-ip>

# 4. once it reached the network, rebuild the same ingredients as the daily (no self-revert, battery on)
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --daily --battery --force
```

The stage-2 m1n1 of the daily (`n1-dt-gpu`) is upstream plus `patches/m1n1/`, the N1 hand-off patches 0022 and 0028 of `contrib/pending/wireless/patches/m1n1/` (the port stays enabled and the host tunables are copied; the kernel trains the N1, so 0023 and 0025-0027, the loader-side training, are optional) and the GPU hand-off of `contrib/pending/gpu/patches/m1n1/` (0019 and the GPU patch numbered 0028, behind `chosen.m5pro,gpu=1`; the N1 patch 0028 is a different one) (toolchain and recipe: [`m1n1-BUILD.md`](contrib/validated/integration/m1n1-BUILD.md)):

```bash
git -C ~/Work/m1n1 checkout -b m5-t6050 7cde7d1a && git -C ~/Work/m1n1 am ~/Work/m5pro-linux/patches/m1n1/*.patch
```

The stage-1 A/B patch is separate (`patches/m1n1-stage1/`): it only belongs in a CHAINLOADING build.

## Layout

| Path | What |
|---|---|
| `patches/m1n1/` | `git format-patch` series on upstream m1n1 (see SOURCES.md), the stage-2 build of the daily. 0001-0007: omarchy-m5's T6050 patches, rebased (author kept). 0008-0015: written here (0013-0015: chainload and SMP for a stage 2 on the ESP). 0017, 0018, 0020, 0021: notch rows, USB-PD controllers into S0, PIPE park, and the combo-PHY tunables produced from the ADT at boot, so the device tree carries no per-unit values. |
| `patches/m1n1-stage1/` | 0016: the A/B fallback and watchdog of the CHAINLOADING stage 1. |
| `patches/omarchy-m5/` | Changes to the omarchy-m5 checkout (the 7.2 stack): J716s board DT, measured PMGR boot state, `GCC=1` builds, `finish-install.sh --macho`. |
| `contrib/validated/aurora/` | The Aurora kernel work that has run on the machine: `series/` (the 87 patches and the rebuild recipe), `tools/` (`mk-daily.py`, `ESP-POLICY.md`), `atc-tunables/`, `pipe-park/`, `trackpad/`, `prs/` (upstream PRs), `STATE.md`. |
| `contrib/validated/integration/` | Hardware results (`RESULTS.md`), test kits and the patch set of the 7.2 stack. |
| `contrib/validated/desktop/`, `contrib/validated/legacy-7.2/` | Desktop setup; trackpad, SMC, cpufreq and USB-host work that ran on the 7.2 stack (what the fallback payload is made of). |
| `contrib/pending/` | Test-payload work, prepared work and design reports: `audio` (with the Aurora audio kernel patches), `dcp`, `gpu`, `wireless` (with the N1 patches), `wfi-idle`, `platform`, `thunderbolt`, `camera`, `video`, `ane`, `crashlog`, `followups`, `boot-ab`, `dt-prep`, `isp-tb`. |
| `contrib/omarchy-mac/` | Every customization on the Mac running Omarchy: one folder per item with its files, installer and README, tracked in `INVENTORY.md` and checked by `audit-macbook.sh`. |
| `contrib/community/` | The full-support gap map (`FULL-SUPPORT-GAP-MAP.md`, `gap-map.csv`) and community status notes. |
| `contrib/distro/` | Design and prototypes for an installable distribution; not run on the machine. |
| `dt/` | The 7.2-stack J716s board DTS and its measured PMGR power-state table. |
| `host/macos/`, `host/`, `scripts/` | Studio-side tether and deploy helpers (macOS and Omarchy), udev rules, the NAT script, m1n1 proxy helpers. |
| `docs/` | Boot and recovery, the SMP investigation, status snapshots, redacted log excerpts, the plan. |

## Not in this repo, on purpose

- Apple boot objects (kernelcache, SPTM, TXM), firmware, and anything extracted from macOS.
- The Mac's ADT dump: it carries the serial number and MAC addresses.
- Per-unit firmware (the Wi-Fi/Bluetooth image) and per-unit device-tree values.
- Disk images, root tarballs, initramfs and kernel builds, payloads.
- Keys and passwords.

Reverse-engineering notes (disassembly excerpts of Apple binaries made while chasing SMP) are kept
outside this repository and are not published. Nothing in this tree is copied from them: the
register writes, ADT properties and SMC keys documented here come from hardware measurements, the
ADT and public sources. Earlier commits of this repository still contain a `docs/re/` folder with
those excerpts; if your project works clean-room, do not check out or read history before the
commit that removed it.

## Contributing / contact

Questions, reports and corrections: [issues on this repo](https://github.com/rolotrealanis98/m5pro-linux/issues).
Fixes that belong upstream go to `aurora-silicon/linux` as small PRs (see
[`UPSTREAM-NOTES.md`](contrib/validated/aurora/series/UPSTREAM-NOTES.md)).

## Credits

omarchy-m5 (betim-hodza) did the T6050 bring-up this builds on: the stub install scripts, the
J714s device trees, the kernel patches and the original m1n1 patches. The Aurora Silicon project
(aurora-silicon/linux; Jeff Queisser, Erik Bourget, Dj and others) carries the T6050 kernel work the
daily is based on: the series carries their commits with authors kept; the AOP audio port is
edimoldovan's. m1n1 and linux-asahi are the Asahi Linux project's work.

## License

Kernel patches are GPL-2.0-only, m1n1 patches and everything else MIT; material taken from
omarchy-m5, Aurora and Asahi keeps its origin and terms. Details: [`LICENSE.md`](LICENSE.md).
