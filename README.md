# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-11-22)

**Kept current:** this section is updated with every step forward (a new daily, a feature that starts working, a test
boot built, a PR merged). The capability ledger [`gap-map.csv`](contrib/community/gap-map.csv) was refreshed on
2026-11-22. Older snapshots: [`docs/status-2026-11-08.md`](docs/status-2026-11-08.md),
[`docs/status-2026-11-06.md`](docs/status-2026-11-06.md). Every change made on the Mac itself is a row in
[`contrib/omarchy-mac/INVENTORY.md`](contrib/omarchy-mac/INVENTORY.md). The capability-by-capability map is
[`contrib/community/FULL-SUPPORT-GAP-MAP.md`](contrib/community/FULL-SUPPORT-GAP-MAP.md) (refreshed 2026-11-17).

**Daily boot:** `xdr1hdr-everyday-20261118-b79e415c.bin`, kernel **7.3.0-gc1e08542a544** (branch `j716s-xdr` =
`j716s-next8`, the current `integration/aurora` base with the J716s series, plus the XDR range and the firmware 27.3 EDR
commits), loaded by the **aura stage 2** (`j716s-camera-1`, with the J716s camera row). Omarchy 4.5 on the root, now
updated with the stock `omarchy update` behind [`safe-update`](contrib/omarchy-mac/safe-update/)'s guards (snapshot first,
held local builds, migration policy, post-update check with automatic restore; the first native update, 43 packages, ran
clean on 2026-11-19). Rollback: `next8gpu-everyday-20261118-3125fe70.bin`.

