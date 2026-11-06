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

## Round 3 (2026-11-05, partial; agent stopped by Rolando before hand-back; coordinator summary)
- Baseline on B2 (old DTB): 18 CPUs, trackpad ready, logs integration-20261105-062910-r3-baseline-B2.
- SMC T1-T5 on B2 (integration-20261105-062933-r3-smc-T1-T5-B2/T1-T5.txt): macsmc RTKit init, macsmc-gpio
  (gP01) and macsmc-low-gpio (gp01) probed, "Apple SMC power/lid events" input, macsmc-rtc registered and set the
  clock, macsmc-reboot poweroff-only active, hwmon macsmc_hwmon present. PASS as far as recorded (T4/T5 files present).
- USB step 1 on B2 (integration-20261105-063307-r3-usb-step1-B2/step1.txt): three UDCs, gadgets m5_0/m5_2 configured
  high-speed, usb0/usb2 up, no xhci/phy/tipd lines with the old DTB. PASS (no regression).
- SMC T6 (battery/charger): the agent built payloads/r3/B2-power-T6.bin (sha 9d892b26...) = B2 without
  `initcall_blacklist=macsmc_power_driver_init`, deployed it and rebooted. RESULT: HARD HANG at ~7.8 s, last line
  `i2c_dev: i2c /dev entries driver` right after `input: Apple SMC power/lid events`, i.e. in/around the
  macsmc-power probe; no oops/panic text on the panel (photo 2026-11-05). FAIL. macsmc-power stays blacklisted;
  this confirms the October macsmc-power crash is real and lives in probe. Next: bisect inside macsmc-power
  (which SMC key read hangs; add dev_info before each key; test with the debug initramfs netconsole once available).
- cpufreq stage 1 and Stage C (usbhost DTB) were NOT reached.
- Parking for Rolando's trip: he restores boot.bin.b2 (or boot.bin.prev = P3) from macOS and sets Startup Disk to
  Macintosh HD; Linux resumes Sunday 2026-11-08.

## Round R1 (2026-11-06, solo)

Rolando alone with the MacBook, no Studio, no tether. Kernel `7.2.2-ge1d2d7313745` (integration
patches 0001-0034). Plan: `R1-TEST-PLAN.md`; kit: `R1-SOLO.md`, `host/macos/r1-deploy.sh`,
`r1/r1-local.sh`. Payloads R1-A `6d6a402b` and R1-B `c4edcb33` (hashes in `r1/SHA256SUMS-payloads`).
Evidence: the script's log folder on the ESP (`r1-a-20261106-1000`, `r1-b-20261106-1207`) plus panel
photos. The raw logs are not published (they carry the battery serial and other identifiers); only
hardware-description facts and numbers are quoted here.

### How we tested without the Studio
- Payloads were built on the Studio (`mk-r1-payloads.py`) and carried to the MacBook over iCloud Drive.
- Rolando swapped `m1n1/boot.bin` on the OMARCHY ESP from macOS with `r1-deploy.sh`, driven over
  Tailscale/SSH from the Studio: macOS side only, no Linux-side access and no USB tether.
- The ESP is the mailbox. `r1-deploy.sh` also puts `r1-local.sh` at the ESP root; at the Linux
  console (as root) `bash /boot/r1-local.sh a|b` collects the evidence into `/boot/r1-logs/`,
  runs the active checks and prints a framed PASS/FAIL/SKIP summary. After a boot, back in macOS,
  `r1-deploy.sh logs` copies the folder out.
- Panel photos cover the summary block and the boot trace.

### Found before the first boot
- The ESP's `boot.bin` was the hanging battery payload `9d892b26` (round 3 `B2-power-T6`), not B2.
  Kept as `boot.bin.power-t6`. It would have hung at ~7.8 s on the first boot.

### R1-A: boot and desktop checks (payload `6d6a402b`, battery driver off)
Booted 2 of 2 (the second boot after `systemctl reboot`; no PMU boot error logged).

