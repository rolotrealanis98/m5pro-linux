# Integration / hardware test results: J716s (2026-11-04)

## Bottom line
Stage A did not reach SSH, so I stopped working on the machine. No feature was hardware-tested.
- The M5 is on `payload-trackpad.bin` (fcc40240). It is not answering SSH, and someone has to go to it to recover it (see Asks).
- Stage B/C were done offline only. One combined kernel was built and the patch series was checked. Payloads are assembled but **never deployed**.

## Per feature
| Feature | Result | Evidence |
|---|---|---|
| LLVM-built kernel base (first boot of a macOS/clang build) | **FAIL**: kernel alive, no SSH | `~/Work/m5-logs/integration-20261104-184815-stageA-boot1/NOTE.txt` |
| Trackpad AFE reset (TEST-PLAN 2-3) | BLOCKED (boot never reached sshd) | same |
| SMC T1-T6 | BLOCKED, not deployed | - |
| cpufreq Stage 1-2 | BLOCKED, not deployed | - |
| USB step 1 (new kernel, old DTB) / steps 2-7 (usbhost DTB) | BLOCKED, not deployed | - |
| USB step 0 (m1n1 proxy probe) | not attempted (would require pulling boot.bin off the ESP and going tethered) | - |

## Stage A failure details
- Baseline before the deploy: gcc kernel 7.2.2-01023-g666335fea5e3-dirty, 18 CPUs, boot.bin a2407e83. Its dmesg and state are in `~/Work/m5-logs/integration-20261104-184617-baseline/`.
- Deploy at 18:48 EST, following trackpad TEST-PLAN step 1:
  - wrote boot.bin.new and checked its hash (fcc40240);
  - renamed it over boot.bin;
  - ran `systemctl reboot`.
- What the bridge saw after the reboot:
  - Both EEM gadgets re-enumerated (udc0 and udc2).
  - 10.55.0.2 and 10.55.2.2 answer IPv4 and IPv6 ping.
  - TCP 22 gives **connection refused** at +4, +9, +12, +20, +32 and +49 min. Nothing else is listening.
  - So the kernel and the initramfs gadget setup run, but sshd never starts. Either the root never mounted (initramfs shell on the panel) or systemd went to emergency mode.
  - dmesg could not be read: no service was listening, so there was no way in.
- I rebuilt both payloads byte for byte with the same recipe: m1n1-plain + default bootargs + Image.gz + DTB + `initramfs-tp.cpio.gz`.
  - Known-good a2407e83 = gcc `studio-artifacts/Image.gz` + `studio-artifacts/t6050-j716s.dtb`.
  - Failed fcc40240 = LLVM `trackpad/Image.gz` + `trackpad/t6050-j716s.dtb`.
  - **Only the kernel and DTB differ.** m1n1, bootargs and initramfs are identical.
- Ruled out offline:
  - Kernel config: identical apart from compiler symbols, plus `ARM64_BTI_KERNEL=y` on clang.
  - `__ex_table` in the LLVM vmlinux is sorted (864 entries), so the macOS sorttable host tool is fine.
  - The DTB change is exactly the trackpad diff:
    - new `smc_gpio_low` node;
    - `gpio` renamed to `gpio@67500000`;
    - 3 properties on multi-touch.
- Remaining suspects, unresolved:
  - (a) the macOS clang toolchain build itself (never booted before);
  - (b) the dockchannel-hid AFE patch;
  - (c) probing `smc_gpio_low` (the gp key bank) through the new DT node.