| Status | Area | State |
|---|---|---|
| **Works (daily)** | CPU, memory, storage | 18 CPUs, WFI idle, schedutil cpufreq, NVMe root with an e2fsck at every boot. |
| **Works (daily)** | Display | The DCP drives the panel at 120 Hz with VRR. **XDR brightness up to 1600 nits** (`m5pro-xdr`, menu row; owner-tested 800-1600 nits, no flicker) and **HDR video** through Hyprland's `cm_auto_hdr` with `appledrm.fw27_3_edr=1`. [`xdr-brightness/`](contrib/omarchy-mac/xdr-brightness/) |
| **Works (daily)** | Brightness | Automatic brightness from the ambient light sensor for the panel and keyboard light, dimming on inactivity. [`auto-brightness/`](contrib/omarchy-mac/auto-brightness/) |
| **Works (daily)** | GPU | Vulkan and native GL (mesa-aurora) for the Hyprland session, zink per app where native GL still renders wrongly. GPU recoveries no longer take the compositor down. |
| **Works (daily)** | Keyboard, trackpad | Keyboard and backlight, trackpad with haptics, macOS-feel pointer profiles. Palm rejection patches are staged. |
| **Works (daily)** | Touch ID | sudo, polkit, the lock screen (also at login) and 1Password unlock through the Secure Enclave. [`touchid-omarchy/`](contrib/pending/touchid-omarchy/), [`lock-at-login/`](contrib/omarchy-mac/lock-at-login/) |
| **Works (daily)** | Camera | The FaceTime HD camera through `apple-isp` (owner-tested in Chrome and Meet) with a denoise filter and an on-demand V4L2 "Clean" camera. Still grainy in dim light: a spatial and chroma clean-up stage plus 60 Hz anti-flicker is built and staged (pkgrel 10). [`camera-denoise/`](contrib/omarchy-mac/camera-denoise/), [`camera-v4l2-bridge/`](contrib/omarchy-mac/camera-v4l2-bridge/) |
| **Works (daily)** | Microphones | The three-capsule array as one microphone in apps. [`mic-array/`](contrib/omarchy-mac/mic-array/) |
| **Partial (daily)** | Speakers | Protected by speakerguardd v2 with PipeWire realtime; a quiet tone plays clean. The listening test at normal volume is still to do. |
| **Works (daily)** | Wi-Fi, Bluetooth controller | The kernel trains the N1; Wi-Fi 2.4/5 GHz works, including open networks; the Bluetooth controller is up. Pairing, Wi-Fi 7 and 6 GHz are still open. |
| **Partial (daily)** | USB-C | Both front ports work as USB3 hosts. Hotplug after boot was unreliable (a port controller missing at probe, a liquid-detection state that never cleared, lost plug events): a boot-time re-probe service is daily ([`usb-pd-rebind/`](contrib/omarchy-mac/usb-pd-rebind/)), and the kernel fix is in the next test boot. |
| **Works (daily)** | Battery, power | Battery and charger, an 80 % charge limit, working power profiles (daemon 0.30-9). |
| **Works (daily)** | Sleep | s2idle on lid close (about 4.3 W on battery). Deep sleep is built, not run. |
| **Works (daily)** | Desktop | Omarchy 4.5 (Hyprland, Lua config), Log out, Startup Disk and Reboot into macOS from the menu, and the **Login Items & Restore** app: it reopens every window on its workspace after a reboot and resumes Claude Code, Codex, OpenCode and Gemini terminal sessions (new on 2026-11-19; one real reboot so far, more checks to come). [`session-restore/`](contrib/omarchy-mac/session-restore/), [`startup-disk/`](contrib/omarchy-mac/startup-disk/) |
| **Works (daily)** | Containers, VMs | KVM, Docker, and x86-64 programs through qemu binfmt. |
| **Works (daily, read-only)** | NVRAM | Read from Linux; one-time Startup Disk targets. |
| **Next test boot** | Neural Engine | The ANE driver ([aurora-silicon/linux#2293](https://github.com/aurora-silicon/linux/pull/2293) DT + #1957's per-build table) with a code pin for the macOS 27.3 (26C5035r) firmware, computed from the firmware image on the Linux install's own macOS volume. [`contrib/pending/ane/`](contrib/pending/ane/) |
| **Prepared** | Video decode | AVD firmware and the VA-API path are installed; a clip test is pending. [`avd-video/`](contrib/omarchy-mac/avd-video/) |
| **In progress** | AirDrop | The N1 firmware starts AWDL and stops after about 11 s; Taildrop is the fallback for iPhone sharing. [`airdrop/`](contrib/omarchy-mac/airdrop/) |
| **Test kernels** | Thunderbolt/USB4, external displays | Both routers bring up a TB3 link and a PCIe tunnel on a test kernel; not on the daily, so no docks or DisplayPort yet. HDMI is lined up on the newest test stack (`j716s-t2-hdmi`), and deep sleep after it (`j716s-t2-sleep`, attended). [`contrib/pending/thunderbolt/`](contrib/pending/thunderbolt/) |
| **Prepared** | SD card reader | The GL9755 reader on PCIe port 1: device tree node, SD power line, reset pin and DART, plus the PCI SDHCI driver (branch `j716s-sdxc`, DTBs compile). Link tunables are copied from the J714s/K116s; one self-reverting boot checks it. |
| **Not planned** | Fan control | The T6050 SMC has no unlock key. |

**Next test boot** (built, self-reverting, waits for the owner): `ane2293c-usbpd1-edr-test-20261119-111abae6.bin`,
kernel 7.3.0-g0c6bb36ed14a. It carries the USB-C hotplug fix (5 commits, KUnit 178/178), the Neural Engine with the 27.3
code pin (KUnit 277 of 278, 1 skipped), and the HDR headroom fading down over 2.0 s as on macOS (DRM KUnit 180 of 181,
1 skipped). The camera clean-up package installs in the same sitting. The USB-C fix is prepared for upstream as three small PRs, posted after the hardware test.
The MacBook is travelling from 2026-11-22: it boots the daily (boot.bin and its fallback are both the daily), and the
test boot waits until it is back with the owner.

**Upstream** (`aurora-silicon/linux`): merged #1082, #1083, #1084, #1152, #1160, #1167 (the J716s device tree), #1174
(27.3 display method IDs), #1182 and #1183 (kernel-side N1 training), #1240, #1241, #1242 (GPU recovery). Open: **#1173**
(M5 GPU InitData for 27.2 and 27.3; on 2026-11-22 macOS 27.2's own InitData was captured on this Mac under the m1n1
hypervisor: the version word, allocation sizes, policy bands and controller words, the inserted status-config words
and the 27.0 HW data layout all match the PR, one status-config block stride is still open; the comment is drafted)
and **#2070** (refuse deep sleep where the 27.x display sleep is unknown; the review asks for admission by the
firmware's method table and a re-signed commit, being reworked), and aura **#274** (the J716s boot, being retargeted to the
27.2 stub and split into small PRs after review). For the
Omarchy project: [omacom/linux-aurora #413](https://github.com/omacom/linux-aurora/pull/413) and the omacom m1n1 stack
#30-#37. [`contrib/validated/aurora/prs/`](contrib/validated/aurora/prs/)

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