| Check | Result | Evidence |
|---|---|---|
| Kernel and args | PASS | `7.2.2-ge1d2d7313745`, blacklist present, no `default_governor` |
| 18 CPUs | PASS | `nproc` = 18, up at 0.69 s |
| NVMe | PASS | partitions at 12.14 s, no ANS retry (RTKit init at 8.76 s). The script's limit was 12 s and showed FAIL; raised to 15 s |
| Trackpad | PASS | `Touch MT ready` at 19.3 s |
| macsmc-low-gpio | PASS | probed |
| SMC core | PASS | `hwmon0` with 4 temperature inputs, `macsmc-rtc`, `macsmc-reboot` (poweroff-only). The script reported "missing: hwmon" (check bug, fixed) |
| No macsmc-power line | PASS | driver blacklisted |
| cpufreq governor | PASS | `schedutil` on all three policies, max 4308000 |
| cpufreq idle floor | **FAIL (real)** | idle 2964000 / 2964000 / 1620000 instead of 1344000 / 1344000 / 1308000, while `top` showed 99.2 % idle |
| cpufreq under load | PASS | loaded cluster reaches 4308000 on cpu1, cpu7 and cpu13 |
| OPP offset | SKIP | `cpuhz`/`dvfs-regs` need the Studio |
| Keyboard backlight | PASS | 0/32/255/0 verified by eye. One log line: `leds_pwm led-controller: failed to read period for kbd_backlight, default to off` (benign) |
| eDP connector | PASS | `card0-eDP-1` connected, one mode, 3456x2160 |
| Notch | PASS (as expected) | `show-notch` property present, notch still hidden: m1n1 is unchanged |
| Lid | SKIP | `evtest` is not installed on the root |
| zram | PASS | `zram0`, zstd |
| iptables | PASS | v1.8.13, nf_tables backend |
| ufw | SKIP | not installed on the root |
| No new noise | PASS after fix | see script fixes below |
| Restart | PASS | comes back on R1-A |

cpufreq tables, recorded as read: `policy0` and `policy6` share a 14-step table
1344000..4308000; `policy12` has a 16-step table 1308000..4308000. The plan's open question (which
cluster is the efficiency cluster) is unanswered.

PMGR: the err/warn lines include 52 `Failed to reach power state` messages, all for four domains
named `b2bd_afc_0`, `b2bd_afc_1`, `b2bd_afr_0` and `b2bd_afr_3`, between 5 s and 23 s, and
`probe ... failed with error -110` / `deferred probe timeout` messages for some power domains at ~23 s. Not diffed against the B2 boot, so "nothing new vs B2" is
not established. The same family (58 lines) appeared on R1-B.

### R1-B: battery with the probe trace (payload `c4edcb33`, battery driver on, `macsmc_power.trace=1`)
**BOOTED 3 of 3.** The round-3 hang at ~7.8 s did not happen.

Probe trace (`trace: ...` lines, SMC keys read/written in this order):

| Step | Time / keys |
|---|---|
| probe start | 7.877 s |
| reads | `CH0R CHCE CHCC AC-i BSFC CHNC` |
| info queries | `CHIS BITV B0RC B0RI B0RV CHTE CH0C CH0I BCF0` |
| writes | `CH0K CH0B` |
| charge-limit keys | `CHWA` then `CHLS` read; both exist |
| strings | `BMDN`, `BMSN`, `BMDT` (size 255), then `BNCB` |
| battery registered | 8.834 s |
| AC adapter registered | 8.893 s |
| event notifier | 8.912 s |
| probe done | 8.932 s (1.05 s in total) |
| afterwards | `BITV`/`B0AV`/`BCF0` read every 60 s; the trace budget ends itself ("budget used up, tracing off") |

Values (on MagSafe):

| Property | Value |
|---|---|
| STATUS | Charging |
| HEALTH | Good |
| CAPACITY | 81 % |
| VOLTAGE_NOW | 12682000 uV |
| CURRENT_NOW | 3525000 uA |
| CHARGE_NOW / CHARGE_FULL / CHARGE_FULL_DESIGN | 6574000 / 8139000 / 8579000 uAh |
| CYCLE_COUNT | 32 |
| TEMP | 312 (31.2 C) |
| TIME_TO_EMPTY | absent on AC (0027) |

MagSafe unplug and replug: `macsmc-ac` online 1 -> 0 -> 1, STATUS Charging / Discharging /
Charging. The SMC logs `aceElec: Elec Cause` lines on the events. Charge thresholds were not written.