### Bisect payloads, built and not deployed (`~/Work/agents/integration/bisect/`)
| file | content | sha256 |
|---|---|---|
| X1-gcc-kernel+trackpad-dtb.bin | known-good gcc kernel + trackpad DTB (tests suspect c: the old gcc kernel already has the macsmc low-gpio cell) | 7a451fe70b0418bab74e1502529c5e17ffecb5cd1e2bd9012a113ecb4bb5bf20 |
| X2-llvm-trackpad-kernel+old-dtb.bin | LLVM trackpad kernel + known-good DTB (tests a+b; with no property, the driver falls back to today's sequence) | 418c92851a046a4ddbea7a817a8a92f0e0bb1c735db275921e0563ecbc78f0dd |

The studio DTB is byte-for-byte the base DT minus the trackpad diff (checked with dtc, phandles normalised), so X1 and X2 separate the two halves cleanly.

## What is on the ESP now (last read before the reboot)
| file | sha256 | what |
|---|---|---|
| /boot/m1n1/boot.bin | fcc402401b33325cac937037deb050660756a4d615182470b7dde3afad001a0d | trackpad payload (LLVM), **does not reach SSH** |
| /boot/m1n1/boot.bin.prev | a2407e836c05d38acd756c74f8d8bdf37b9c3a197ebb9c776b884140793f563c | known-good gcc payload, 18 CPUs |
| /boot/m1n1/boot.bin.known-good | a2407e836c05d38acd756c74f8d8bdf37b9c3a197ebb9c776b884140793f563c | same, extra copy |
| /boot/m1n1/boot.bin.prev2 | 66c917bf4c85aeec05b4c7801c958a6678d83ac9455beaf0c875058edaf1a839 | old single-CPU payload (the coordinator's "boot.bin.prev-1cpu"; saved as prev2 before the first deploy, not yet renamed because the machine is unreachable) |

## Asks for Rolando
1. **Recover the M5:**
   - Hold power until it is off, then hold power again into the boot picker and pick Macintosh HD.
   - In macOS, mount the 0.5 GB FAT partition labelled OMARCHY (GPT p4): `diskutil list` to find it, then `diskutil mount diskXsN`.
   - Then run `cp /Volumes/OMARCHY/m1n1/boot.bin.known-good /Volumes/OMARCHY/m1n1/boot.bin && diskutil eject /Volumes/OMARCHY`.
   - Shut down and power on into the Omarchy stub. It should boot the gcc kernel on 18 CPUs.
   - While p4 is mounted, also run `cp boot.bin.prev2 boot.bin.prev-1cpu` there.
2. Before recovering, if possible, photograph the panel. It shows either `m5.root=... did not mount; staying in initramfs` or systemd's emergency-mode prompt, plus the last kernel lines. That alone decides which way to bisect.
3. After recovery, over SSH: `journalctl --list-boots` and `journalctl -b -1 -p warning` will show whether the failed boot reached systemd (I can run these).

## Stage B/C offline results
- Worktree `/Volumes/linux-cs/wt-integration` (detached at trackpad 61c807bf4; changes are staged in the index, **no commits**).
  - SMC, cpufreq and USB patches applied with `git apply` and no conflicts. t6050-smc.dtsi took both the SMC hunk (SPMI reg 0x4000, comment) and the trackpad hunk (smc_gpio_low) cleanly.
- Config: trackpad .config + `CONFIG_MACSMC_POWER=y` + `omarchy-usb-host.config` (merge_config + olddefconfig).
  - PHY_APPLE_USB2, TYPEC and SN201202X =y; TPS6598X off; RTL8152/AX88179/UAS/RFKILL/CFG80211 =y.
- Build: LLVM=1, -j8, exit 0. The only warnings are the existing host-tool `gen-hyprel.c` -Wformat ones. Release `7.2.2-g61c807bf41a1-dirty`. Log: `build/build.log`.
  - Image.gz a8b88f3f1526ea2e0b080b18127f588970a62bcf4bdfdc14990b85bc47fb08fd
  - t6050-j716s.dtb 5eaee870886d26c4df3dabdc73bcaab37fc3ee3f306cca53586161e87624e4d5
  - t6050-j716s-usbhost.dtb ec1c3d371bd50fe79aa7e36d81b09e343be02164cbed4e287d356ae507c95879
- Payloads in `payloads/`, **UNTESTED**. Bootargs = default + `initcall_blacklist=macsmc_power_driver_init cpufreq.default_governor=userspace ignore_loglevel`; kboot appends `idle=nop arm64.nowfxt`.
  - UNTESTED-stageB-combined-j716s.bin 1be50388d5e0eb6db858357901455673a5b1eea99b2ab32985ccb9605f70b851
  - UNTESTED-stageC-combined-usbhost.bin c2e024dee9c0e995a821e14033836f4745f97352d2525cde63ad20ba85a141fa
  - Do not deploy them until the Stage A failure is understood: they share the same LLVM toolchain and trackpad changes.
- dtc unit_address_vs_reg on `gpio@67500000`/`gpio@67700000`: left as is. The names match asahi's t6030.dtsi exactly (same warning upstream, W=1 only), and the mfd binds by compatible.
- Not picked up: `~/Work/agents/platform/` patches (per coordinator).

## Patch set (`patches/`), compile-validated only, NOT hardware-validated
- `patches/linux/0001-0015`, to apply on BASE f31c51d61 (= 236788cd2 + omarchy patches 0001-0009 + j716s dt/ overlay):
  - 0001-0002 trackpad;
  - 0003-0005 SMC;
  - 0006 SMC DT (kernel-path copy of the omarchy dt/ change);
  - 0007-0009 cpufreq;
  - 0010 cpufreq DT (kernel-path copy);
  - 0011-0015 USB.
  - Checked: applying all 15 to f31c51d61 in a temporary index gives tree c762295205639498a9680a786ed453039f4bbfbe, identical to wt-integration.
- `patches/omarchy-m5/0003-integration-trackpad-smc-cpufreq-usb-combined.patch`: one patch on omarchy-m5 j716s @ 2c87598 (`git apply --check` clean). It contains:
  - trackpad dt, SMC dt+config, cpufreq generator+dtsi, USB dt/config/build-kernel.sh;
  - kernel patches carried in `patches/linux/` renumbered to avoid the SMC/USB 0010-0012 collision: 0010 trackpad, 0011-0013 SMC, 0014-0016 cpufreq, 0017-0019 USB.
  - Its dt/ files are byte-identical to the integration kernel tree's DT sources.

## Gated, and why
- macsmc-power: `initcall_blacklist` stays until SMC T6 passes on hardware.
- cpufreq: userspace governor until Stage 1 passes.
- USB host DTB: only after USB step 1.
- All of it waits on the Stage A failure being explained.
- Never: suspend, CPU hotplug, removing `idle=nop arm64.nowfxt`.

## Round 1 resolution (2026-11-05, coordinator)
- Root cause of "no SSH": NOT the kernel build. The ANS (storage coprocessor) firmware sometimes needs ~3 s to finish its
  asi init; `apple_rtkit_wait_for_completion` waits 1 s, nvme-apple logs `ANS did not boot` / `Reset failure status: -62`
  and the root never appears. The known-good gcc payload failed identically on the next boot. A manual rebind of
  nvme-apple from the initramfs shell brought the disk up (nvme0n1 p1-p6) and `switch_root` reached the Arch root.
- Fixes: kernel patch 0016 (RTKit handshake wait 1 s -> 10 s); host/macos/mk-debug-initramfs.sh (60 s root wait,
  dropbear on the gadget link, automatic nvme-apple rebind every 12 s after an "ANS did not" message).
- P3 = LLVM trackpad kernel (7.2.2-g8bcfb21b951d) + 0016 + trackpad DTB + debug initramfs, sha256
  fccf71bcad938f34312e89b9f8c46e4431f78536d742f98c884d5eeca57f9806. Deployed 2026-11-05 10:40 UTC.
- TRACKPAD PASS 3/3 boots: "host-driven AFE reset, power method 2" -> "AFE reset released" -> "Touch MT ready" at
  ~19-21 s each boot; macsmc-low-gpio line 28 `afe-reset` out hi ACTIVE LOW; 894,576 bytes of events on event2 in
  40 s of swiping (raw hidraw2 247,168 bytes; keyboard event1 3,984 bytes). NVMe at 8.3-10.7 s on all three boots.
- The LLVM/clang kernel build is therefore validated on hardware (18 CPUs, SSH, trackpad).
- ESP now: boot.bin = P3; boot.bin.prev = boot.bin.known-good = a2407e83 (gcc, no trackpad fix); boot.bin.prev-1cpu = prev2 = 66c917bf.

## Round 2 prelude (2026-11-05, coordinator): iBoot boot-failure counter
- The Stage B payload B1 (923f506a..., kernel 7.2.2-g61c807bf41a1-dirty) did boot fine; the "needs to be
  reinstalled" recovery after its deploy was iBoot's boot-failure counter, not the kernel. POWER_RESET_MACSMC
  was =m (no modules on the root), so Linux never wrote boot_stage / boot_error_count / panic_count in the
  PMU scratchpad; every watchdog restart from Linux counted as a failed boot and only a macOS boot cleared it.
- Fix (kernel patch 0017, on top of platform patch 0040): POWER_RESET_MACSMC=y, smc_reboot node enabled with
  the abbey scratchpad cells (boot_stage 0xf801, counts 0xf802, shutdown_flag 0xf80f bit 3),
  apple,poweroff-only (restart stays on the watchdog) but boot_stage is still set to 0 before a restart.
- Verified on hardware: read-only dump of 0xf800..0xf80f = `20 30 00 00 ...` after a macOS boot; after one
  Linux reboot the driver logged `PMU logged 1 boot error(s) and 0 panic(s)` and cleared it (0xf802 -> 0x00,
  boot_error_stage 0xf803 = 0x30). Cell offsets confirmed.
- B2 = B1 + 0016 (already in) + 0017, debug initramfs, gated args. sha256 55d95928... (old DTB),
  8a2c516e... (usbhost DTB). Deployed; boot.bin.prev = P3, boot.bin.b1 = B1, boot.bin.p3 = P3.
- B2 reboot series 2026-11-05 ~11:30 UTC: 3 consecutive Linux (watchdog) reboots, macsmc-reboot reported NO boot
  errors on any of them (the "PMU logged" line only prints when a count is non-zero), scratchpad stayed
  `20 30 00 30`, NVMe at 8.9-11.6 s, trackpad "Touch MT ready" every boot, 18 CPUs. Boot-failure-counter issue CLOSED.
