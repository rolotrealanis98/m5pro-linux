# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-11-07)

The daily kernel is now **Aurora Silicon's `integration/aurora` (Linux 7.3.0) plus a 60-patch J716s
series**. It boots untethered from the ESP on all 18 CPUs with NVMe root, battery, SMC sensors, both
Type-C ports as USB hosts, the trackpad and a Hyprland desktop (software rendering). The microphone works
on a separate audio kernel. WFI idle is in test. The older asahi-wip 7.2 stack is kept as the fallback
payload; everything it proved (SMP, boot chain, NVMe, trackpad, battery, cpufreq) carried over.

Hardware results, round by round: [`contrib/validated/integration/RESULTS.md`](contrib/validated/integration/RESULTS.md).
Exact ingredients of the current payload: [`contrib/validated/aurora/STATE.md`](contrib/validated/aurora/STATE.md).
Last full write-up with test labels and repro steps: [`docs/status-2026-11-06.md`](docs/status-2026-11-06.md).

### Works (tested on hardware)

| Area | State |
|---|---|
| Aurora kernel, the daily | **works**: NVMe root, 18 CPUs, `apple_idle` cpuidle, schedutil cpufreq on all three clusters, USB Ethernet, keyboard, trackpad, Hyprland on llvmpipe over simpledrm (`card0-eDP-1`, notch rows). The device tree is source-form, has no per-unit values, and builds with the kernel. |
| Battery and charger (`macsmc-power`) | **works** (R3-S): status, capacity, voltage, current, charge, cycle count, temperature, charge behaviour, AC input power. Not exercised on this kernel: discharging and MagSafe unplug events. |
| SMC sensors (`macsmc_hwmon`) | **works** (HWMON-T1): 60+ temperature channels, both fans (0 rpm when cool), power and current rails. Fan control is not available (the T6050 SMC has no `Ftst` unlock key). |
| USB, left-front port | **works**: SuperSpeed hub, RTL8153 Ethernet, receiver dongle, card reader. |
| USB, right port | **works** (probe test and a live plug test): hub at SuperSpeed Plus (10 Gb/s), keyboard, mouse, Ethernet. DisplayPort on it is not tested. |
| Trackpad | **works** on both stacks: the host drives the AFE reset on SMC low GPIO `gp1c`; `Touch MT ready` on every boot since R3-R. |
| Microphone | **works** (audio kernel only, not yet in the daily): three capsules, speech tracks the voice. Jack switches register; headphones are not tested. |
| Boot safety | **works**: two-stage m1n1 with an A/B stage-1 (falls back to the previous payload after a failed boot, 150 s watchdog), a self-reverting test payload, a four-payload ESP policy. The A/B fallback has fired for real once. |
| Power off, S1 freezer step | **work** on the 7.2 stack (`systemctl poweroff`, no boot error next boot; `pm_test=freezer`). Real s2idle is not tested. |
| Desktop | **works**: Hyprland, Waybar, foot, Xwayland on stock Arch Linux ARM packages, software rendered. |

### In test

| Area | State |
|---|---|
| WFI idle | **WFI-T1 passes** (one boot): the cores really sleep now and idle power on the charger drops from 16.4 W to 8.6 W. m1n1 has been appending `idle=nop` since its "disable wfi if it loses state" change; the patch ignores it. The 1 h soak, the per-CPU register check and promotion to the daily are open. [`contrib/pending/wfi-idle/`](contrib/pending/wfi-idle/) |
| Aurora PRs | Three are open on `aurora-silicon/linux`: **#1082** rtkit handshake wait 1 s to 10 s, **#1083** dockchannel-hid 50 ms settle after the AFE reset, **#1084** macsmc hwmon keeps a fan whose optional keys are missing. Held: CIO reset (#946 replaces it), cpufreq binding (#481), SMC match (#941), the J716s board DT. [`contrib/validated/aurora/prs/`](contrib/validated/aurora/prs/) |

### Blocked or not working