### r1-local.sh false positives found today (fixed in the kit)
| Check | Problem | Fix |
|---|---|---|
| `nvme` | limit 12 s, boot took 12.14 s | limit 15 s |
| `smc-core` | reported hwmon missing although `hwmon0` exists | hwmon check corrected |
| `noise` | pattern `bug:` matched "de**bug:**", then `pause_on_oops` in the kernel command line | pattern `\bBUG:`; the "Kernel command line" line is dropped before the pattern grep |
| `kbd-sysfs` | the `pwm\|pmgr` grep matched the unrelated PMGR power-state lines and the benign `leds_pwm` line | only `fpwm`/`pwm` lines count, "failed to read period" excluded |

### Not done today (needs the Studio or hardware)
PMP dumps, A/B stage-1, s2idle, OPP-offset tools (`cpuhz`, `dvfs-regs`), ufw test, lid `evtest`,
R1-C USB host (waiting for Rolando's USB-Ethernet adapter).

### Open items
1. **schedutil never drops to the lowest OPP.** Idle sits at 2964000 / 2964000 / 1620000 with the
   machine 99.2 % idle. Suspects: `idle=nop` polling and frequency-invariance accounting. Needs the
   Studio (`cpuhz`, `dvfs-regs`, a governor comparison).
2. **Which of patches 0018-0027 cured the battery hang is not known.** No bisect was done.
   Hypothesis only: the probe reads three 255-byte strings (`BMDN`/`BMSN`/`BMDT`) right before
   registering the battery, which makes 0018 (refuse a reply bigger than the read buffer) the
   leading suspect. A confirming test is R1-D/R1-E on one side and a payload with 0018 reverted on
   the other.
3. **The notch is hidden** until m1n1-plain is rebuilt with the show-notch patch
   (`patches/m1n1/0017`); the property itself is present.
4. **cpufreq tables / cluster identity:** the 14- and 16-step tables above and the plan's question
   about which cluster is E.
5. **PMGR `Failed to reach power state` lines** for the `b2bd_af*` domains and the ~23 s
   deferred-probe timeouts: diff against a B2 boot.
6. **Pending payloads:** `R1-D-olddtb-battery.bin` and `R1-E-usbhost-battery.bin` (B2 base arguments
   only, battery enabled, no trace/panic/pause_on_oops/ignore_loglevel) are built and in the iCloud
   folder; `r1-local.sh` has no `d`/`e` step yet.

## Round R2 (2026-11-06 evening, live over Tailscale)

Same evening as R1, same machine (J716s), kernel `7.2.2-ge1d2d7313745`. What changed: Rolando is at
the MacBook, and the Studio now reaches macOS and then Linux over Tailscale. Tailscale was installed
on the Linux root (it needed `pacman-key --init && pacman-key --populate archlinuxarm` first), so
payload swaps happen from Linux (`/boot` is the ESP) and logs are pulled live; no iCloud round trip
and no macOS visit between payloads. Tailscale addresses and device names are not recorded here.
Raw logs stay outside the repo (serial numbers, addresses): `r1-c-20261106-1812` (R1-C),
the R2-B boot folder and `r2b-live/` (dmesg and journal of the live session).

Payloads (hashes of the `boot.bin` as booted; build recipe `m1n1-BUILD.md`, sums in `r1/SHA256SUMS-r2-payloads`):

| Label | m1n1 (stage 2) | DTB | Battery | Hash |
|---|---|---|---|---|
| R1-C | old `742c5981` (patch 0005 skipped the USB-PD controller setup) | usbhost | gated | `019cf5f1` |
| R2-B | new `7497c0b1` = 0017 notch + 0018 USB-PD S0 setup | usbhost | on | `5091e1fe` |

R2-A (new m1n1 on the normal DTB, the isolating run for the tether port) was not run; R2-B was booted directly.

### Step table

| Step | Result | Evidence |
|---|---|---|
| R1-C: boot with the old m1n1 and the usbhost DTB | booted | `dwc3` at `0x2aa280000` in host role, `xhci-hcd` up with two root hubs (USB 3.1) |
| R1-C: hub in the left-front port | **FAIL**, port dark | no LEDs, no enumeration, no mouse; `usb-ports` "no port enumerated" |
| R1-C: the `-110` lines | not USB | `apple-pmgr-pwrstate` probe timeouts for `power-controller@280..2f0` at ~23 s (script false positive, fixed) |
| R1-C conclusion | no VBUS | our m1n1 patch 0005 skipped the USB-PD controller setup |
| R2-B: boot (new m1n1, usbhost DTB, battery on) | **PASS** | booted; fb0 `virtual_size` 3456,2234 |
| R2-B: notch rows kept (0017) | **PASS** | `fb0/virtual_size` 3456,2234 (was 3456,2160); the top rows are behind the camera housing |
| R2-B: USB host, hub plugged in BEFORE boot | **PASS** | `usb 1-1` high-speed hub (VIA Labs) at 8.65 s, then Genesys hubs, Anker hub, whole chain enumerated |
| R2-B: Logitech Bolt receiver | **PASS** | mouse works at the console (`hid-generic`, 2 input devices) |
| R2-B: card reader (GenesysLogic) | **PASS** | `usb-storage` bound, `sda`/`sdb` LUNs (empty slots: "Media removed") |
| R2-B: Realtek RTL8153 Ethernet | **PASS** | `r8152` -> `enu1u2u2`, carrier on at 24.5 s, DHCP through a systemd-networkd `20-wired.network` (`Name=en*`, `DHCP=yes`), `ping 1.1.1.1` ~12 ms |
| R2-B: unplug, then replug the hub | **FAIL** | after an unplug nothing re-enumerates (only the root hubs remain); a replug stays dark |
| R2-B: battery | **PASS** | 100 % / Charging on MagSafe throughout the session |
| cpufreq idle floor (R1 open item 1) | **resolved: measurement artifact** | see below |
| S1 sleep step (freezer only) | **PASS** | see below |
| Power off | **PASS** | see below |
| Desktop | in progress | see the line at the end |

### USB host: what works and what does not

- The USB-PD controller setup (hpm0/1/2/5 into S0, IRQs masked) runs once, in m1n1, at boot. With it
  restored in stage 2, the left-front port carries VBUS and the whole chain enumerates, provided the
  hub is attached before boot.
- **Plug-before-boot caveat.** The kernel has no `tipd`/`cd321x` driver (`CONFIG_TYPEC_TPS6598X` is
  not set and neither DTB has a node for the controllers), so nothing in Linux talks to the PD
  controllers. After an unplug nothing re-enumerates and a replug stays dark until the next boot
  (nothing in Linux re-arms the port). This is the next USB item.
- The RTL8153 logs `Direct firmware load for rtl_nic/rtl8153b-2.fw failed with error -2`: the
  `linux-firmware` file is not on the root. The adapter works without the patch; install the file to
  silence it.
- First boot of the session logged `20-wired.network:3: Invalid section header '[Network}'` from
  systemd-networkd (typo in the new unit); an older `en.network` matched the adapter. Fix the unit
  on the root.

### cpufreq idle question: resolved, a measurement artifact

- With schedutil (`rate_limit_us` 12), `cat scaling_cur_freq` reads 2964000 / 2964000 / 2880000 at
  0.00 load.
- `policy12/stats/time_in_state` shows ~800 s at 1308000 against a few seconds in every other state
  over the boot: the cluster sits at the floor, and the shell or SSH activity of the read wakes it.
- Switching policy12 to `ondemand` gives 1308000 within 15 s; `userspace` at 1308000 holds.
- R1 open item 1 ("schedutil never drops to the lowest OPP") is closed. `cpuidle` driver = none
  (`idle=nop`), noted.
- New question: `time_in_state` for policy12 also lists 4332000 / 4428000 / 4512000 / 4608000, above
  `cpuinfo_max_freq` 4308000. Table or boost-state question for the cpufreq work, not investigated.

### S1 sleep step (freezer only): PASS

`pm_test=freezer`, `echo freeze > /sys/power/state`, detached from the SSH session.

| Guard or event | Result |
|---|---|
| `sleep_power_off` | `-1` |
| `mem_sleep` | `[s2idle]` |
| logind and sleep safe drop-ins | installed first from `contrib/pending/platform/userspace/etc/systemd/`; `sleep.target` and `suspend.target` masked |
| write returned | rc=0 |
| log | "Freezing user space processes completed", 5 s debug wait, "Restarting tasks: Done", "PM: suspend exit" |
| after | SSH session alive |

Only the freezer level was run. Deeper `pm_test` levels and real s2idle are not done.

### Power off: PASS

`systemctl poweroff` over SSH at 19:43:38. The journal shows "Reached target System Power Off" and the
machine went dark within seconds (confirmed by Rolando). The next boot logged no PMU boot error. The
`macsmc-reboot` poweroff-only path is verified.

### r1-local.sh changes (v3)

| Change | Why |
|---|---|
| `usb-errors` counts `-110` only on lines with usb/xhci/dwc3/phy (and never `apple-pmgr-pwrstate`) | the R1-C FAIL was the pmgr timeouts, not USB |
| `usb-enum` (new, passive) counts `usb N-M: new ... USB device` lines and devices under `/sys/bus/usb/devices`, and prints them; `usb-ports` no longer reports "no port enumerated" when the chain is already up | the R1-C and R2-B reports contradicted the enumeration |
| `--battery` flag; default auto-detect from `/proc/cmdline` (no `initcall_blacklist=macsmc_power...` means battery expected, then the battery presence checks run in every step); `kernel-args` expects the blacklist only for gated payloads | R2 payloads have the battery on |
| `probe-done` is SKIP when the command line has no `macsmc_power.trace=1` | no trace on R1-D, R1-E, R2 |
| `notch` accepts 3456,2234 (rows kept) as well as 3456,2160 | m1n1 0017 |
| step `d` = general: passive collection plus battery and USB presence checks, no prompts, USB checks only on the usbhost DTB, no idle-frequency read | batch of checks for any payload |

Checked with `bash -n` and `shellcheck` (clean), and the new grep and enumeration logic against the
R1-C and R2-B dmesg (R1-C: six `-110` lines, none on a USB line; R2-B: seven new-device lines).
Not run on the machine yet.

### Open items after R2

1. **Kernel `tipd`/`cd321x` driver and DT nodes** for the four PD controllers, so a replug (and any
   port role or VBUS change) works at runtime. Until then USB devices must be plugged in before boot.
2. **cpufreq boost states** above `cpuinfo_max_freq` (4332000 .. 4608000) in policy12's `time_in_state`.
3. **PMGR `b2bd_af*` domain probe timeouts** (`Failed to reach power state`, `-110` at ~23 s): still
   present on R2-B, still not diffed against B2.
4. **OPP-offset tools** (`cpuhz`, `dvfs-regs`) not run.
5. **`ufw` and `evtest` not installed** on the root, so the ufw and lid checks stay SKIP.
6. Patch-bisect for the battery hang (R1 open item 2) is still not done; payload `R2-A` unrun.
7. The notch item (R1 open item 3) is closed by R2-B (3456,2234).

### Desktop (in progress)

A separate effort is installing Hyprland on llvmpipe on the machine; no results here yet.

## Round R3 (2026-11-06 evening/night): Aurora Silicon kernel on the J716s

Same machine and day as R1 and R2 (the "Round 3" above is the 2026-11-05 SMC round; this one is R3 of
the 2026-11-06 series). Question: does `aurora-silicon/linux` `integration/aurora` (Linux 7.3.0) run on
the J716s, as a base we could follow instead of carrying the whole asahi-wip stack? Rolando was at the
machine for the first boots and did the manual reboots; after R3-K, an autonomous loop with a
self-reverting payload took over. Analysis of the two trees: `../aurora/ANALYSIS.md`. Tools:
`../aurora/tools/`. Raw dmesg and the device trees stay outside the repository (they carry per-unit
values); only hardware-description facts are quoted.

### Kernel and payload recipe

| Part | What |
|---|---|
| Base | `integration/aurora`, Linux 7.3.0, `33bec4016c46` |
| + PR #945 | J716c device tree, merged (two trivial conflicts) |
| + our 0016 | RTKit handshake wait 1 s -> 10 s (see Round 1) |
| + PR #936 | T6050 NVMe and SART v4, cherry-picked |
| + PR #939 | T6050 combo PHY and dwc3, cherry-picked; display-crossbar conflicts resolved to the integration side |
| Not needed | PR #938 (the centauri drivers are already in integration) |
| Config | `make defconfig asahi.config` (16K pages), `RUST` off, boot-path drivers built in (list in `../aurora/tools/README.md`) |
| Result | 28 commits on top of `aurora/integration` for R3-N (branch `aurora-j716s`, tip `da5a44d086e6`); 31 for R3-Q (tip `4504ef7485be`, the three PHY commits added) |
| Payload | m1n1-plain `7497c0b1` (the R2 stage 2) + bootargs + `Image.gz` + DTB + initramfs; bootargs are the B2 ones, with `initcall_blacklist=macsmc_power_driver_init` on the gated payloads |

Two build gotchas on macOS: BSD `sed` breaks `arch/arm64/tools/gen-kernel-hwcaps.sh` (`\+`), fixed by
putting gnu-sed and the coreutils `gnubin` on `PATH`; and the first build used 4K pages by mistake
(`asahi.config` sets 16K).

### Device tree: what had to change

The J716s tree was proposed by the analysis agent (derived from J716c), then post-processed on the
decompiled DTS (`../aurora/tools/reorder-cpus.py` and hand edits):

1. **CPU order.** m1n1 stopped with `DT CPU 5 MPIDR mismatch 0x40100 != 0x40005`. Aurora's
   `t6050-max.dtsi` appends the sixth core of each cluster after the first fifteen, and m1n1 matches
   CPU nodes by index. The nodes were reordered to ADT order.
2. **Compatibles with no driver in integration.** `smc` (added the `apple,t8103-smc` fallback),
   `cluster-cpufreq` (`apple,t8112` fallback), `nvme`/`sart` (first `t8132`/`t6000` fallbacks, then
   PR #936 native), `cio` reset (`t8142` fallback and the node enabled), and `apple,smc-pcio-gpio`
   (no driver: keyboard and trackpad deferred on the AFE reset line). The last one was fixed with an
   `apple,smc-low-gpio` child and `apple,afe-reset-gpios = <low-gpio 28 ACTIVE_LOW>` on the
   `input@8000` **parent** node, which is where Aurora's driver reads it.
3. **NVMe.** Aurora's own driver first needed `resets` and `power-domains` (an ANS `power-controller@140`
   was added). With PR #936 both must be absent: the driver adopts the running ANS and restarts it
   without a PMGR reset.
4. **Left-front Type-C chain enabled:** `hpm1` `usb-pd@a` (`sn201202x`) on SPMI and the connector graph.
5. **Combo PHY tunables.** The PHY needs 14 `apple,tunable-*` lists that no public loader fills for
   T6050. They were generated from the ADT (`../aurora/atc-tunables/`); the per-unit values are not
   committed.

### Boots

| Payload | Hash | Change | Result |
|---|---|---|---|
| R3-B | `84b293c5` | first payload with CPU nodes in ADT order (checked over the m1n1 proxy) | proxy run, no root involved |
| R3-E | `e46437e2` | Type-C chain, compatible fallbacks, debug initramfs | initramfs shell: no NVMe, no keyboard |
| R3-H | `beec6567` | same plus the DIAG block on the panel | DIAG shows `nvme` failing with `-ENOENT` for its reset control, and the `dockchannel` AFE reset line unresolved |
| R3-I | `874142cc` | ANS power domain and reset in the DT | `nvme` IOP power ack `-62` after 1 s; keyboard still absent |
| R3-J | `4b7b9d0c` | our 0016, 10 s RTKit wait | still no ANS; **keyboard works** (AFE reset line fixed) |
| R3-K | `bed28a83` | PR #936, no ANS reset in the DT | **ROOT MOUNTS**; 18 CPUs; `apple_idle` registered; keyboard and trackpad; no USB (dwc3 has no reset control: the combo PHY has no driver) |
| R3-M | `cd53220e` | PR #939, `TYPEC_SN201202X=y`, selftest initramfs | the PHY driver probes and fails: it needs the tunables |
| R3-N | `f971f9e7` | tunables from the ADT (kernel `Image.gz` `5f8b3e78`) | PHY probes, then `dummy PIPE park failed (-1)`, dwc3 reset assert `-5`, no USB. The self-revert service restored R2-B automatically (first autonomous revert) |
| R3-O | `454b7434` | R3-N plus m1n1 0020 (T6050 PIPE park); same kernel, DTB fixed7 | PIPE check passed, dwc3-apple and xhci probed, hub enumerated at 1.1 s as `usb 1-1`. Then the SN201202x entered COMBO_DP2 ("mode 3", the hub's DP billboard), tipd dropped the USB role, xhci was removed, the PHY firmware restarted and `bank2+260 timeout: 881 & 400 != 400` (UC_TNBL_DONE never set: the firmware restarted on stale preloaded data), `start of mode 3 failed (-110)`, `sn201202x: failed to configure Type-C connection`, mux safe-mode failures, cable revalidation failed. Self-reverted automatically. Analysis: `../aurora/pipe-park/ANALYSIS-R3O.md` |
| R3-Q | `4083b7df` | R3-O's m1n1 (`a28b1815`) and DTB fixed7, kernel rebuilt with Aurora's three `j716c/thunderbolt` PHY commits (`b8f2be0fef93` restart the PHY firmware on its original data, `e604b7f414b4` carry on when the PIPE lock is not acknowledged, `6f93def30893` park the PIPE from a dummy producer on any clock); tree tip `4504ef7485be` | **WORKS**, see Result below. Installed as `boot.bin`, R2-B as `boot.bin.prev`; the selftest flag stays in the cmdline (inert while the network is up) |

Built but not individually reported here: R3-A (J716c DT), R3-C, R3-D, R3-F, R3-G (intermediate
DT/diag variants) and R3-L (`9ef02cfd`, R3-K with a handoff variant). Hashes are in
`~/Work/agents/aurora-kernel/payloads/SHA256SUMS` (not in the repository).

### Findings

- **Aurora's integration kernel boots the J716s to a mounted root and a working keyboard and trackpad**
  with PR #936 and a hand-fixed device tree: 18 CPUs, NVMe, `apple_idle` registered (cpuidle needs
  m1n1 to stop appending `idle=nop`).
- **0016 alone did not bring the ANS up with Aurora's driver (R3-J); PR #936 did (R3-K).** With it the
  driver adopts the running ANS and restarts it without a PMGR reset, so the ANS reset and power
  domain must not be in the DT.
- **The AFE reset line is the whole trackpad/keyboard dependency**, as in Round 1. On this kernel it
  is the `apple,afe-reset-gpios` property on the parent input node (the same GPIO as our trackpad
  patch: SMC low GPIO line 28, active-low), plus a driver that exists for the GPIO bank.
- **The combo PHY needs per-port tunables from the ADT.** No public loader fills them for T6050;
  `gen-atc-tunables.py` reproduces them. With them the PHY probes; the USB3 lock then fails.
- **R3-N failure, fixed by R3-Q:** `dummy PIPE park failed (-1)` with the PIPE registers dumped in the log,
  then dwc3 reset assert `-5`. Cause: m1n1's `usb_init` parked the PIPE with the T8103 field layout (m1n1 0020
  fixes it); the second blocker was the PHY firmware restart (R3-O), fixed by Aurora's commit `b8f2be0fef93`.

