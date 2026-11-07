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
| Result | 28 commits on top of `aurora/integration` for R3-N (branch `aurora-j716s`, tip `da5a44d086e6`); 31 for R3-Q (tip `4504ef7485be`, the three PHY commits added); 35 for R3-R (tip `6d9f1ec652a6`, the four r3r patches added) |
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
| R3-K | `bed28a83` | PR #936, no ANS reset in the DT | **ROOT MOUNTS**; 18 CPUs; `apple_idle` registered; keyboard (the trackpad's multi-touch device was not created, see R3-R); no USB (dwc3 has no reset control: the combo PHY has no driver) |
| R3-M | `cd53220e` | PR #939, `TYPEC_SN201202X=y`, selftest initramfs | the PHY driver probes and fails: it needs the tunables |
| R3-N | `f971f9e7` | tunables from the ADT (kernel `Image.gz` `5f8b3e78`) | PHY probes, then `dummy PIPE park failed (-1)`, dwc3 reset assert `-5`, no USB. The self-revert service restored R2-B automatically (first autonomous revert) |
| R3-O | `454b7434` | R3-N plus m1n1 0020 (T6050 PIPE park); same kernel, DTB fixed7 | PIPE check passed, dwc3-apple and xhci probed, hub enumerated at 1.1 s as `usb 1-1`. Then the SN201202x entered COMBO_DP2 ("mode 3", the hub's DP billboard), tipd dropped the USB role, xhci was removed, the PHY firmware restarted and `bank2+260 timeout: 881 & 400 != 400` (UC_TNBL_DONE never set: the firmware restarted on stale preloaded data), `start of mode 3 failed (-110)`, `sn201202x: failed to configure Type-C connection`, mux safe-mode failures, cable revalidation failed. Self-reverted automatically. Analysis: `../aurora/pipe-park/ANALYSIS-R3O.md` |
| R3-Q | `4083b7df` | R3-O's m1n1 (`a28b1815`) and DTB fixed7, kernel rebuilt with Aurora's three `j716c/thunderbolt` PHY commits (`b8f2be0fef93` restart the PHY firmware on its original data, `e604b7f414b4` carry on when the PIPE lock is not acknowledged, `6f93def30893` park the PIPE from a dummy producer on any clock); tree tip `4504ef7485be` | **WORKS**, see Result below. Installed as `boot.bin`, R2-B as `boot.bin.prev`; the selftest flag stays in the cmdline (inert while the network is up) |
| R3-R | `b457425e` | R3-Q's m1n1 (`a28b1815`) and initramfs; kernel tree `aurora-j716s` tip `6d9f1ec652a6` = R3-Q tree + r3r 0001-0004 (AFE settle 50 ms with a log line; hwmon fan port of our 0003; INIT_WORK-before-notifier port of our 0004; battery identity reads at key size); config `HID_MAGICMOUSE=y`, `HID_APPLE_MTP_HAPTIC=n`, `HIDRAW=y`; DTB fixed8 = fixed7 minus the unused `apple,smc-pcio-gpio` node; blacklist still on | **WORKS, trackpad included**, see Result (R3-R). Installed as `boot.bin` (self-revert loop, nobody at the machine); R2-B stays as `boot.bin.prev` |
| R3-S | `0d77e6f1` | R3-SERIES without `initcall_blacklist=macsmc_power_driver_init` (battery driver on), built by `mk-daily.py --battery` | **WORKS** (2026-11-07 09:17 UTC, self-revert loop with the A/B stage-1 as the second net, nobody at the machine), see Result (R3-S). The battery build is the daily payload from here on (`daily-20261107-ce3f10af`, self-test flag off) |
| R3-T | `08902f08` | m1n1 `pipepark-atc` (`f7555558` = 0020 + 0021; sha256 prefix `28b26ebc`), kernel `6d9f1ec652a6` (R3-R's), DT **without** baked tunables (`../aurora/dt/t6050-j716s-aurora-decompiled.dts` (retired, see git history)) | **WORKS** with USB3, trackpad and network (2026-11-07 about 02:00, self-revert loop, nobody at the machine). The live DT showed the 14 combo-PHY tunables filled by m1n1 0021, so the J716s DT is publishable (see "Publishable DT" below). Closes R3-P / open item 5 |
| R3-V | `8864d45e` | kernel tip `302945c1ecb3` = `6d9f1ec652a6` + PR #937 (PCIe) + PR #938 (T6050 centauri, 16 patches); config adds `SECURITY_LANDLOCK`, `ZRAM`, `PINCTRL_APPLE_GPIO`, `RFKILL`, `CFG80211`, `APPLE_CENTAURI`, `BT_HCICENTAURI`, `BACKLIGHT_CLASS_DEVICE`; same m1n1 and DT as R3-T | **WORKS** (2026-11-07, self-revert loop). pacman works again (Landlock was missing), trackpad, USB3 and network OK. `pcie-apple 1cb0000000.pcie: probe failed -22` is expected: the port is untrained (m1n1 0023 is opt-in, W1/W2) and the failure is harmless. Wi-Fi itself is not tested |
| R3-X | `734594ed` | R3-V plus our simpledrm eDP patch 0029 and `apple,internal-panel` on the framebuffer node | **WORKS** (2026-11-07 morning, self-revert loop): `card0-eDP-1` is back, so the Hyprland config has a DRM connector again; trackpad, USB3 and network as on R3-V. Became `boot.bin`, then `boot.bin.prev` once R3-SERIES was installed |
| R3-SERIES | `8c8dd836` | **Clean 58-patch series** (`../aurora/series/`) on `aurora-silicon` `integration/aurora` `33bec4016c46`: kernel `7.3.0-g4f630b11270d`, config `defconfig asahi.config j716s.config` with `RUST` off, DT = the series' own source-form `arch/arm64/boot/dts/apple/t6050-j716s.dts` compiled by the kernel build (no hand-edited DTB), m1n1 `pipepark-atc` `28b26ebc`, `initramfs-selftest`, bootargs as R3-X (incl. the `macsmc_power` blacklist and `m5.selftest=1`) | **WORKS** (2026-11-07 about 10:10, self-revert loop, nobody at the machine), see Result (R3-SERIES). Installed as `boot.bin` (daily); `boot.bin.prev` = R3-X |

Built but not individually reported here: R3-A (J716c DT), R3-C, R3-D, R3-F, R3-G (intermediate
DT/diag variants) and R3-L (`9ef02cfd`, R3-K with a handoff variant). Hashes are in
`~/Work/agents/aurora-kernel/payloads/SHA256SUMS` (not in the repository).

### Findings

- **Aurora's integration kernel boots the J716s to a mounted root and a working keyboard** (the trackpad
  followed in R3-R) with PR #936 and a hand-fixed device tree: 18 CPUs, NVMe, `apple_idle` registered (cpuidle needs
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

- **The `apple,t8142-cio-reset` fallback we booted R3-H through R3-X with was wrong.** It uses the register at offset
  `0x30`; T6050 needs `0x60` (same bits). It was harmless because nothing used that reset (the only consumer,
  `usb4_3_acio`, is disabled). The series fixes it properly with a driver entry, `apple,t6050-cio-reset`
  (patch 0051), and R3-SERIES booted with the CIO reset driver bound through that entry.

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

**Still missing on this kernel (as of R3-Q; superseded by the R3-R result below):**

- Trackpad multi-touch (diagnosed wrongly here; the real cause is under R3-R): "Touch MT ready" is absent and the Apple MTP input device is not created. The AFE
  reset we wired to macsmc-low-gpio line 28 satisfies the keyboard interfaces but not Aurora's dockchannel-hid,
  which expects the SMC pcIO GPIO line 2 through the `apple,smc-pcio-gpio` driver from their
  j716c/t6050-platform branch.
- Battery: still gated by `initcall_blacklist=macsmc_power_driver_init`. Aurora lacks our 0004 INIT_WORK
  fix and the 0003 fan key.
- Wi-Fi (PR #937 and the firmware handoff), display driver (DCP), GPU.

### Result (R3-R, 2026-11-07 about 01:45, autonomous loop, nobody at the machine)

**The trackpad works on the Aurora kernel, and so does everything R3-Q had.** Payload `b457425e`. Boot log
(times are kernel seconds):

| Time | Line |
|---|---|
| 0.205 s | `input: Apple MTP multi-touch ...` and `magicmouse ... input: HOST HID v5.10 Mouse` |
| 1.42 s / 1.47 s | `multi-touch: AFE reset asserted` / `released` (the 50 ms settle from r3r 0001) |
| 1.64 s | `New AFE[0] cbor image received` |
| 1.72 s / 1.73 s | `Interface multi-touch is now ready` / `Touch MT ready` |

On our 7.2 kernel `Touch MT ready` came at about 19 s, so this is a faster path to a working trackpad. Also in
the log: 9 USB devices enumerated, Type-C port0 plus its partner, and zero error lines once the PMGR noise is
filtered out.

**Root cause of the earlier miss** (analysis: `../aurora/trackpad/ANALYSIS.md`): `hid-magicmouse` was `=m`
(`HID_APPLE_MTP_HAPTIC=m` forces it to `m` through its Kconfig dependency) and nothing loads modules for this
kernel, so the multi-touch HID device never bound, `dchid_open()` never ran, and the AFE reset was never
driven. The wiring through `macsmc-low-gpio` gp1c line 28 was correct all along. The R3-Q conclusion that
Aurora needed `apple,smc-pcio-gpio` was wrong: that node was driverless in this tree and fixed8 simply drops
it. The cost of `HID_APPLE_MTP_HAPTIC=n` is no haptic feedback on click (the click is still reported); the
optional pcIO GPIO port (`../aurora/trackpad/patches/optional-pcio/0005`) was not needed.

**What was added to R3-Q's tree** (recipe: `../aurora/trackpad/R3-R-RECIPE.md` (retired, see git history)): the four `r3r` patches (35
commits above `aurora/integration`), `HID_MAGICMOUSE=y`, `HID_APPLE_MTP_HAPTIC=n`, `HIDRAW=y`, DTB fixed8.
The hwmon and macsmc-power patches are inert here: hwmon is disabled in the DT and the battery driver is still
blacklisted.

**ESP state:** `boot.bin` = R3-R; `boot.bin.prev` = R2-B (our 7.2 kernel, the rollback);
`boot.bin.r3q`, `boot.bin.b2`, `boot.bin.known-good`. Older spares were pruned because the 500 MB ESP filled
up; every self-revert also stores a 25 MB `boot.bin.failed`, so spares need pruning after each revert.

**Still missing on the Aurora kernel after R3-R:**

- **Battery** (R3-S, same payload without the blacklist): **works** through the loop once the A/B stage-1 was in place, see Result (R3-S).
  Whether r3r 0004 (battery identity reads at key size, Aurora's code) cures the probe hang at about 7.8 s is
  unknown; our 0003/0004 were already in the 7.2 B2 payload and it still hung.
- **USB replug** (hot-plug after boot) not tested on this kernel.
- **Wi-Fi/BT:** PR #937 plus the N1 firmware handoff.
- **Display driver (DCP):** firmware-compat gate. **GPU:** gated off in Aurora's tree.
- **cpuidle beyond WFI:** m1n1 still appends `idle=nop`.
- **m1n1 0021** (R3-P, built, not booted): the DTB still carries this unit's PHY tunables.
- S1 and power-off on this kernel (not run).

### Result (R3-T and R3-V, 2026-11-07 02:00-05:30, self-revert loop, nobody at the machine)

- **R3-T (`08902f08`):** m1n1 `pipepark-atc` (`f7555558`, 0020 + 0021) with the DT that has no `apple,tunable-*`
  lists. USB3, trackpad and network came up as on R3-R, and the live device tree showed the 14 tunables filled by
  m1n1. 0021 is therefore verified on hardware, and the "per-unit tunables" caveat of R3-Q/R3-R no longer applies.
- **R3-V (`8864d45e`):** kernel `302945c1ecb3` (R3-R's tree + PR #937 + PR #938 centauri, 16 patches) and the config
  additions listed in the table. Landlock fixes pacman (it needs `CONFIG_SECURITY_LANDLOCK` for its download
  sandbox). Trackpad, USB3 and network unchanged. `pcie-apple 1cb0000000.pcie: probe failed -22` is the PCIe
  driver finding an untrained port; nothing depends on it and nothing broke.
- **R3-X** (`734594ed`; R3-V + simpledrm eDP patch 0029 + `apple,internal-panel` on the framebuffer node) booted: `card0-eDP-1` is back.
- Desktop: an Omarchy-style Hyprland setup from Arch ARM repo packages is installed on the machine
  (`../desktop/omarchy/`). The idle lock stays disabled until `passwd rolo` has been run.

### Result (R3-SERIES, 2026-11-07 about 10:10, self-revert loop, nobody at the machine)

First boot of the kernel built from the **clean 58-patch series** (`../aurora/series/`, canonical recipe in
`../aurora/series/SERIES.md`) instead of the hand-assembled `aurora-j716s` branch. Payload `8c8dd836`: kernel
`7.3.0-g4f630b11270d` on `aurora-silicon` `integration/aurora` `33bec4016c46`, config `defconfig` + `asahi.config` +
`j716s.config` (`RUST` off), DT compiled by the kernel build from the series' source-form `t6050-j716s.dts`, m1n1
`pipepark-atc` `28b26ebc`, `initramfs-selftest`, bootargs as R3-X (blacklist and `m5.selftest=1` included).

- **Booted and stayed up:** network, `card0-eDP-1`, trackpad (`Touch MT ready` at 1.34 s), `apple_idle`, NVMe
  partitions at 0.37 s, no error lines after filtering the PMGR noise and the expected `pcie-apple` `-22`.
- **`macsmc` bound through the native `apple,t6050-smc` match** (patch 0052), with no `apple,t8103-smc` fallback in the DT.
- **The CIO reset driver bound with its own T6050 entry** (patch 0051), not the `t8142` fallback (see Findings).
- **ESP:** `boot.bin` = R3-SERIES (the daily payload); `boot.bin.prev` = R3-X (the revert target); `boot.bin.b2`,
  `boot.bin.known-good`.
- **Open points from the series work:**
  - ask Aurora how their m1n1 boots J716c with the old CPU order (we need the ADT order, patch 0054);
  - cpufreq: the J716s uses the `apple,t8112-cluster-cpufreq` fallback; decide between it and a `t6050` soc info;
  - `dtbs_check` was not run (no dt-schema on the Studio);
  - `apple,internal-panel` on the simpledrm node needs a binding patch;
  - hwmon stays disabled in the DT until the `F0md`/`F1md` keys are read;
  - the battery driver is still blacklisted (R3-S, attended).
- **PR plan:** `../aurora/series/UPSTREAM-NOTES.md`; patches 0001-0044 are Aurora's own commits carried as-is, 0045-0058
  are ours.

### Publishable DT

`../aurora/dt/t6050-j716s-aurora-decompiled.dts` (retired, see git history) (and its `.dtb`) is the J716s device tree for the Aurora kernel
with **no per-unit values**: the combo-PHY tunables are filled in by m1n1 0021 at boot, as R3-T showed. It is the
decompiled PR #945 J716c DT plus the J716s edits of this round. The source-form `t6050-j716s.dts` against Aurora's
dtsi files now exists as patch 0057 of the series (`../aurora/series/dt/t6050-j716s.dts`) and booted in R3-SERIES;
the decompiled file is kept as the reference.

### Attended queue (needs Rolando at the machine; reason in parentheses)

1. **R3-U**: m1n1 0024 (coprocessor-log reservations) plus the opt-in DCP handoff (new loader code; a stage-2
   failure needs a power-hold to recover).
2. **W0 / W1 / W2** Wi-Fi steps (`../../pending/wireless/aurora-n1/R3-W-RECIPE.md`). W0 is a read-only port status. W1 and W2
   train apcie0 port 0 and may disturb NVMe, which sits on the same controller; the FTAB firmware has no ticket yet.
3. **R3-S** battery (the probe hang history: a hang is not self-recoverable without the A/B stage-1 watchdog).
4. **Audio** (attended only; the AOP setup mailbox may SError and the speakers can be damaged by a wrong amp setup).
   Recipe: `../../pending/audio/aurora/R3-AUDIO-RECIPE.md`.
   - **Kernel:** built in the Fedora container (Rust on, AOP stack), `Image.gz` `00e8df6f`, tree `wt-aurora-audio` tip
     `1d2ac24c066e` = the R3-X tree + 11 audio patches. It is not the series kernel (`RUST` is off there); folding the 11
     patches into the series is still to do.
   - **Payloads:** **R3-AUDIO-A** `a7c05d1a` (mic and jack on, speakers left in hardware shutdown) first, then
     **R3-AUDIO-B** `34e96037` (speakers at amp level 10, `speaker_max_db=-40`). Neither is run by the autonomous loop.
   - **Root userspace** is prepared from repo packages (pipewire, wireplumber, UCM, graphs, J716 speakersafetyd profile;
     `../../pending/audio/aurora/audio-root-setup.sh`).
   - **Packages that must be built:** `speakersafetyd`, `asahi-audio` (with the `bankstown` and `triforce` lv2 plugins)
     and `alsa-ucm-conf-asahi` are **not in the Arch Linux ARM repos**. Script:
     `../../pending/audio/aurora/build-audio-pkgs.sh`. Rolando runs it: the permission layer blocks agents from building
     external code.
   - **Speaker boot is blocked until `speakersafetyd` is installed** on the root; R3-AUDIO-A (no speakers) does not need it.

Status lines for the rest: DCP is **no-go for scanout** until a 27.3 method table exists (firmware
AppleDCP-1317.60.10, SDK 27.3, against the driver's exact `"27.0.0"`; `../../pending/dcp/aurora/ANALYSIS.md`); GPU is gated off
in Aurora's tree.

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

**Update 2026-11-07:** item 5 is closed by R3-T (m1n1 0021 verified, publishable DT). Items 2 and 3 and the DCP part of 4 are now the "Attended queue" above.

1. ~~Trackpad multi-touch~~ **resolved by R3-R** (`HID_MAGICMOUSE=y`; see the Result above).
2. **Battery.** R3-S (R3-R without `initcall_blacklist=macsmc_power_driver_init`), with Rolando present. r3r
   0003 and 0004 are the Aurora-tree ports of our INIT_WORK fix and the new key-size identity reads.
3. **Wi-Fi/BT.** Needs PR #937 (PCIe), the FTAB firmware (personalised per unit, not in this repo) and
   the bootloader handoff.
4. **DCP** is gated on firmware 27.0.0 (this machine runs macOS 27.3 beta 1, 26C5035r); **GPU** is gated off for the M5 Pro
   in Aurora's tree.
5. **Portability of the USB3 result:** boot m1n1 0021 with the tunable-less DTB (R3-P, built, not booted).
6. Re-check on this kernel what Round R1/R2 established on ours: S1, power-off, USB replug. Not run on the Aurora
   kernel. (cpuidle and cpufreq are covered by R3-Q: `apple_idle` and `schedutil` work; deeper idle than WFI
   needs m1n1 to stop appending `idle=nop`.)

### Result (R3-S, 2026-11-07 09:17 UTC, self-revert loop + A/B stage-1, nobody at the machine)

Payload `r3-s-battery-20261107-0d77e6f1.bin`: the R3-SERIES ingredients (series kernel `7.3.0-g4f630b11270d`,
series DT, m1n1 `pipepark-atc` `28b26ebc`, `initramfs-selftest`) with the `macsmc_power` blacklist dropped and
`m5.selftest=1` kept. `boot.bin.prev` was R2-B (our 7.2 kernel, networked), the A/B stage-1 watchdog armed.

- **Boot:** network up at 23 s; boot slot `primary`; `m5-selftest` finished (no revert, no marker); uptime past
  160 s with the kernel feeding the 150 s watchdog; `dmesg -l err` empty apart from the expected untrained
  `pcie-apple` probe.
- **Battery (`macsmc-battery`):** `status=Full capacity=100 capacity_level=Full voltage_now=13.034 V
  current_now=0 charge_now=7.950 Ah charge_full=8.001 Ah charge_full_design=8.579 Ah cycle_count=33 temp=27.5 C
  health=Good present=1 charge_behaviour=[auto] auto-discharge`.
- **AC (`macsmc-ac`):** `ONLINE=1`, `INPUT_POWER_LIMIT=64.8 W` (the MagSafe brick in use).
- **SMC:** RTKit protocol 12 at 0.10 s; power/lid input device; reboot/poweroff via SMC. No probe hang: the
  R1-era 7.8 s hang is gone with the work-init patch (series 0048) on the Aurora kernel too.
- **Not exercised:** discharge (the brick stayed in), MagSafe unplug/replug events, `tps6598x` source role.

**Promotion:** `daily-20261107-ce3f10af.bin` = the same ingredients, `--daily --battery --force` (self-test flag
off, battery on) installed as `boot.bin`; `boot.bin.prev` stays R2-B `5091e1fe`; the ESP was pruned to four
payloads (`boot.bin`, `boot.bin.prev`, `boot.bin.known-good`, `boot.bin.b2`). The verification reboot of the new
daily is recorded in `contrib/validated/aurora/STATE.md`.

### Result (R3-AUDIO-A2 and R3-AUDIO-B2, 2026-11-07 09:27-09:45 UTC, self-revert loop + A/B stage-1; Rolando near the machine for the sound)

Both payloads: series audio kernel `7.3.0-g32512dab5b4e` (`j716s-series-audio`, Rust on, AOP stack), m1n1 `pipepark-atc`
`28b26ebc`, `initramfs-selftest`, `boot.bin.prev` = the battery daily `ce3f10af`. Root prepared with `audio-root-setup.sh` and
the Studio-built packages (speakersafetyd 2.0.1, triforce-lv2 0.3.2, alsa-ucm-conf-asahi 10; bankstown and asahi-audio did
not build and are not needed by our graphs).

**A2 (`526ef58c`, mic + jack DT, speakers held off): WORKS.** Network at 23 s, no revert, trackpad up. Cards: `AppleJ716AOP`
(`t8140-aop-audio`) and `AppleJ716` (`macaudio`). AOP: RTKit protocol 12, 13 AFK endpoints, `aop-audio`, `aop-audprov`,
`aop-voicetrigger` announced; `cs42l84` revision 36; six `tas2764` probed ("no brownout configuration" only); both ADMACs.
macaudio: "the boot loader passed no amp levels, disabling speakers" (expected on A), 0 woofer controls.
- **Mic:** `arecord -D hw:AppleJ716AOP,0 -f FLOAT_LE -c 3 -r 48000`: first open logs `lpai channel masks: 0x0`, `pdm0 config:
  0x0`, `pdm0 hf decimator: 0x0` (accepted). Ambient (nobody there): RMS 0.000082 (-82 dBFS) on all three capsules, not
  zeros. Speech (Rolando talking, on B2, same AOP): RMS 0.000293 (-71 dBFS), peaks 0.0025 (-52 dBFS), per-second RMS
  following the voice, three capsules within 0.2 dB. **Microphone works.** Jack switches present (`Headphone Jack`,
  `Headset Mic Jack`, both off), headphones not tested.

**B2 (`fa0161a2`, speaker DT, `snd_soc_macaudio.speaker_max_db=-40`): boots and is safe; first sound faults.** No revert,
16 woofer/tweeter controls, `pcmC1D2c` (Speaker Sense) present.
- **Gate fix:** speakersafetyd did not start: our udev rule had `ATTRS{id}` and `DRIVERS` on different parents, which udev
  never matches (all parent keys must match one parent). Without the daemon the volumes stayed locked (silence, the safe
  failure). Rule fixed (id only), reloaded, triggered: daemon active, parses `apple/j716.conf` (six speakers, amp gain
  16 dBV, tweeter max 0.59 W, woofer 0.89 W), kernel then prints `Speaker volumes unlocked` and `Speaker volume ceiling
  -40 dB`; `Speaker Volume` controls at 121 = -40 dB; `Amp Gain Volume` = 10 (its max).
- **Routing:** `plughw:AppleJ716,1` alone fails ("no backend DAIs enabled for Secondary"): the front end must be routed with
  `Speaker Playback Mux` = Secondary and `Speaker Switch` = on (no UCM: alsaucm cannot import our profile yet).
- **First sound:** 2 s 1 kHz at -40 dBFS, six channels, `aplay` exit 0, daemon saw "Sample rate: 48000". At the end of the
  stream every amp logged `fault: bad TDM clock` (20 fault lines, context `02,19,00,00,04` on i2c0 and `02,39,00,00,05`
  on i2c2). This is the recipe's "AOP stopped the serializer under the amps" row (edimoldovan: mute toggle, undrained
  sense). Stop rule applied: logs saved to `/boot/r1-logs/audio-b2-20261107/` (private), `Speaker Switch` off, daily
  restored as `boot.bin` with R2-B as `boot.bin.prev`. Rolando heard nothing, which proves little: -40 dBFS under a -40 dB ceiling is about -80 dB, below the room.
- **Reboot after the speaker test did not complete cleanly.** Turning `Speaker Switch` off produced another burst of
  `bad TDM clock` (358.6-358.8 s), then `Speaker volumes locked: Lock timeout` (359.8 s); `systemctl reboot` ran to
  "Sending SIGTERM to remaining processes" (361 s) and the machine only came back 52 s after the command (a clean reboot takes
  about 22 s), with iBoot's PMU boot-error count at 1 (`pmu-scrpad` `300100` instead of `2f0000`). **The A/B stage-1 did its
  job for the first time in anger:** it booted `boot.bin.prev` (R2-B, 7.2) as `fallback-after-failure`, network up, and the
  next plain reboot cleared the count and returned to the primary slot. The audio kernel's reboot path hangs or resets
  abnormally after the amps faulted (shutdown/remove in tas2764, macaudio or the AOP speaker path, under investigation).
- **Next:** compare with edimoldovan's fix for the TDM-clock fault on J714c (his tree after 83d711c3a9), and check whether
  the fault is on stream stop only (the daemon saw a valid rate, no fault during the 2 s).

### Result (HWMON-T1, 2026-11-07 09:49 UTC, self-revert loop + A/B stage-1, nobody at the machine)

Payload `hwmon-t1-20261107-4f68e1be.bin`: the battery daily's kernel (`7.3.0-g4f630b11270d`) with the dt-prep SMC sensors
DTB (`contrib/pending/dt-prep/patches/hwmon/0001`: hwmon-common, dual fans with `F0md`/`F1md`, laptop set; the `TCMb` die
key and the shared temperature nodes removed so discovery can run), `m5.selftest=1`, prev = the daily `ce3f10af`.

**WORKS.** Primary slot, 18 CPUs, network, no revert. `macsmc_hwmon` registered (hwmon2) beside `macsmc_battery`,
`macsmc_ac`, the Type-C source and the NVMe; no probe message at all, which is the driver's success path.
- Readings at idle on the charger: AC input 19.7 V / 0.93 A / 18.4 W, total system power 13.5 W, heatpipe 9.4 W,
  battery 13.03 V; fans 0 rpm with min 1350 and max 5349 / 5777 rpm (fans off at 28 C, `fan*_target` 0); discovered
  temperatures: 60+ channels (die TVD* about 51 C, memory TVM* 32-40 C, ambient Ta* 31-42 C, fan-side TfC* 36-39 C).
- The 3.8 V rail power reads 0 (key present, value zero): check `PMVR` on macOS before trusting it.
- Side note, this boot only: the first USB enumeration of the hub failed at 1.9-2.2 s (`device not accepting address`,
  `hub failed to enable device`, -108) and the retry at 3.7-5.0 s brought everything up (Ethernet, hub, keyboard dongle).
  Seen once in 12 boots today; worth watching with the PHY tunables.
- Fan control not tried (the T6050 SMC has no `Ftst` unlock key; see `dt-prep/hwmon/CHECK.md`).
- Next: RIGHTPORT-T1, then the combined DTB as the daily.

### Result (RIGHTPORT-T1, 2026-11-07 09:55 UTC, self-revert loop + A/B stage-1, nobody at the machine, nothing in the port)

Payload `rightport-t1-20261107-ee1dba8e.bin`: the daily kernel with the dt-prep right Type-C port DTB
(`contrib/pending/dt-prep/patches/right-port/0001`: ATC2 dwc3, combo PHY, mailbox, two DARTs and the three power
domains enabled; `hpm2: usb-pd@c` on the previously disabled `nub_spmi_a1`; connector graph), `m5.selftest=1`,
prev = the daily `ce3f10af`.

**WORKS at the probe level.** Primary slot, 18 CPUs, left-port Ethernet and dongle as before, no revert, no new errors.
- Every right-port node bound: `382280000.usb` -> `dwc3-apple`, `383000000.phy` -> `apple-t6050-dp-phy`,
  `383148000.mailbox` -> `apple-mailbox`, both DARTs -> `apple-dart`.
- The a1 SPMI bus works on Linux for the first time: `spmi-2`, device `2-0c` -> `sn201202x`, giving Type-C `port1`
  (revision 1.2, PD revision file present, `waiting_for_supplier` no longer set, role defaults device/sink with nothing
  plugged). The dependency-cycle notices for the new connector match the left port's.
- No host bus on it yet, as expected: dwc3 starts in device role until the PD controller reports a partner. Needs the hub
  plugged into the right port once (attended, trivial) to show `usb3`/`usb4` buses and VBUS from the m1n1 0018 S0 setup.
- Next: STACK-T1 (sensors + right port together), then that DTB becomes the daily.

### Result (STACK-T1, 2026-11-07 10:00 UTC, self-revert loop + A/B stage-1, nobody at the machine)

Payload `stack-t1-20261107-98d4a1a6.bin`: the daily kernel with both dt-prep DTB changes together (SMC sensors + right
Type-C port), `m5.selftest=1`, prev = the daily `ce3f10af`. **WORKS:** primary slot, 18 CPUs, network, no revert, no
errors; `macsmc_hwmon` plus a second Type-C source supply (`tps6598x_source_psy_2_0c`) and `port1`; right-port dwc3 bound.
The two DT patches are now series 0059 (sensors) and 0060 (right port); the combined DTB becomes the daily
(`daily-20261107-*` built with `--daily --battery --force`, self-test flag off). Right-port host mode still needs a plug test.

### Result (WFI-T1, 2026-11-07 10:08 UTC, self-revert loop + A/B stage-1, nobody at the machine)

Payload `wfi-t1-20261107-040d4866.bin`: kernel `7.3.0-gf080637018df` (`j716s-betizzel` = the series + `contrib/pending/
wfi-idle/patches/linux/0001` "T6050 idles in WFI even with idle=nop" + 0002 PM_DEBUG), the daily's DTB (series 0059+0060),
battery on, `m5.selftest=1`, extra `kvm-arm.wfi_trap_policy=trap sysctl.kernel.panic_on_rcu_stall=1`; prev = the daily
`275d84ec`. The command line still ends in m1n1's `idle=nop arm64.nowfxt`.

**WORKS, and it is the biggest power change so far.** Primary slot, 18 CPUs, network, no revert, no RCU stall, no Oops or
SError. dmesg: `Apple: preserving registers across WFI` and `Apple: idling in WFI, ignoring idle=nop`; cpuidle driver
`apple_idle`, CPU 0 spent 209 s of its first 211 s in the WFI state (38814 entries), so the cores really sleep now.
- **Idle power on the charger** (SMC `PSTR`, read moments apart at the same idle): daily (spinning idle) 16.4 W total,
  5.7 W heatpipe -> WFI-T1 8.6 W total, 1.9 W heatpipe. Roughly half; betizzel saw 15.3 W -> 5.6 W on his J714s.
- Nothing else changed: the series DT, battery, sensors, right-port probe, trackpad and USB as on the daily.
- Not yet: the 1 h soak and the per-CPU register check (T1 soak), `apple_keep_idle_nop` A/B (T2), promotion to the daily
  with `kvm-arm.wfi_trap_policy=trap` in BASE (T4 in `wfi-idle/REPORT.md`).

### Result (R3-AUDIO-B3, 2026-11-07 10:13 UTC, self-revert loop + A/B stage-1, nobody at the machine)

Payload `audio-b3-20261107-28509219.bin`: kernel `7.3.0-g030e2113e26b` (`j716s-audio-tdm`: the B2 audio kernel +
`audio/tdm/patches/0001` Ed's LW1 sense alignment + `0002` keep the AOP speaker service alive until the back-end's
hw_free), the spk DTB with `apple,deferred-shutdown` on all six amps, battery on, `speaker_max_db=-40`, `m5.selftest=1`,
prev = the daily `275d84ec`.

- **Boot and gates:** primary slot, both cards, speakersafetyd active at 1.88 s (udev rule fix), `Speaker volumes unlocked`
  and `ceiling -40 dB` at 1.887 s, Amp Gain 10, `apple,deferred-shutdown` present on all six codec nodes.
- **Tone (2 s, 1 kHz, -40 dBFS, six channels):** the stop-time faults are gone and `Speaker Switch` off is quiet. A burst
  of `bad TDM clock` remains at **stream start**: 5 faults (0038 x2, 003a x2, 0039, 003c, 003d) 150-270 ms after the daemon
  saw the stream open (152.907 s -> 153.152-153.171 s), none at the end (~154.9 s). B2 had 20 lines over stop and
  switch-off. GPIO 106 (shared amp IRQ) count 1032. Logs: `/boot/r1-logs/audio-b3-20261107/` (private).
- **Reboot after the tone: clean** (23 s to the next boot, PMU boot-error count 0, primary slot), so the B2 reboot stall
  did not reproduce on this kernel. systemd owns no runtime watchdog (`RuntimeWatchdogUSec=0`, reboot watchdog 10 min).
- **Then:** the next boot of the same payload had no network inside 90 s; `m5-selftest` restored the daily and rebooted
  (the loop guard's one revert). Its saved log shows the hub, dongle and the r8152 adapter all enumerated normally by 3.3 s
  and `enu1u2u2` configured and UP, but with **NO-CARRIER** for the whole 90 s: an Ethernet link flake on the adapter or the
  switch, not the kernel (the next boot on the daily had carrier at once). Not audio-related; the self-revert did its job.
- Next: 0003 for the start-time burst (agent), then B4.

### Result (RIGHTPORT plug test, 2026-11-07 10:50 UTC, on the WFI soak boot with the daily DTB; Rolando moved the hub)

The hub (Ethernet, 2.4 GHz dongle, card reader) moved from the left-front port to the right port with the machine running.
**Host mode works on the right port.** Type-C `port1` switched to data host / power source with VCONN on and a partner;
a new xHCI pair came up under `382280000.usb` (USB 3.1 Enhanced SuperSpeed), the hub enumerated at SuperSpeed Plus Gen 2x1
(10 Gb/s on both tiers), the dongle's keyboard and mouse registered, the r8152 Ethernet came back as `enu1u2u2` with the
same address and SSH resumed. So the m1n1 0018 USB-PD S0 setup covers hpm2 and the combo PHY tunables from the ADT
(m1n1 0021) are right for ATC2 too. Not tested on the right port: DisplayPort (dcpext0 and the xbar stay off), charging in.

### Result (WFI soak + SLEEP S1-S4, 2026-11-07 10:26-11:42 UTC, WFI-T1 kernel, Rolando at the machine for S4)

Kernel `7.3.0-gf080637018df` (series + `wfi-idle` 0001/0002: WFI override, PM_DEBUG), the daily's DTB, payload
`wfi-t1-20261107-040d4866.bin`, one boot, 76 minutes.
- **Soak (56 min, cut short on Rolando's call):** no RCU stall, Oops or SError (the only error line was the hub's first
  enumeration attempt during a live port move); all 18 cores pass a floating-point consistency run; CPU 0 had 409k WFI
  entries; idle on the charger 9.8 W total system power (the spinning daily: 16.4 W). **WFI idle is validated.**
- **Sleep, `dt-prep/s2idle/s2idle-step.sh` (copied to `/boot`, its `idle=nop` guard relaxed for the overriding kernel),
  WD2 guard off (unverified; Rolando present):**
  - S1 freezer: PASS, 5 s.
  - S2 `pm_test=devices`: PASS, 7 s; every device suspend/resume callback ran; USB (22 devices), Ethernet and trackpad back.
  - S3 `pm_test=platform` (late + noirq, power domains off): PASS, 7 s; same recovery.
  - S4 real s2idle, `echo mem > /sys/power/state`, wake on the power button: PASS. `Timekeeping suspended for 346.641
    seconds`; resume at 4211 s, `suspend_stats` success 4 / fail 0; USB, Ethernet (carrier back), battery 100 %.
  - After each of S2-S4 SSH over Tailscale took 2-6 minutes to return: the WireGuard path re-forms after the Ethernet
    adapter's suspend/resume; TCP 22 answered at once, the SSH handshake only completed later. Not a kernel symptom.
- Not measured yet: power while asleep (on battery, overnight), lid-close wake, repeated sleep cycles in one boot, sleep on
  the audio kernel, the USB-C right port across sleep (it was empty).
- Next: promote the WFI kernel to the daily (add `kvm-arm.wfi_trap_policy=trap` to BASE), then enable lid sleep in logind.

### Result (W0, 2026-11-07 11:44 UTC, self-revert loop + A/B stage-1, Rolando nearby)

Payload `w0-n1dt-20261107-24276a09.bin` (`contrib/pending/wireless/aurora-n1/prep/RUN-W0.md`): the daily's series kernel and DTB, m1n1 `n1-dt`
(the daily's m1n1 + 0022 N1 DT fill-in + the dart-pmp0 dapf line), the selftest initramfs carrying the FTAB (private), battery
on, `m5.selftest=1`, prev = the daily `275d84ec`. Root prepared first (`W0-ROOT-PREP.sh`: FTAB at
`/usr/lib/firmware/apple/centauri/j716s-ftab.bin`, digest matches the Studio copy; iwd, iw, wireless-regdb, bluez
installed, nothing enabled).

**PASS (port not trained, as expected).** Primary slot, network at ~60 s, `m5-selftest`: "network OK, keeping this
payload", no revert; `pcie-apple 1cb0000000.pcie: probe ... failed with error -22` (root port disabled, untrained); the
device tree's `pci@0,0` carries the five tunables lists (`apple,apcie-config-tunables`, `pcie-rc-tunables`, gen3/gen4/gen5
shadow tunables) that m1n1 0022 fills from the ADT. No `chosen/m5pro,n1` (W0 does not set it). No SError/Oops.
Not captured: m1n1's `n1: port 0: ... linksts ...` line (no `phram.ko` on the root for this kernel; the modules build will
provide it, or a panel video). Next: W1 (`RUN-W1.md`, attended: m1n1 trains apcie0 port 0 behind `chosen.m5pro,n1=1`).

### Result (W1, 2026-11-07 11:50 UTC, attended: Rolando at the machine)

Payload `w1-n1train-20261107-3c0a1eff.bin` (`contrib/pending/wireless/aurora-n1/prep/RUN-W1.md`): W0 plus m1n1 `n1-train` (0020-0023) and
`chosen.m5pro,n1=1`. **Boots, no revert, no NVMe disturbance; the training was refused by its own guard.** The stage-2 log
(read on the running system through `phram`: the kernel's reserved-memory `flash@...` nodes carry `compatible = "phram"`
with labels `m1n1_stage2.log` and `adt`, so `modprobe phram` with no parameters exposes them as `/dev/mtd0` and `/dev/mtd1`;
`phram.ko` is now installed on the root for the series kernel) says:

    n1: control function: firmware-name apple/centauri/j716s-ftab.bin, platform-id 0x000c6050
    n1: chosen.m5pro,n1=1: training apcie0 port 0
    pcie-t6050: STOP: ANS is not running (before)
    n1: port 0 training stopped; booting without the N1
    n1: port 0: rc ctl 0x0 stat 0x1, port status 0x6 linksts 0xc300220c ltssm 0x0
    n1: port 0 not up: root port and DART disabled

- **W0's open question is answered:** iBoot does not train port 0 (`ltssm 0x0`, `linksts` bit 0 = 0).
- **Why W1 stopped:** 0023 snapshots the ANS/storage state before touching the shared GP PHY and refuses when the ANS is not
  running. In our chain (A/B stage-1 chainloads `boot.bin` from the ESP, then stage-2 runs kboot) the ANS is stopped at
  that point; Linux's nvme-apple starts it itself. So the guard can never pass as designed on this chain.
- The kernel therefore saw the port disabled (`pcie-apple ... -22`), the `pci@0,0` node and its tunables removed by m1n1,
  network up, selftest "network OK"; ESP restored to the daily afterwards.
- Next: an m1n1 change (`n1-wifi/w2/`): start the ANS in stage-2 for the training window, or train without the snapshot
  when the ANS is down, or train in stage-1; agent analysis in progress.

### Result (R3-AUDIO-B4, 2026-11-07 12:00 UTC, self-revert loop + A/B stage-1, nobody at the machine)

Payload `audio-b4-20261107-d2f29654.bin`: kernel `7.3.0-g7767a8193740` (`audio/tdm` 0001-0003: 0003 waits for the speaker
service to report `pwrd` before the unmute and logs the state at stream end), the deferred-shutdown spk DTB, battery on,
`speaker_max_db=-40`, `m5.selftest=1`, prev = the WFI daily `dcec81ed`. Script `b4-run.sh` (interrupt and unhandled counts
per tone, pin state, three tones, one with the daemon stopped, switch-off, amp registers).

**Boots and is safe; the fault is continuous during playback, not an edge.** Gates pass as on B3. Idle 10 s without a
stream: amp IRQ (GPIO 106, level, idle high) count +0, unhandled +0, so the line is not stuck and there is no storm at
rest. Each 2 s tone: `spkr: pwrd reached after 0 ms (1 reads)` (the service is already running because speakersafetyd
holds the sense stream), the first `bad TDM clock` 35 ms later, then 590-722 "callbacks suppressed" and +635..+641
interrupts per tone with unhandled +0: about 320 real latches per second on all six amps for the whole stream, the same
with speakersafetyd stopped (volumes locked, silent), none after `Speaker Switch` off. No `firmware stopped it` line.
- Reading: the TDM clock/frame the AOP serializer drives for the J716s six-channel stream does not match what the amps are
  programmed to expect (bit-clock ratio, FSYNC rate, slot width or count), so 0002/0003's ordering fixes were aimed at the
  wrong thing; they stay (they cost nothing and removed the switch-off burst). The J716s has six amps (three per I2C bus)
  against the J714c's four; the J716 macaudio entry reuses the J714 front-end names and serializer configuration.
- Logs: `/boot/r1-logs/audio-b4-20261107/` (private). Next: 0004 after the geometry comparison (agent); a 2- or 4-channel
  stream as a discriminator.

### Result (LID sleep, 2026-11-07 12:20 UTC, WFI daily, Rolando at the machine)

Root changes: `/etc/systemd/logind.conf.d/20-m5pro-lid-sleep.conf` (HandleLidSwitch=suspend, ExternalPower=suspend,
Docked=ignore), `/etc/systemd/sleep.conf.d/20-m5pro-s2idle.conf` (AllowSuspend=yes, hibernation off, SuspendState=mem),
`/etc/udev/rules.d/97-m5pro-xhci-wakeup.rules` (xhci wakeup enabled, as the S-tests did by hand); `suspend.target`,
`sleep.target` and `systemd-suspend.service` unmasked (hibernate units stay masked: this kernel has CONFIG_HIBERNATION=y).
- First lid close: logind saw it ("Lid closed. Suspending...") and the still-masked `suspend.target` refused it. Lesson:
  the bring-up's safety mask lived in two places (the sleep.conf drop-in and the unit mask).
- Second lid close: suspend entered (`PM: suspend entry` 70 ms after "Lid closed."), and 230 ms later the SMC emitted
  `SMC HID Event: 03 00 01` (the "lid opened" code) while the lid stayed closed, at the same instant as the MTP's "Sending
  Cumulus Report to enter Dependent Mode"; macsmc-input is a wakeup source, so the suspend ended after 0.74 s
  (`suspend_stats` success 1 / fail 0). Opening the lid 20 s later produced no further event. With the lid test earlier,
  with no suspend configured, 03 01 00 / 03 00 01 tracked close / open faithfully.
- So: lid close triggers sleep correctly, the wake path works, but a spurious lid-open event aborts it. Under analysis
  (`~/Work/agents/lid-sleep/`); the power button and the command path (`systemctl suspend`) are unaffected.
- The udev `power-switch` tag and ID_INPUT_SWITCH are correct; the device is `Apple SMC power/lid events` (event0).

### Result (W2, 2026-11-07 12:26 UTC, attended: Rolando at the machine)

Payload `w2-n1ans-20261107-2dedddda.bin` (`wireless/aurora-n1/w2/RUN-W2.md`): W1 plus m1n1 0025 (`n1=3`: start the ANS for
the training window, read-verify a block, stop it again). Stage-2 log:

    n1: chosen.m5pro,n1=3: training apcie0 port 0 with ANS started
    pcie-t6050: ANS stopped (0x0): starting it
    nvme: initialized at 0x45dcc0000
    pcie-t6050: NVMe block 1 read (GPT header)
    pcie-t6050: storage before: reference
    pcie-t6050: storage after A: unchanged
    pcie-t6050: storage after S: unchanged
    pcie-t6050: STOP: link up: 0x410028208 = 0xab001208 after 500 ms
    pcie-t6050: storage after training: 0x419600048 0x0000006e -> 0x0000006d  (allowed)
    pcie-t6050: storage after training: NVMe read identical
    nvme: shutdown done / ANS stopped again for Linux
    n1: port 0: rc ctl 0x1 stat 0x1, port status 0xd linksts 0xab001208 ltssm 0x1

- **Firsts:** m1n1 started a stopped T6050 ANS itself (10 s RTKit wait), read NVMe, trained with the storage snapshot
  as designed, and handed Linux an ANS in today's state: Linux booted normally (NVMe "boot: mode normal"), root mounted,
  network up, no revert, PMU count 0.
- **Training:** PMGR/PHY stages A and S ran with storage unchanged; the link never came up within 500 ms (`ltssm 0x1`,
  root port status 0xd). Per the plan this is the "N1 still in SMC reset" case: next W2b (`n1=4`, adds the SMC `gP13`
  release before training), then the J813-style reset pulse and timings if that still stops.
- Storage register 0x419600048 changed 0x6e -> 0x6d across the training and was classified allowed (the agent's
  whitelist); the block read-back was identical.

### Result (W2b, 2026-11-07 12:32 UTC, attended)

Payload `w2b-n1ans-20261107-d9009a03.bin` (`n1=4`: W2 plus 0023's SMC reset release before the training). The ANS start,
GPT read, snapshot and clean stop all repeated as on W2 (W2 itself was re-run once by a deploy mishap and reproduced
byte for byte). The training stopped before any link attempt:

    pcie-t6050: STOP: /arm-io/apcie0/pci-bridge0 function-reset is not an SMC pKW4

0023's reset-release path expects the bridge's `function-reset` ADT property to name an SMC `pKW4` function; the J716s
describes it differently. Port state afterwards back to idle (`status 0x6`, `ltssm 0x0`). Linux booted normally, NVMe
fine, no revert, PMU count 0. The storage register 0x419600048 moved 0x6e -> 0x6c (W2: -> 0x6d), classified allowed;
block read identical. Next (agent): decode the J716s `function-reset` descriptor and implement the right release
(SMC key or GPIO) with the J813-style pulse and timings, then W2c.

### Result (R3-AUDIO-B5, 2026-11-07 12:35 UTC, self-revert loop + A/B stage-1, nobody at the machine)

Payload `audio-b5-20261107-14da9666.bin`: kernel `7.3.0-ge5a4712a3f0d` (`audio/aurora/tdm` 0001-0004; 0004 gives the J716
speaker link the J616s format: normal bit clock, inverted frame clock, 250-bit frame, as the J716s ADT's speaker serializer
describes), the deferred-shutdown spk DTB, battery on, `speaker_max_db=-40`, `m5.selftest=1`, prev = the WFI daily.

**The TDM clock fault is gone.** Gates as before. Idle: amp IRQ +0. Three 2 s six-channel tones at -40 dBFS, then one
with speakersafetyd stopped, then `Speaker Switch` off: **0 `bad TDM clock` lines**, amp IRQ deltas +11 / +20 / +15 / +13
per tone (B4: +635..+641), speakersafetyd up throughout, `pwrd reached after 0 ms`. Amp registers after the run (page 0,
all six): `0x08=0x08 0x09=0x02 0x0a=0x1a 0x0d=0x13` (the new edge: TDM_CFG1 0x02, TDM_CFG4 bit 0 set), playback slots
`0x0c` = 0x00/0x22/0x44 on i2c0 and 0x11/0x33/0x55 on i2c2, latches `0x49=0x00 0x4a=0x02 0x4b=0x00`, `0x5c=0x19`.
- Not yet: anything audible (-40 dBFS under a -40 dB ceiling), the left/right V/I sense scaling check, the protective
  PipeWire graph, the meaning of the residual interrupts and latch 0x4a bit 1 (agent).
- Next: B6 with `speaker_max_db=-30` and a -10 dBFS tone (about -40 dB out, quiet but audible) with Rolando listening.

### Result (GPU E0 readback, 2026-11-07 12:41 UTC, on the WFI daily, read-only MMIO through /dev/mem)

`contrib/pending/gpu/e0/e0-readback.sh` (dry-run validated first; 14 32-bit reads, all inside ADT device windows, none in
System RAM). Stage 1: PMGR PS PMP (gate 27) `0x0f0000ff`, PMS_SRAM (gate 28) `0x0f0000ff` (both on). Stage 1b: the PMP SRAM
cold-marker words at 0x28457bcc0..bcdc are all zero, including +0x7bcd8 where the t6050/pmp driver expects `0xfeed1b00`:
**the SRAM is not in the "cold" state that driver assumes**, so a host-side PMP start would take a different path on this
boot chain (iBoot loads the PMP; our m1n1 does not start it). Stage 1c (PMGR group 3): GPX `0x1f0003ff` (on, auto), AFR
`0x0f040300` (off), CS `0x0f000300` (off), GFX `0x0f040300` = exactly the analysis's expectation (off, auto-off, parents
AFR+GPX). **Verdict: GO E1 with the caveat "PMP SRAM NOT-COLD"**; E1 (the ID-register read and the clean "M5 Pro not yet
available" refusal) does not touch the PMP. Logs `/boot/r1-logs/e0-20261107T124129Z/`.

### Result (W2c, 2026-11-07 12:56 UTC, loop + A/B stage-1; Rolando away): **the N1 is on the bus**

Payload `w2c-n1smc-20261107-d8bab230.bin` (`n1=4` with m1n1 0026: the `function-reset` lookup fixed, the J813-style SMC
`gP13` reset pulse, 1 s link wait). Stage-2 log:

    pcie-t6050: SMC key gP13 <- 0x00800000: 0
    pcie-t6050: SMC key gP13 <- 0x00800001: 0
    pcie-t6050: port 0 link Gen1 x1
    pcie-t6050: endpoint 01:00.0 is 0x1900106b
    pcie-t6050: storage after F: 0x419600048 0x6e -> 0x6d (allowed)
    pcie-t6050: port 0 up, N1 at 01:00.0
    pcie-t6050: storage after training: NVMe read identical / nvme: shutdown done / ANS stopped again for Linux
    n1: port 0 up: root port and DART okay          (linksts 0x9b001001, ltssm 0x1)

Kernel: `pcie-apple 1cb0000000.pcie: port 0: RID 0100 -> SID 1, slot 1`, `adopted port 0, endpoint 01:00`, ECAM, `pci
0000:01:00.0: [106b:1900] ... PCIe Endpoint` (BAR 0 64 KiB, BAR 4 32 MiB assigned, 2.5 GT/s x1 link), `Adding to iommu
group 1`, `apple_centauri 0000:01:00.0: enabling device`, then **`N1 automatic startup failed in phase0: -5`**. Root
mounted, network up, battery 96 %, SMC fine after m1n1's key writes, no revert, PMU count 0.
- `phase0: -5` is the predicted "ROM rejected the FTAB" case (`wireless/aurora-n1/ANALYSIS.md` 2.3): our `ftab.bin` has no
  ticket; the matching `centauri.j716sap*.im4m` manifests sit next to it in the macOS Preboot restore bundle. Next: W3 =
  the same loader with a personalised FTAB (Studio-only work; the file stays private).
- The W2b stop was a bug in 0023 (`adt_getprop_copy()` returns the copied length, the check compared it with 0), not a
  different descriptor: the J716s `function-reset` is `pKW4` key `gP13` template 0x00800000, as on the J813.
- First warm boot only; RUN-W2.md asks for a full power-off before a run, which an unattended run cannot do.

### Result (DAILY-NEXT-T1, 2026-11-07 13:00 UTC, loop + A/B stage-1, nobody at the machine): **did not boot**

Payload `daily-next-t1-20261107-01ece59a.bin`: kernel `7.3.0-g80bbf87ea430` (`j716s-series` + 0063 MTP haptic built in +
0064 netfilter/nftables, policy routing, WireGuard, bridge/veth/overlay/fuse, all `=y`; `~/Work/agents/daily-next/`),
the series DTB (same as the daily's), battery on, selftest on, prev = the WFI daily `dcec81ed`.
The machine came back on `boot.bin.prev` with `boot-slot = fallback-after-failure`: the new kernel never fed the 150 s
stage-1 watchdog, so it hung or panicked before `apple_wdt` probed (or never started). No console capture exists for that
boot (no pstore backend, the stage-2 phram log is overwritten by the next boot), so the cause is unknown. **The A/B
stage-1 recovered it unattended, as designed.** ESP restored to the daily. Next: bisect with two payloads (haptic only,
netfilter only) and, when Rolando is at the machine, a panel video of the failing boot.

### Result (W3, 2026-11-07 13:40 UTC, cold start by Rolando): **did not stay up**

Payload `w3-n1ftab-20261107-33add271.bin` = W2c with the initramfs carrying the FTAB stitched with the board's Image4
manifest (`wireless/aurora-n1/w3/`); the same file installed on the root (`j716s-ftab.bin`, W0 copy kept as `.w0`).
Full power-off, power button pressed by Rolando. The machine came up on `boot.bin.prev` (the WFI daily) with
`boot-slot = fallback-after-failure`, PMU count 1: the W3 boot stopped feeding the 150 s stage-1 watchdog and reset.
No console capture. Since W2c booted twice with the only difference being the unsigned firmware (which the ROM refused),
the likeliest reading is that the ROM accepted the stitched image, the N1 firmware ran, and the machine froze afterwards:
the J714c showed exactly that (a freeze 20-40 s after boot) until ASPM was stripped on the adopted port. Next: W3b = the
same payload with `pcie_aspm=off`, filmed; then the kernel print of image_response/stage (edimoldovan 50519853a58d) if
it still fails. ESP restored to the daily; root firmware left as W3 (rollback: the `.w0` file).

### Result (W3b, 2026-11-07 13:44 UTC, cold start by Rolando): **Wi-Fi and Bluetooth come up**

Payload `w3b-aspmoff-20261107-009a839e.bin` (built with mk-daily from the W2c ingredients: series kernel
`7.3.0-g4f630b11270d`, stack DTB, m1n1 `n1-smc` with `chosen.m5pro,n1=4`, the W3 initramfs carrying the FTAB with the board's
Image4 manifest stitched in, `pcie_aspm=off`, battery on, selftest on), prev = the WFI daily. Full power-off, button.
- m1n1 as W2c: SMC gP13 pulse, `port 0 link Gen1 x1`, `endpoint 01:00.0 is 0x1900106b`, `port 0 up, N1 at 01:00.0`.
- Kernel: `adopted port 0`, `[106b:1900]`, `apple_centauri: enabling device`, **no phase0 line** (the ROM accepted the
  image), `port 0: link retrained after a root-port reset` at 0.43 s, `[106b:1902]` and `[106b:1903]` on functions 1 and 2
  (RID 0101 -> SID 2, 0102 -> SID 3), `Wi-Fi firmware channel list: 709 bytes, capabilities: 570 bytes`, `Wi-Fi firmware
  channels: 2.4 GHz 13, 5 GHz 25, 6 GHz 0 (38 entries)` at 3.37 s; **`wlan0`** (phy0, managed) and **`hci0`** (Bluetooth,
  version 17, manufacturer 76) registered, rfkill clear; primary slot, no revert, PMU count 0, battery 94 %.
- Up past 123 s with ASPM off (W3 froze inside that window with ASPM on), so the J714c's ASPM finding holds here too.
- Userspace: `W1-POST-ROOT.sh` (iwd, bluetooth for this boot), scan: see the next lines. Association with a passphrase is
  Rolando's. Still open: warm reboot with the N1 link alive (the J714c needed a pcie-apple shutdown park), the ASPM strip
  on the adopted port as a kernel patch instead of `pcie_aspm=off`, the WFI daily kernel with this stack, 6 GHz (0 entries
  in this regulatory list), Bluetooth pairing.
- **Radio check on the same boot (W3b, up 268 s):** `ip link set wlan0 up; iw dev wlan0 scan`: 55 BSS entries, 33 SSIDs,
  2.4 GHz and 5 GHz (2412, 5720, 5785 MHz among the most seen), signals down to -30 dBm; `btmgmt find` for 8 s: 36 devices.
  `iwd` fails to start: the kernel lacks `CRYPTO_USER_API_HASH`, `CRYPTO_USER_API_SKCIPHER`, `KEY_DH_OPERATIONS`,
  `CRYPTO_ARC4` (`CRYPTO_USER_API=m` with no module installed). Config 0065 adds them; association is next.

### Result (DAILY-NEXT bisect A and B, 2026-11-07 13:51-13:57 UTC, loop, nobody at the machine)

- **A** `bisect-A-20261107-eb8916fb.bin`: series tip + 0063 (MTP haptic built in), kernel `7.3.0-g595c6158020f`: **boots**
  (primary, 18 CPUs, network, no revert; nft works; `ip rule` unsupported as expected; two `haptic` dmesg lines).
- **B** `bisect-B-20261107-907eab2b.bin`: series tip + 0064 (netfilter, policy routing, WireGuard, bridge/veth/overlay/
  fuse), kernel `7.3.0-g445b2338a033`: **boots** (nft ok, `ip rule` lists the local table).
- So the full kernel's failure (DAILY-NEXT-T1) is either the combination, a size effect, or a one-off. Next: re-run the
  full kernel once (and kernel D = 0064 + 0065 iwd crypto), with the crash-log capture in place if it is ready.

### Result (DAILY-WIFI-T1, 2026-11-07 14:00 UTC, loop, nobody at the machine): **associated, DHCP lease, traffic**

Payload `daily-wifi-t1-20261107-5e188412.bin` (WFI kernel `7.3.0-gf080637018df`, stack DTB, m1n1 `n1-smc` with
`chosen.m5pro,n1=4`, the stitched-FTAB initramfs, `pcie_aspm=off`, battery, selftest on), warm reboot from the daily.
N1 trained and adopted as on W3b, `Wi-Fi firmware channels` at 3.4 s, `wlan0` and `hci0` present; primary slot, no revert.
Userspace: `wpa_supplicant` from the Arch Linux ARM repos (iwd needs kernel crypto this kernel lacks), config written
with `wpa_passphrase` (file 0600 on the root; the passphrase is nowhere else), `wpa_supplicant@wlan0` enabled, a
systemd-networkd `.network` for wlan0 with DHCP and route metric 2048 (Ethernet stays preferred while plugged).
- `wpa_state=COMPLETED`, WPA2-PSK, 5 GHz (5200 MHz), signal -30 dBm; DHCPv4 lease and gateway from the home router;
  `ping -I wlan0 1.1.1.1`: 3/3, 17 ms average. Bluetooth controller up (not paired yet).
- Next: this stack becomes the daily (self-test flag off); a reboot from a live Wi-Fi link (the J714c needed a pcie-apple
  shutdown park); throughput; iwd once kernel crypto 0065 is in; the ASPM strip as a patch instead of `pcie_aspm=off`.

### Result (DAILY-WIFI promotion attempt, 2026-11-07 14:04 UTC): **restart with the N1 link alive does not come back**

`daily-20261107-915de615.bin` (the DAILY-WIFI-T1 ingredients without the self-test flag) was installed and the machine
rebooted FROM the DAILY-WIFI-T1 boot (N1 trained, wlan0 associated earlier, `wpa_state=SCANNING` at that moment). It came
back on `boot.bin.prev` (the WFI daily) as `fallback-after-failure`, PMU count 1. The same ingredients had booted from a
non-N1 boot minutes earlier, so the variable is the warm, already-trained N1/port at loader time: the J714c's "a restart
with the link alive never reached m1n1" (fixed there with a pcie-apple shutdown that parks the adopted port). The Wi-Fi
stack therefore stays a test payload; the daily remains `dcec81ed`. Work item `wireless/aurora-n1/w4`: loader branch for
an already-trained port and a kernel shutdown that parks it.

### Result (LID-SLEEP kernel, 2026-11-07 14:11 UTC, Rolando at the machine): **lid close sleeps, lid open wakes**

Payload `lid-sleep-20261107-d332cf88.bin`: kernel `7.3.0-g82a7d71d217e` (series tip + `platform/lid-sleep` patch 0001:
macsmc-input confirms a lid-open report during suspend against the SMC `MSLD` key and ignores one in the first
`lid_wake_settle_ms` = 2000 ms), stack DTB, battery, selftest on, prev = the daily. Lid closed 30 s by Rolando:
`Lid closed.` -> `Suspending...` -> `PM: suspend entry` -> `suspend-to-idle` -> **`Timekeeping suspended for 39.477
seconds`** -> SMC `03 00 01` -> `macsmc-input: lid open 72030001 at +40069 ms in sleep, MSLD=0: wakeup` -> resume ->
`Lid opened.`; `suspend_stats` 1/0, Ethernet and USB back. No spurious early event appeared in this run (the earlier
0.7 s abort may have been timing-dependent); the patch's confirm path accepted the real opening. Promote the kernel
(it is the series tip + this patch) to the daily; the patch becomes series 0066.

### Result (R3-AUDIO-B6, 2026-11-07 14:20 UTC, Rolando listening): **the speakers play, clean**

Payload `audio-b6-20261107-6478b765.bin` = B5's kernel (`7.3.0-ge5a4712a3f0d`, tdm 0001-0004) and defer DTB with
`snd_soc_macaudio.speaker_max_db=-30`; speakersafetyd run with `-v` through a drop-in for the session; Mux Secondary,
Switch on; 1 kHz, six channels, 2 s each through `plughw:AppleJ716,1`, raw device (no DSP graph).
| level | amp IRQ delta | faults | daemon peak power |
|---|---|---|---|
| -30 dBFS | +18 | 0 | 0.00 W |
| -20 | +14 | 0 | 0.00 W |
| -12 | +20 | 0 | 0.00 W |
| -6 | +21 | 0 | 0.01 W |
| 0 dBFS | +15 | 0 | 0.04 W |
| left only / right only, -12 dBFS, 3 s | +13 / +14 | 0 | 0.00 W |
Rolando: "I heard the 1 kHz tone, sounded good, no distortion." speakersafetyd stayed up, no limiting, no warnings.
The daemon's modelled coil temperatures sit at 52-71 C at rest (woofers 71 C, tweeters 58 C before the tones, falling
to 63 / 52 C after), which looks like an ambient/scale offset in the J716 profile: it errs in the safe direction and is a
follow-up for the sense scaling pass (left vs right power at a longer tone).
Next: the PipeWire profile for the desktop user, the sense-scaling check, then the audio kernel candidate as the daily
once the N1 restart issue is solved (the daily must carry both stacks).
- **Desktop path (same boot, 14:31 UTC):** user `rolo` in group `audio`, linger on, PipeWire/WirePlumber enabled; the
  current `99-asahi-j716.conf` fragment (RawSpeakers rename with AUX0-5 positions, software DSP on, the J716 graph) replaces
  the UCM sink with `audio_effect.j716-bringup` (default) and exposes the mic graph as a source. `pw-play` of a 4 s 440 Hz
  -12 dBFS stereo file at sink volume 1.0: the speaker PCM ran at S24_LE 48 kHz 6 ch (MMAP), `spkr: pwrd reached`, amp IRQ
  +16, 0 faults, daemon fine. An earlier silence through PipeWire came from an old copy of the fragment on the root (UCM
  sink only, software DSP off). speakersafetyd's 71/58 C idle coil readings are its deliberate warm-start assumption
  (99 C cold, 120 C warm, decaying to t_ambient 50 C), not a profile bug.