| Area | Why |
|---|---|
| GPU | No public driver for the 27.x GPU firmware interface; the M5 Pro is gated off in Aurora's tree. The desktop is software rendered. [`contrib/pending/gpu/`](contrib/pending/gpu/) |
| Display driver (DCP) | The firmware here is 27.3; Aurora's driver matches the method table of exactly 27.0.0. No scanout, no brightness control. [`contrib/pending/dcp/aurora/`](contrib/pending/dcp/aurora/) |
| Speakers | The machine boots safely with a volume ceiling and the protection daemon. The first tone makes every amplifier report `bad TDM clock`. The stop-time faults are fixed; a burst at stream start remains. Attended tests only. [`contrib/pending/audio/aurora/`](contrib/pending/audio/aurora/) |
| Wi-Fi and Bluetooth (N1) | The PCIe adoption, N1 transport, Wi-Fi and Bluetooth patches (16 of them) are in the series; the hardware steps have not been run. The firmware is personalised per unit and is not published. [`contrib/pending/wireless/aurora-n1/`](contrib/pending/wireless/aurora-n1/) |
| Camera, Thunderbolt/USB4, thermal zones | Design reports only. [`contrib/pending/isp-tb/`](contrib/pending/isp-tb/), [`contrib/pending/platform/`](contrib/pending/platform/) |

### The base (unchanged since 2026-11-05)

- **SMP, 18 cores**: needs a stub built from macOS 27.3 beta 1 or later, whose stage-2 mBoot carries Apple's
  fix for raw boot objects. No m1n1 or kernel change. [`docs/smp-t6050-raw-path.md`](docs/smp-t6050-raw-path.md)
- **Untethered boot**: stage 1 (in the stub) is a CHAINLOADING m1n1; stage 2 on the ESP is m1n1, kernel,
  device tree and initramfs in one file. Kernel updates are a file copy. [`docs/boot-and-recovery.md`](docs/boot-and-recovery.md)
- **NVMe** needs a 10 s RTKit handshake wait (the ANS firmware sometimes takes about 3 s).
- **iBoot's boot-failure counter** is cleared by Linux on reboot and by the A/B stage-1, so repeated Linux
  restarts no longer end in the "needs to be reinstalled" recovery.

## Quick start: build and install a payload

The payload is one file: m1n1 (0x400000 bytes) | boot arguments | `Image.gz` | device tree | initramfs.
[`mk-daily.py`](contrib/validated/aurora/tools/mk-daily.py) builds it from named, hash-pinned ingredients and
prints the commands for the swap; it never touches the machine. What may sit on the ESP, and how a failed test
returns to the last good payload, is in [`ESP-POLICY.md`](contrib/validated/aurora/tools/ESP-POLICY.md): read it first.

```bash
# 1. kernel: a worktree of aurora-silicon/linux at 33bec4016c46 + the series, then build it (recipe: series/SERIES.md)
git am contrib/validated/aurora/series/patches/*.patch
make LLVM=1 ARCH=arm64 defconfig asahi.config j716s.config && make LLVM=1 ARCH=arm64 -j Image.gz dtbs

# 2. check the ingredients, then build a test payload (it reverts itself if the network does not come up)
python3 -I contrib/validated/aurora/tools/mk-daily.py --list      # edit INGREDIENTS (paths, pins) for your machine first
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --label my-test

# 3. print the ESP swap, read it, run it yourself; boot the test with the Ethernet adapter attached
python3 -I contrib/validated/aurora/tools/mk-daily.py --deploy-plan --payload DIR/my-test-<date>-<hash>.bin --host root@<linux-ip>

# 4. once it reached the network, rebuild the same ingredients as the daily (no self-revert, battery on)
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --daily --battery --force
```

The stage-2 m1n1 of the daily is upstream plus `patches/m1n1/` (toolchain and recipe: [`m1n1-BUILD.md`](contrib/validated/integration/m1n1-BUILD.md)):

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
| `contrib/validated/aurora/` | The Aurora kernel work that has run on the machine: `series/` (the 60 patches and the rebuild recipe), `tools/` (`mk-daily.py`, `ESP-POLICY.md`), `atc-tunables/`, `pipe-park/`, `trackpad/`, `prs/` (upstream PRs), `STATE.md`. |
| `contrib/validated/integration/` | Hardware results (`RESULTS.md`), test kits and the patch set of the 7.2 stack. |
| `contrib/validated/desktop/`, `contrib/validated/legacy-7.2/` | Desktop setup; trackpad, SMC, cpufreq and USB-host work that ran on the 7.2 stack (what the fallback payload is made of). |
| `contrib/pending/` | Not proven yet, or design only: `audio` (with the Aurora audio kernel patches), `dcp`, `gpu`, `wireless` (with the N1 patches), `wfi-idle`, `boot-ab`, `dt-prep`, `platform`, `isp-tb`. |
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