### Result (R3-Q, 2026-11-07 about 01:00, autonomous loop, nobody at the machine)

**First Aurora kernel boot with working USB3 on the J716s.** What R3-Q shows in the log:

- NVMe partitions at 0.36 s; 18 CPUs; cpuidle `apple_idle` registered and in use (WFI states, about 94 M
  entries in the first minutes).
- cpufreq `schedutil`, max 4380000 (policies 0 and 6) and 4608000 (policy 12). These are the top of the
  table because Aurora's tables mark no turbo states.
- Type-C port0 host/source with the partner in accessory mode. xhci bus 1 (USB2) and bus 2 (SuperSpeed):
  the hub enumerates Gen2x1 at 1.37 s, the RTL8153 comes up as SuperSpeed on 2-1.2.2 with carrier at
  5.6 s, the Logitech receiver is there. No PIPE-lock warning appeared.
- Keyboard through dockchannel-hid (stm, keyboard, actuator and tp-accel interfaces), `kbd_backlight` LED,
  `fb0` 3456x2234, and `macsmc-reboot` ("Handling reboot and poweroff requests via SMC": restart goes
  through the SMC, not the watchdog).
- Only noise in the errors: hid-generic "device has no listeners" twice.

**What each piece fixed** (the chain from R3-N to R3-Q):

| Piece | Fixed |
|---|---|
| m1n1 0020 (PIPE park) | R3-N's `dummy PIPE park failed (-1)`: m1n1 left `MUX_CTRL` at 0x22, which on T6050's layout is USB4 clock with dummy data. Now 0x42, the kernel's park returns at once, dwc3-apple probes (R3-O) |
| Kernel `b8f2be0fef93` (restart the PHY firmware on its original data) | R3-O's second PHY firmware start (the DP billboard switch, mode 3): the firmware restarted on stale preloaded data and `UC_TNBL_DONE` never came. The kernel now saves the first start's image and restores it for every restart |
| Kernel `e604b7f414b4` (carry on without the PIPE lock ack) | The lock ACK may never come; the USB3 switch goes ahead with a warning instead of staying on USB2. It did not fire on R3-Q |
| Kernel `6f93def30893` (park from a dummy producer on any clock) | The kernel twin of m1n1 0020; redundant with it but matches Aurora |
| DTB fixed7 | Combo PHY tunables, the AFE reset line, the Type-C chain and the other compatible fixes (unchanged from R3-N) |

**Caveat: per-unit tunables.** fixed7 carries the 14 combo-PHY `apple,tunable-*` lists generated from this
unit's ADT, so the DTB works on this machine only and is not committed. m1n1 0021 (`../aurora/pipe-park/`,
commit c909e17) is the proper path: it fills the tunables from the ADT in kboot, so a generic DTB (fixed6,
no tunables) works on any unit. R3-P (m1n1 0020 + 0021 + fixed6, `9d7865f2`) is built but was not booted;
R3-Q uses fixed7.

**Still missing on this kernel:**

- Trackpad multi-touch: "Touch MT ready" is absent and the Apple MTP input device is not created. The AFE
  reset we wired to macsmc-low-gpio line 28 satisfies the keyboard interfaces but not Aurora's dockchannel-hid,
  which expects the SMC pcIO GPIO line 2 through the `apple,smc-pcio-gpio` driver from their
  j716c/t6050-platform branch.
- Battery: still gated by `initcall_blacklist=macsmc_power_driver_init`. Aurora lacks our 0004 INIT_WORK
  fix and the 0003 fan key.
- Wi-Fi (PR #937 and the firmware handoff), display driver (DCP), GPU.

### Process: what went wrong and what we changed

Honest account, because the evening cost more reboots than it needed to:

- **The first full scan of the DTS already listed the unmatched combo PHY** (and the other
  driverless compatibles). Only the first failures were fixed, boot by boot, so the
  same class of problem (a compatible or provider with no driver) kept coming back and cost five
  reboots that an offline check could have replaced. Rolando did the reboots by hand and is tired of it.
- **A `=m` driver slipped through.** `TYPEC_SN201202X` was `=m` with no modules on the root; the new
  dependency check caught it before the boot.
- **Changes to the process:**
  - the diag initramfs prints the bound drivers and the storage/SMC lines on the panel when the root
    is missing, so a failed boot is a readable photograph;
  - the selftest initramfs installs `/usr/local/sbin/m5-selftest` and `m5-selftest.service` into the
    root; with `m5.selftest=1` and no network after 90 s it saves logs to `/boot/r1-logs/selftest-*`,
    restores `boot.bin.prev` and reboots. R3-N was the first autonomous revert and it worked;
  - `dt-depcheck.py` checks the DTS offline against the kernel tree (unmatched compatibles,
    disabled or driverless providers);
  - the rule: **no boot without the dependency check and all required drivers `=y`.**
- Limits of the self-revert: it only exists once the root has mounted, and it needs `boot.bin.prev`
  on the ESP to hold the last known-good payload.

### Still open

1. **Trackpad multi-touch** ("Touch MT ready" absent): needs the `apple,smc-pcio-gpio` driver (SMC pcIO GPIO
   line 2) from Aurora's j716c/t6050-platform branch, or a matching change in dockchannel-hid.
2. **Battery.** Gated by `initcall_blacklist=macsmc_power_driver_init`; needs our 0004 INIT_WORK fix and the 0003
   fan key on the Aurora tree.
3. **Wi-Fi/BT.** Needs PR #937 (PCIe), the FTAB firmware (personalised per unit, not in this repo) and
   the bootloader handoff.
4. **DCP** is gated on firmware 27.0.0 (this machine runs macOS 27.3 beta 1, 26C5035r); **GPU** is gated off for the M5 Pro
   in Aurora's tree.
5. **Portability of the USB3 result:** boot m1n1 0021 with the tunable-less DTB (R3-P, built, not booted).
6. Re-check on this kernel what Round R1/R2 established on ours: S1, power-off. Not run on the Aurora kernel.
   (cpuidle and cpufreq are covered by R3-Q: `apple_idle` and `schedutil` work.)
