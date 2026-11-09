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

### Result (LID daily promotion + bisect C and D, 2026-11-07 14:40-14:52 UTC, loop, nobody at the machine)

- **Daily promoted:** `daily-20261107-534ca146.bin` = kernel `7.3.0-g82a7d71d217e` (series tip + 0066 lid-open confirm),
  stack DTB, battery, `kvm-arm.wfi_trap_policy=trap`, no self-test flag: primary slot, 18 CPUs, network,
  `lid_wake_settle_ms` 2000. Previous daily `dcec81ed` retired from `boot.bin.prev`.
- **C** (`7.3.0-ga2518bd52a46`, series tip + 0065 kernel crypto): boots; nft ok; `ip rule` unsupported (expected);
  `CRYPTO_USER_API_HASH=y`; **iwd starts** (`active`).
- **D** (`7.3.0-g91812cddaf1c`, + 0064 netfilter/routing/WireGuard): boots; `ip rule` lists the local table; iwd active.
- full2 (+ 0063 haptic) running next; if it boots, the one earlier failure of the combined kernel stays unexplained
  (no capture) and the crash-log work decides whether to trust it.
- **full2** (`7.3.0-g24e777afc7f6`, + 0063 haptic + 0064 + 0065, same tree as the earlier failed "full"): **boots**
  (169 s to ssh, primary slot, 18 CPUs, no revert); nft ok, `ip rule` ok, two haptic input devices, iwd active.
  The earlier failure of the combined kernel did not reproduce; it stays unexplained until the crash-log capture
  (ramoops + netconsole) is in place. 0063/0064/0065 are not in the daily yet.
- Afterwards the lid daily `534ca146` was restored as `boot.bin` (verified by hash) and the previous WFI daily
  `dcec81ed` put back as `boot.bin.prev`, so the fallback is a different kernel than the primary.
- Desktop: `hypridle.conf` now locks after 10 min idle (`loginctl lock-session`); it takes effect at the next
  Hyprland login (hypridle is started by `hyprland.lua`).

### Result (CRASHLOG-T0..T3, 2026-11-07 15:16-15:36 UTC, loop, nobody at the machine)

Kernel `7.3.0-crashlog-gf080637018df` (WFI kernel + PSTORE_RAM/CONSOLE/PMSG, NETCONSOLE, PANIC_TIMEOUT 10), payloads in
`~/Work/agents/crashlog/payloads/`, lid daily `534ca146` as `boot.bin.prev` throughout.
- **T1 (ramoops node, mem-type 1 uncached): did not boot.** Stage-1 fell back to the lid daily (`fallback-after-failure`).
- **TK (same kernel, the daily's DTB, no ramoops node): boots** (primary, 18 CPUs, network). So the node, not the kernel.
- **TM2 (node, mem-type 2 cached): boots**, `Registered ramoops as persistent store backend`, `/dev/pmsg0` present.
  Retention probe (pmsg + kmsg marker, then `systemctl reboot`): **store empty** on the next boot.
- **TM0 (node, mem-type 0 write-combined): boots and registers; retention probe: store empty** as well.
- Conclusion: ordinary DRAM at DRAM base + 8 GiB is not preserved across a warm reset on this machine; the route is the
  region iBoot preserves for XNU's panic log (m1n1 fills the ramoops node from the ADT), agent running.
- netconsole: the MacBook's USB Ethernet sits on a separate 192.168.10 network that does not forward UDP to the Studio's
  LAN, so the units are installed with no target (they exit cleanly); pstore is the path. Attended option: move the
  adapter onto the Studio's LAN.
- Root-side: `m5-pstore-collect.service` (sysinit) and `m5-netconsole.service` installed and enabled on the root.

### Result (W4: restart with the N1 trained and in use, 2026-11-07 15:37-15:46 UTC, loop, nobody at the machine)

Payload `w4-n1warm-20261107-a9911c95` (m1n1 0020-0023/0025/0026/**0027** warm-N1 entry; kernel `7.3.0-gff289b9ce8ec` =
WFI kernel + pcie-apple adopted-port park/ASPM strip + centauri leave-alone, both edimoldovan's; W3b DTB and stitched-FTAB
initramfs; `n1=4`, `pcie_aspm=off`, self-test on, battery on). `boot.bin.prev` = lid daily `534ca146`.
- First boot: primary, N1 at 01:00.0/.1/.2 (`106b:1900/1902/1903`), port 0 adopted, `link retrained after a root-port
  reset`, wlan0 associated (WPA2 5 GHz) by wpa_supplicant without help.
- **Three `systemctl reboot` cycles with wlan0 associated and a ping running: all three back on the primary slot, N1
  adopted, wlan0 associated. PASS** (the DAILY-WIFI promotion failure of 14:04 UTC does not reproduce with W4).
- The restore reboot from W4 into the lid daily (whose m1n1 has no N1 code) came back `fallback-after-failure`: a loader
  without 0027 hangs once on the warm N1, then the stage-1 fallback boots prev (the same lid daily). So the N1-aware m1n1
  goes into every payload from here on, and the next daily is W4 + the lid patch (building).
- Module set for the lid daily kernel `82a7d71d217e` installed on the root (171 modules, phram included).

### Result (CRASHLOG-PRAM, 2026-11-07 15:48-15:58 UTC, loop, nobody at the machine)

m1n1 0028 (ramoops node carved from iBoot's `/pram` panic-log region, header page skipped, mem-type 0) + crash-log
kernel + daily DTB: payload `crashlog-pram-20261107-de06f732`, daily twin `daily-20261107-c317334d` as prev for the panic.
- Boots on the primary slot; `reserved-memory/ramoops@10bd98dc000` (1552 KiB) present, ramoops registered, `/dev/pmsg0`.
- Warm `systemctl reboot` with pmsg + kmsg probes written: **store empty** on the next boot.
- Deliberate panic (`sysrq c`, PANIC_TIMEOUT 10): the machine came back on the daily twin as `fallback-after-failure`
  (so the panic and the restart happened), and the store was **empty** there too.
- Conclusion: iBoot consumes and clears `/pram` on every boot (XNU's own panic log is extracted by iBoot), and the ECC
  DRAM is zeroed; no RAM region we can name survives a reset for Linux. RAM-backed pstore is **not viable** on the J716s
  without NVRAM access or an iBoot-side path. Evidence for a frozen boot has to come from outside the machine:
  netconsole with the USB Ethernet adapter on the Studio's LAN (attended re-plug; pre-panic lines, and panic lines too
  with an AX88179-class adapter), plus `initcall_debug` on hunt payloads. The kernel config pieces stay in the series
  (harmless); the DT node and m1n1 0028 stay in contrib/pending/crashlog for the record.

### Result (DAILY-WIFI-LID promotion, 2026-11-07 16:03-16:08 UTC, Rolando watching the panel)

- Test twin `w4t-lidwifi-20261107-350fd22a` (W4 stack + 0066 lid confirm, kernel `7.3.0-gb61f760243c4`): its first boot
  (unattended, 15:59) fell back to the lid daily; the second boot, watched from the panel, came up with no hang or odd
  line: primary, 18 CPUs, N1 adopted, wlan0 associated, hci0, `lid_wake_settle_ms` 2000. The first-boot failure is
  unexplained (the same one-off pattern as DAILY-NEXT "full" and the crash-log T1 payload).
- **Daily promoted: `daily-wifi-lid-20261107-bd9ebd5e.bin`** (same ingredients, no self-test flag): primary, Wi-Fi,
  Bluetooth, lid settle, battery driver, no reboot issues on the panel. `boot.bin.prev` = the test twin (it carries the
  N1-aware m1n1, which every rollback now needs). Modules for `b61f760243c4` (phram included) on the root.
- The lid daily `534ca146` is retired from the ESP rotation (copies on the Studio).

### Result (LID sleep on the Wi-Fi daily, 2026-11-07 16:09-16:11 UTC, Rolando at the machine)

Three lid closes of 30 s on `daily-wifi-lid bd9ebd5e` (kernel b61f760243c4, N1 adopted, wlan0 associated): logind
starts the suspend each time and it **aborts in 0.8 s**: `apple_pcie_suspend_noirq returns -16`, `PM: noirq suspend of
devices failed` (suspend_stats fail 5, success 0; last_failed_dev 1cb0000000.pcie, step suspend_noirq). The lid patch
never came into play; the SMC HID event `03 01 00` (close) arrives, logind suspends, pcie-apple refuses with -EBUSY
because the adopted N1 port is up. The previous daily (no PCIe at all) slept fine. New blocker: **s2idle with the
adopted N1 port**: a pcie-apple suspend/resume path for adopted ports (agent). Until then the Wi-Fi daily does not
sleep on lid close (it stays awake); the lid daily 534ca146 sleeps but has no Wi-Fi.

### Result (NEXT-DAILY, 2026-11-07 16:14-16:21 UTC, Rolando watching the panel)

Test payload `next-daily-wifi-20261107-7e285d94` (series 3f2bdbc61510, 86 patches; N1-aware m1n1; W4 chosen lines;
stitched-FTAB initramfs): boots clean on the panel, primary, 18 CPUs, N1 adopted (3 functions), wlan0 associated,
hci0, lid settle 2000, two MTP haptic devices (Rolando: trackpad clicks give feedback), nft ok, netconsole configfs
present and configured, `AppleJ716` speaker card + `AppleJ716AOP` mic card, -30 dB ceiling, speakersafetyd active,
PipeWire J716 sink and mic. 2 s 1 kHz tone at -20 dBFS through the sink: `spkr: pwrd reached`, 0 faults.
**Daily promoted: `daily-wifi-20261107-78b12875.bin`** (its no-self-test twin): primary, all of the above; `boot.bin.prev`
= the test twin 7e285d94. Known gap carried over: lid-close sleep aborts (N1 port suspend_noirq -EBUSY), fix in progress.
netconsole: the UniFi gateway now forwards UDP 6666 to the Proxmox receiver (iptables, not persistent), but the gateway
sits behind an ISP modem (double NAT), so nothing arrives until that modem forwards the port too.

### Result (m1n1 #65 v2 cold boot of the exact aurora-wip tree, 2026-11-07 ~16:25 UTC, Rolando at the panel)

Payload `m1n1-65v2-n1-20261107-22f89156` (aurora-wip b6b4592 + the four PR commits, W3b kernel/DTB/initramfs,
`chosen.asahi,t6050-n1=4`), started from full power-off. Panel: the Aurora logo, then `FDT: CPU 6..17 is not alive,
disabling` (aurora-wip brings up one cluster), `n1: chosen.asahi,t6050-n1=4: training apcie0 port 0 with ANS started
after the SMC reset release`, `pcie-t6050: ANS stopped (0x0): starting it`, **`nvme: invalid split BAR geometry`**,
`pcie-t6050: STOP: nvme_init failed, ANS stopped as before: not training`, `n1: port 0 training stopped; booting
without the N1`, `n1: port 0 not up: root port and DART disabled`, then `Failed to prepare FDT!` (`too many
/arm-io/i2c devices`, no GPU/display/sep/pmp/nvram handling) and `No valid payload found` -> `Running proxy...`.
- The N1 code behaved as designed (safe STOP, port left disabled), but the training itself was not exercised because
  aurora-wip has no T6050 bring-up (CPU clusters, NVMe split BAR, ADT quirks). Those live in our m1n1 0010-0021 and are
  a separate series for Aurora.
- The Aurora m1n1 disables the stage-1 watchdog at start, so the machine sat in the proxy and a power-button restart
  booted the same slot again (the PMU boot-error count does not cover a boot that stops in the proxy). Recovery: macOS
  over Tailscale, mount the ESP (`diskutil mount disk0s4`, `/Volumes/OMARCHY 1`), rewrite `boot.bin`/`boot.bin.prev`,
  `shutdown -r now`. Rule: never put a loader without our watchdog behaviour on the boot slot unattended.

### Result (N1-SLEEP, 2026-11-07 16:38-16:43 UTC, Rolando at the machine)

Test payload `w4t-n1sleep-20261107-84957e95` (kernel `7.3.0-g85c770faad4b` = Wi-Fi+lid kernel + pcie-apple "keep
the adopted link up through suspend-to-idle"): boots primary, N1 adopted, wlan0, hci0. Two lid-close sleeps (the third
close did not start a suspend): `PM: suspend entry (s2idle)` -> `macsmc-input: lid open 72030001 at +41746 ms in
sleep, MSLD=0: wakeup` / `+46683 ms` -> `pcie-apple 1cb0000000.pcie: port 0: adopted link kept through suspend-to-idle`
-> `PM: suspend exit`; suspend_stats success 2 / fail 0; wlan0 associated after resume; hci0 present. **PASS.**
Root cause of the regression: `apple_pcie_suspend_noirq()` returned -EBUSY unconditionally for any adopted-link host
(Aurora's adoption commit). Fix = patch `contrib/pending/wireless/patches/linux/0003-PCI-apple-T6050-adopted-ports-keep-the-link-up-throu.patch`.

### Result (DAILY 0087, 2026-11-07 16:55-17:01 UTC, loop, nobody at the machine)

Series tip `a0f2f30c967b` (87 patches = everything validated today: WFI idle, battery, SMC sensors, right port, lid
confirm, haptic, netfilter/WireGuard, iwd crypto, AOP audio + J616s TDM format, netconsole config, W4 park patches,
adopted-link s2idle fix 0087), N1-aware m1n1, W4 chosen lines, stitched-FTAB initramfs.
- Test twin `next-daily-wifi-20261107-ee3d0dd8`: primary, 18 CPUs, N1 adopted, wlan0, hci0, two haptic devices, both
  audio cards, -30 dB ceiling, netconsole configfs, nft ok. Warm restart with wlan0 in use: same, primary.
- **Daily promoted: `daily-wifi-20261107-4feff24c.bin`** (no self-test flag): primary, all of the above.
  `boot.bin.prev` = the test twin. Modules for `7.3.0-ga0f2f30c967b` (128, phram) on the root.
- Still to confirm on this exact kernel when Rolando is home: one lid-close sleep (the fix is the same code that passed
  on the W4 line), and a speaker listening check.

### Result (NOASPMFLAG-T1 and BOARDV2-T1, 2026-11-07 17:10-17:21 UTC, loop, nobody at the machine)

- **No `pcie_aspm=off`** (`next-daily-noaspmflag-20261107-bc0c69a0`, series kernel a0f2f30c967b): boots primary, N1 adopted,
  `pci 0000:00:00.0: ASPM: Link Capabilities L0s L1 treated as unsupported to avoid device defect` (series 0085 strips
  ASPM on the adopted root port), `LnkCtl: ASPM Disabled`, wlan0 associated; **5-minute soak with Wi-Fi traffic: alive,
  no freeze** (the W3 freeze came ~30 s after login). **PASS: the boot flag is redundant with 0085**; the next daily
  build drops `pcie_aspm=off`. Side note: 14 % loss on the Wi-Fi ping during the soak (rtt 2-15 ms), to look at
  separately (association quality, not ASPM).
- **Board-v2 DTB** (`next-daily-boardv2-20261107-7fac672d`: the PR v2 DT + the local ATC0 gadget node, no audio nodes):
  first boot **fell back** to the test twin. Retry running to separate a one-off from a real failure.
- The separate ASPM PR branch (`pr/pcie-apple-adopted-port-aspm`) is redundant with edimoldovan's ab24d156868e (our
  0085), now validated here; hold it and point to his.

### Result (BOARDV2-T2, 2026-11-07 17:22-17:26 UTC, loop)

Retry of the board-v2 DTB payload: **boots on the primary slot**, self-test "network OK": NVMe root, DockChannel
keyboard/trackpad/actuator, 10 input devices, N1 adopted, wlan0 associated, hci0, battery, 6 hwmon (the SMC set; the
daily's extra 6 are the amps), no audio (expected, the PR DT has no audio nodes), the panel connector reports
`Unknown-1` connected (no `apple,internal-panel` in the PR DT). **The v2 board DT is validated**; PR opened.

### Observation: first boot of a new payload file fails once (4 of ~16 today)

DAILY-NEXT "full", crash-log T1, the lid+Wi-Fi test twin and the board-v2 payload each fell back on the FIRST boot after
the file was written, and every retry of the same bytes booted; no second-or-later boot of any file failed today. Not
yet explained (not a data problem: the hash was verified before and after). Mitigation to try on the next deploys:
after `mv` and `sync`, unmount and remount the ESP before rebooting, and keep counting. Crash-log T1 was never retried,
so its "does not boot" verdict is weaker than recorded.

### Result (GPU E2a control, 2026-11-07 18:34-18:37 UTC, loop, nobody at the machine)

Payload `e2a-ctl-20261107-e71fc225` (kernel `7.3.0-g3671d907d570` = series + Aurora #1012 + the 15 commits of the
27.2+ port, DRM_ASAHI=y; DTB = daily + E1's disabled GPU nodes; m1n1 `n1-warm-gpu` at 0x410000 bytes; no
`chosen.m5pro,gpu`): **primary slot on the first boot**, 18 CPUs, N1 adopted, wlan0 associated, self-test network OK.
m1n1: `FDT: GPU: T6050: hand-off off (chosen.m5pro,gpu=unset), GPU nodes as the DT has them`. Kernel: no
`2300000000.gpu` line, gpu/mailbox/pmgr_gfx nodes disabled, driver idle; `e2-readback.sh` verdict
`CONTROL (no gpu var): gpu node disabled, driver idle = as designed`. The 0x410000 stage-2 image boots. **PASS.**
Daily restored. E2b (hand-off on) is staged and waits for Rolando's go (one uncovered failure mode needs the power button).

### Result (DCP stage A, 2026-11-07 18:38-18:42 UTC, loop)

Payload `dcpa-20261107-e0a474e8` (daily kernel + daily DTB + m1n1 `n1-warm-gpu-dcp` = n1-warm + GPU hand-off 0028 +
DCP 0024/0025, not armed): **fell back** on its first boot (stage-1 -> daily). The captured loader log belongs to the
fallback boot, so the cause is open: the first-boot-of-a-new-file pattern again, or 0024's unconditional reservation of
the nine coprocessor `__OS_LOG` segments (the one thing this loader does on every boot that the E2a loader does not).
Retry once after the E2 chain; if it falls back again, the DCP loader needs the panel or a trace before stages B0/B
(which use the same loader) can mean anything.

### Result (GPU E2b, 2026-11-07 18:42-18:46 UTC, loop, nobody at the machine): THE GPU FIRMWARE BOOTS

Payload `e2b-gpu-20261107-3f2fec04` (= E2a + `chosen.m5pro,gpu=1`). First boot of the file, primary slot, self-test
"network OK", 18 CPUs, N1 adopted, wlan0 associated.
- m1n1: `FDT: GPU: T6050: chosen.m5pro,gpu=1: GPU hand-off`; ttbs/pagetables/handoff/l2-pagetables, fw-text 0xa4000,
  fw-data 0x184000 all "outside Linux RAM"; sgx 0x2300000000+0x3fdc000; mailboxes GFX/GFX1 from the ADT.
- Kernel: six reserved-memory regions; `always-on domain afr/gfx is off at boot, turning it on`; `aurora 2300000000.gpu:
  Probing...`; `GPU ID registers: 0xb031100 0xb0a00 0x11020a 0x40404 0x1320311 0x400c1809`; `GPU firmware build:
  26C5035r for T6050 G17S` -> `GPU firmware: 27.3 (26C5035r), G17S`; `GPU idle power-off delay: 2 ms`; MMU initialised,
  IO maps; `RTKit: Initializing (protocol version 12)` x2; `M5 firmware graph ready: private +0x178000, shared +0x34000`;
  **`M5 primary initdata acknowledged`**, **`M5 secondary initdata acknowledged`**, **`M5 firmware opening records
  retired`**, **`[drm] Initialized aurora 1.0.0 for 2300000000.gpu on minor 1`**; `/dev/dri/card1` (driver aurora) and
  `/dev/dri/renderD128`; power domains gfx/afr/gpx on, cs off; mailboxes bound to apple-mailbox; no crash, no SError,
  no DART/UAT fault, no RCU stall; stable for the 2+ minutes until the daily was restored.
- The 27.2+ InitData graph (A/B2/C/D) is accepted by the 27.3 beta 1 firmware on the first try. `e2-readback.sh`
  says STOP-FAULT on one line that is the harmless `printk: debug: skip boot console de-registration.` (same false
  positive as E2a): treat the run as **PASS E2**. Next: userspace (Mesa for G17 under the `aurora` DRM name), a soak,
  then the GPU kernel as the daily. Logs: `~/Work/agents/gpu-e2/logs/e2b/` (private).

### Result (DCP stage A retry, 2026-11-07 18:46-18:50 UTC, loop)

Same payload `dcpa-20261107-e0a474e8`: **boots on the primary slot** (self-test network OK). The loader with the GPU
hand-off and the display hand-off code (not armed) is fine; it reserves the coprocessor `__OS_LOG` segments
(`FDT: T6050: mtp __OS_LOG ... reserved`, `auss-cpu0 ...`). Fifth instance today of "first boot of a new payload file
falls back once, the retry boots" (DAILY-NEXT full, crash-log T1, lid+Wi-Fi twin, board-v2, DCP-A). E2a/E2b and the
no-ASPM payload were exceptions (first boot fine). Stages B0 and B run next.

### Result (DCP stages B0 and B, 2026-11-07 18:50-19:07 UTC, loop; reruns with full capture)

- **B0** (`dcpb0-20261107-fe531c17`: gpu-dcp m1n1, daily kernel, daily DTB + mk-fixed9's display nodes without
  bw-scratch, `chosen.m5,t6050-display=1`): primary on the first boot (twice). Loader: `DCP: T6050: dcp at 0x48ae00000:
  CPU_CONTROL 0x10 (running) CPU_STATUS 0xec; PROTECT dart-dcp 0xff dart-disp0 0x1b9`; dart-dcp SID 23, dart-disp0
  SIDs 0 and 16 all `four-level, the ADT's table`; `reserved 8 coprocessor __OS_LOG segments`; **`dcp handed off: vram
  0x10bd15f4000+0x72c4000 reserved as its framebuffer; firmware-version 27.3 beta, firmware-compat 27.3.0; dcp, mailbox,
  dart-dcp, dart-disp0 and the display subsystem enabled`**. Kernel (no DRM_APPLE): dcp node `okay` in iommu group 0,
  simpledrm unchanged, panel fine. **PASS.**
- **B** (`dcpb-20261107-02a4e1d0`: same + the `7.3.0-dcp-g3671d907d570` kernel with DRM_APPLE and the 27.3 method table,
  drm.debug + dyndbg): same loader lines; kernel: `apple-dart 48a340000.iommu ... locked: 1` and `48a300000 ... locked: 1`,
  simpledrm card0 stays, then **`apple-dcp 48ae00000.dcp: error -ENODEV: Incompatible devicetree! Use devicetree matching
  this kernel.`** exactly as predicted (no bw-scratch), before any DCP register access; no DART faults; netconsole target
  up on this kernel. **PASS.** Only the internal panel's `apple,bw-scratch` offset stands between this and stage C
  (attended). Logs: `~/Work/agents/gpu-e2/logs/dcp/` (private).
- Observation: restoring the daily after B (a fresh copy of the same daily file) came back `fallback-after-failure`,
  then booted: the first-boot pattern happens to a re-written copy of a known-good file too, with the drop_caches
  mitigation in place. It is about freshly written files, not their content.

### Result (GPU first frame, 2026-11-07 19:25-19:31 UTC, loop): VULKAN WORKS, GL SUBMITS REJECTED

E2b payload again (`e2b-gpu-20261107-3f2fec04`), this time written with a real ESP unmount/remount-by-device and an
on-disk re-hash before the reboot: **primary on the first boot** (the previous attempt, written the old way, fell back
once). Aurora Mesa agx3c (`/opt/mesa-aurora`, `ASAHI_M5_BRINGUP=1`) via `gpu-first-frame.sh --screen`:
- **Vulkan: PASS.** `deviceName = Apple M5 Pro (G17S B1)`, `driverName = Borealis`; gpubench `compute.light` and
  `render.light` ok; **gpubench-stress `render.first` 206 iterations and `xq.chain` 8114 iterations / 132,939,776
  checks, 0 errors**; vkmark headless cube runs on the GPU; aurora-diag gpu passes. No GPU kernel errors other than the
  rejected GL submissions below.
- **OpenGL / GLES: FAIL at submit.** Contexts create (`GL_RENDERER: Apple M5 Pro (G17S B1)`, GLES 3.2 / GL 4.6), but every
  render submission is refused: userspace `DRM_IOCTL_ASAHI_SUBMIT render failed: Invalid argument (256x256 tile 32x32
  layers 1 samples 1)` (also 64x64 and 3456x2234), kernel `aurora 2300000000.gpu: [File N Queue 1]: IOCTL: submit
  failed! (submission ID: X err: EINVAL)`. So the Gallium render submit differs from the Vulkan one in something the
  kernel validation refuses on this device. `eglinfo -B` exits 2; the GBM-to-simpledrm steps and the on-panel frame
  (step 8) fail for the same reason; the gpubench-gl step "passed" only by its own criterion (context identity).
- 7 of 12 steps pass. Agent on the GL submit EINVAL (kernel validation vs Gallium submission). Hyprland on the GPU
  waits for it (Hyprland renders through GLES).

### Result (GPU first frame on zink + Hyprland on the GPU, 2026-11-07 19:57-20:03 UTC, loop): 13 of 13 PASS

Root cause of the GL failure: on the M5 the kernel requires each render submission to carry its program list
(`DRM_ASAHI_SET_RENDER_RESOURCES`, `backend.rs:197` returns EINVAL without it, feature `DRM_ASAHI_FEATURE_RENDER_RESOURCES`);
Aurora's Vulkan driver sends it, the Gallium GL driver never does, and Gallium's native M5 path only covers the base
M5 (G17G). Upstream runs M5 Pro GL through zink on Vulkan. Fix (Mesa `a79e5a94e31` on agx3c, installed): Gallium
declines G17S/G17C, the wrapper and the GPU session set `MESA_LOADER_DRIVER_OVERRIDE=zink`.
- E2b payload written with the unmount/remount path: primary on the first boot (second time in a row).
- `gpu-first-frame.sh --screen`: **13 passed, 0 failed**, no `submit failed` in the kernel log. Vulkan identity; GLES
  headless render on renderD128 (`GL_RENDERER: zink Vulkan 1.4(Apple M5 Pro (G17S B1) (AURORA_BOREALIS))`, correct
  pixels); eglinfo surfaceless (GL core/compat/ES all on zink over the M5 Pro); GBM on renderD128 with PRIME into
  simpledrm, explicit and implicit modifiers, correct readback; Vulkan compute/render/stress (2 passed, 61 s) and
  vkmark; gpubench-gl on zink; aurora-diag; **step 8: a GPU-rendered frame modeset onto the panel (left green, right
  orange, 10 s): PASS**.
- **Hyprland on the GPU session** (`/run/hypr-gpu`, zink): started on tty2 (pid up, the Omarchy bar and wallpaper), a
  `grim` screenshot through the session captured the desktop (private copy in `~/Work/agents/gpu-e2/logs/firstframe/`).
  Which renderer Hyprland picked (zink on the GPU vs software) is not yet confirmed from its log; the next GPU boot
  copies the runtime Hyprland log before the restore.

### Result (GPU soak with Hyprland on the GPU, 2026-11-07 20:04-20:35 UTC, loop)

E2b payload, Hyprland started in the GPU session (`/run/hypr-gpu`, zink). The runtime Hyprland log settles the
renderer question: aquamarine `No matching render node for .../framebuffer, falling back to sole renderD on the system:
/dev/dri/renderD128`, `Creating CDRMRenderer on gpu /dev/dri/renderD128`, `Vendor: Mesa`, **`Renderer: zink Vulkan
1.4(Apple M5 Pro (G17S B1) (AURORA_BOREALIS))`**. The desktop is GPU-rendered; scanout stays on simpledrm (CPU copy)
until the DCP driver lands. glmark2-wayland inside the session every 5 minutes: scores 597, 613, 612, 846, 890 (the
GPU is warming up its clocks; no throttling signs), zero GPU kernel errors over the soak, Hyprland pid stable, battery
Full on the charger. The GPU kernel `7.3.0-g3671d907d570` is being promoted to the daily (daily twin of E2b being
built; the GPU session becomes the automatic default when the aurora card exists).


## GPU DAILY promotion (2026-11-07 20:35 UTC)

The GPU kernel is the daily. `boot.bin` = `e2b-daily-20261107-fd4b3b9e.bin` (kernel `7.3.0-g3671d907d570` = the 87-patch series + Aurora #1012 + the 27.2+ InitData port, m1n1 `n1-warm-gpu`, battery, `n1=4`, `gpu=1`, no `m5.selftest`), `boot.bin.prev` = the E2b test twin `3f2fec04` (same kernel with the self-test; falls back to a GPU kernel too, because the previous daily `4feff24c` has no aurora driver and the Hyprland launcher would then start the software session, which is the intended behaviour either way).

- Written with the remount procedure; first boot on the primary slot, 76 s to SSH, 18 CPUs, Wi-Fi connected, Bluetooth, haptic, 2 sound cards, battery.
- `GPU firmware: 27.3 (26C5035r), G17S`, `M5 firmware opening records retired`, `[drm] Initialized aurora 1.0.0`, `renderD128` present; both getty@tty2 and the user session units active.
- Preceded by the 25-minute Hyprland-on-GPU soak on the same kernel (zink over Borealis, glmark2 clean, 0 GPU errors; see "GPU soak" above).
- Desktop: `~rolo/.local/bin/hypr-session` now starts the GPU session by itself when a `/sys/class/drm/card*/device/driver` resolves to `aurora` and `/opt/mesa-aurora` exists (software session otherwise, or when `/etc/hypr-gpu-disable` exists; `/run/hypr-gpu` forces it for one boot; a GPU session that dies within 30 s is replaced by the software session). Mesa variables come from `/etc/mesa-aurora/session.env` and are exported to Hyprland, the user manager and the D-Bus activation environment. Not yet seen live: a full desktop login on this kernel (next attended boot).
- Rollback: `put` the previous daily `daily-wifi-20261107-4feff24c.bin` back as `boot.bin` (kept in `~/Work/agents/next-daily/payloads/private/`).

## First-boot fallback root cause (2026-11-07, analysis of today's logs)

Not a stage-1 read problem. The timing of the fallback boots (reboot sent to kernel start 21-28 s, same as a clean
reboot) shows the stage-1 found iBoot's error count already set on its first pass: the restart of the session that
had just written tens of MB to the FAT ESP was counted (vfat `sync` sends no device flush; apple-nvme's final
shutdown waits at most 5 s). Every fallback today followed an ESP write + reboot within 1 s; every reboot without a
write was clean. Full analysis, the 0017 stage-1 patch (size check against the directory entry, watchdog re-armed
after the read, optional 0x31/0x32 stage marks so a counted restart boots the primary) and the `esp-put.sh` write
procedure are in `contrib/pending/boot-ab/firstboot/`. Two corrections: E2b's first boot did not fall back (it booted
and went silent); the W4 restore fallback fits this cause, not a warm-N1 hang. Decision: use `esp-put.sh` for every
ESP write from now on; 0017 goes on the stage-1 slots in an attended sitting.

## NVRAM-RO: boot NOR and NVRAM partition visible from Linux (2026-11-07 20:47 UTC)

Payload `nvram-20261107-130350ed.bin` = the GPU daily twin (kernel `7.3.0-g3671d907d570`, m1n1 `n1-warm-gpu`,
self-test on) with the qspi controller enabled in the DTB plus `flash@0` (jedec,spi-nor, 25 MHz, single wire) and the
fixed partition `nvram` at 0x700000 size 0xc0000 (`contrib/pending/nvram/patches/0001`). Stock `spi-apple-qspi`
module (no J716s board row, `read_only=Y`).

- Boot: primary slot first try, 76 s to SSH, 18 CPUs, Wi-Fi, GPU up (renderD128). The ESP was written with the new
  `esp-put.sh` procedure (fsync, remount read-only, 5 s settle): 2 of 2 fresh payload writes booted on the first pass
  (test twin and the daily restore).
- `spi-nor spi0.0` probes under `apple-qspi` at `505118000.spi`, `1 fixed-partitions partitions found`, mtd2 =
  `nvram` 786432 bytes, erasesize 4096. The 768 KiB partition reads back fully from `/dev/mtd2ro`.
- Parsed read-only with `v3-nvram.py show`: 12 banks of 64 KiB with consecutive generations (192 to 203), active bank
  10 (gen 203), 217 entries, 34137 of 65536 bytes used. Variable names match the ones macOS shows (`boot-volume`,
  `upgrade-boot-volume`, `auto-boot`, `boot-command`, `backlight-nits`, `prev-lang:kbd`, `SystemAudioVolume`,
  `boot-breadcrumbs`, …). The dump stays on the machine in `/var/lib/nvram-t6050/` (root only; it carries tokens).
- Not done: no write. Next: the J716s board row module swap and one attended `alt-boot-volume` write (next boot =
  macOS), which needs asahi-nvram/asahi-bless built on the MacBook.

## OMACOM-WDT-KEEP: the omacom-stacked m1n1 boots the J716s (2026-11-07 21:16 UTC)

Payload `omacom-wdt-keep-20261107-2014252d.bin` = m1n1 `v1.6.1-424-gaee8488` (omacom/m1n1 #26 + our five-branch T6050
series: bring-up + RVBAR relay, N1, GPU hand-off, display hand-off, `m1n1.wdt=keep`) + the 87-patch daily kernel
`7.3.0-ga0f2f30c967b` and DTB, `chosen.asahi,t6050-n1=4`, self-test on. Written with `esp-put.sh`.

- Primary slot first pass, 76 s to SSH, 18 CPUs, Wi-Fi connected (N1 trained by this loader), Bluetooth, no USB
  gadget network (omacom has no T6050 combo-PHY tunable fill; expected), 1 benign dmesg match.
- Stage-2 log: `Primary WDT left armed (m1n1.wdt=keep)`, `SMP: installed RVBAR relay`, `n1: ... training apcie0 port 0
  with ANS started after the SMC reset release`, `pcie-t6050: port 0 up, N1 at 01:00.0`, `n1: port 0 up: root port and
  DART okay`, `kboot: MTP DAPF programmed on T6050` (only the MTP DAPF, as #26 does), then the kernel.
- So the omacom PR series boots this machine end to end with the watchdog kept armed; the GPU and display hand-offs
  were present but not armed in this payload.
- Restore of the GPU daily (`esp-put.sh`, 5 s settle) came back on `fallback-after-failure` (the prev twin, same kernel)
  with `boot.bin` intact: the first esp-put write that still fell back once (2 of 3 esp-put writes booted first pass).
  The session that wrote it was the omacom-m1n1-booted kernel; the pmu scratchpad was not read on that boot. The
  loop runners now print `m5pro,pmu-scrpad` so the next fallback can be classified (stage-1 0017's marks remain the
  real fix).

## POWER-T1: the power kernel resets within a minute (2026-11-07 21:22 UTC) — FAIL

Payload `power-t1-20261107-c15b58cd.bin` = the GPU daily tree + the 13 cpufreq/PMC/CLPC/thermal patches (kernel
`7.3.0-g1d276f9e36c7`, PMC in observe mode by default), GPU daily DTB with the power DT changes (T6050 cpufreq
compatibles only, `turbo-mode` on the M clusters' boost state, `apple,t6050-pmc`/`apple,t6050-clpc`, TCMb/mTPL keys),
self-test on, written with `esp-put.sh`.

- Result: the machine came back 102 s after the reboot on `fallback-after-failure`, pmu scratchpad `300130` (error
  stage 0x30 = after the loader's hand-over, in Linux), uptime 39 s: the power kernel ran for roughly a minute and
  reset before the network came up, then stage 1 booted the previous twin. No crash log (no netconsole yet).
- Prime suspect: the PMC driver probing the `apple,t6050-pmc` node (the agent's own flagged risk: a read of an
  unclocked PMC window could fault); second: the cpufreq status-register read path on T6050. Bisect payloads
  requested (cpufreq + thermal only; PMC/CLPC only).
- The boot before this one had come back on `fallback-after-failure` with `300100` (error stage 0x00): that one was the
  restore after the omacom-m1n1 session, i.e. the counted-restart case, not a payload failure.
- The GPU daily restore then booted on the primary slot (pmu `300030`, 0 errors).

## K1/K2: the kernel trains the N1 port itself (2026-11-07 21:27 UTC) — PASS

Kernel `7.3.0-g50d99dcea7b4` = the 87-patch series + 0088-0094 (edimoldovan's cold train, host tunables, DART
manual availability and adopted-DART availability; our warm-N1 250 ms power reset, the J716s gP13 template write and
the DT: tunable windows, `pwren-gpios`, first SMC GPIO bank, GP power chain). Patches in
`contrib/pending/wireless/patches/linux/0004-0010`, m1n1 0028 in `patches/m1n1/`.

- K1 (`n1kernel-k1-20261107-c62b1ca5.bin`, m1n1 n1-dt = n1-warm + 0028, NO `chosen.m5pro,n1` line): the loader logs
  `n1: port 0 not up: root port and DART okay` and leaves the port down; the kernel prints `port 0: trained by Linux,
  the boot loader left it down`, adopts it, `link retrained after a root-port reset`, all three functions enumerate
  (106b:1900/1902/1903), Wi-Fi connected, Bluetooth up; 77 s to SSH, primary slot.
- K1 warm restart with wlan0 in use: same result (trained again by the kernel). So the warm-N1 problem is solved on the
  kernel side too (the 250 ms power-line reset), without the loader's N1 code.
- K2 (`n1kernel-k2-20261107-96afa462.bin`, n1-warm with `n1=4`): the loader trains as before, the kernel adopts the
  port (`Link down` then `link retrained after a root-port reset`), Wi-Fi and Bluetooth up: the adopt path still works
  with the DART deferral and the new power-domain nodes.
- All four boots in this run (K1, K1 warm, K2, restore) came up on the primary slot first pass with `esp-put.sh`.
- One dmesg line matched the fault pattern on each boot; it is the benign nvme `PANICLOG not yet written` RTKit
  syslog line (same count on the daily).
- Consequence: loader-side N1 training (m1n1 0023, 0025-0027, the n1 modes) becomes optional for the disk-boot path;
  the loader still has to keep a down port enabled and copy the per-machine tunables (0022 + 0028). Next: fold
  0088-0094 into the GPU daily with the n1-dt loader and no n1 line.

## DISPLAY STAGE C: the DCP drives the internal panel (2026-11-07 21:35 UTC) — PASS (unattended, remote checks)

Payload `dcpc-20261107-9ec63d9a.bin` = DCP kernel `7.3.0-dcp-g3671d907d570` (GPU tree + `j716s-dcp.config`, DRM_APPLE=y
with the 27.3 method table and swap layout), m1n1 `n1-warm-gpu-dcp` with `chosen.m5,t6050-display=1`, DTB `dcp9c` (fixed9
display nodes + internal `apple,bw-scratch` = PMC + 0x20000), `drm.debug=0x1e` + dyndbg, self-test on. Written with
`esp-put.sh`; primary slot first pass, 75 s to SSH, Wi-Fi up.

- Loader: `dcp handed off: vram 0x10bd15f4000+0x72c4000 reserved as its framebuffer; firmware-version 27.3 beta,
  firmware-compat 27.3.0; dcp, mailbox, dart-dcp, dart-disp0 and the display subsystem` locked to the ADT's page tables
  (`stage-c-loader-log.txt` in `contrib/validated/display/`, serial redacted).
- Kernel: `live DCP DMA resources retained until reboot`, `negotiating RTKit with the running DCP`, the firmware
  starts its pipeline (`start_ios_gated`, `switch to normal mode succeeded`), `boot done`, `dcp_hotplug() connected:1
  nr_modes:6`, `DCP booted`. simpledrm is gone; `card1` = `apple-drm`, connector `card1-eDP-2` connected and enabled,
  six 3456x2234 modes (the promoted timings predicted by the VRR analysis), backlight `apple-panel-bl` 300/600 (type
  platform; a 50 % write read back 300/600, so brightness writes do not reach the panel yet). No `DCP has crashed`,
  `swap failed`, `Incompatible devicetree` or timeout lines; 0 faults. The console kept printing through the DCP for the
  whole boot (fbcon moved to eDP-2), so swaps work; the cadence was not measured (the runner's modetest parse failed
  and tracefs was not mounted).
- Firmware complaints to follow up (`stage-c-dcp-journal-excerpt.txt`): `DCP requested undeclared provider clock index
  0` and `getClockFrequency returned pixelClock = 0` (clock provider missing in the DT), `Could not find table
  'display-backlight-compensation-v1'`, `init_power_lut: failed to read power-lut-data-x`, `load_ca_data: Unrecognized
  data version 0`, `create_default_fb_surface ... failed`, `panel charge parity violation`, `Could not find Backlight
  service / nvram service`, `LACS_ERROR`. Analysis agent running.
- Visual confirmation from Rolando (picture continuity at takeover, backlight level) pending; he saw the console flood
  on the panel, which is the DCP rendering.
- Next: the same payload with the 120 Hz (3) and VRR (2) patches and a fixed check script (modetest + tracefs),
  measured unattended; then DCP in the daily once the brightness path and the clock provider are sorted.

## CAMERA I1: ISP DARTs and power domains (2026-11-07 21:40 UTC) — PASS

Payload `isp-i1-20261107-68af92c8.bin` = the 87-patch daily kernel `7.3.0-ga0f2f30c967b` + the camera DTB (next-daily DTB
+ ISP node, 3 ISP DARTs, 8 pmgr domains; ISP firmware segments reserved: isp-firmware-text 12400 KiB, isp-firmware-data
20288 KiB), m1n1 `n1-warm-gpu`, `apple_isp` blacklisted, self-test on; written with `esp-put.sh`, primary slot first
pass, 76 s to SSH.

- The three ISP DARTs (5828c0000, 5828e0000, 582900000) bind to `apple-dart`; 8 of 8 ISP power domains present by name
  (isp_be and isp_fe on, the rest off); `apple_isp` not loaded; no faults (the single match is the benign printk line).
- The pre-check that compares the ISP firmware segment ranges against the ADT could not confirm the segments on the
  running daily (parser mismatch on the `adt` MTD dump), so I2 (firmware handshake, /dev/video0) was skipped by design.
  I2 also needs a kernel with the ISP patches 0001 + 0003 (the daily `apple-isp.ko` has no `apple,t6050-isp` alias);
  that build is in progress.

### Stage C corrections after the journal analysis (`contrib/validated/display/stage-c-analysis.md`)

- The journal was complete (1.58 s to 77 s); the flood is `pr_publish: id: 119` every ~40 ms. The firmware stayed alive the
  whole time; 0 real fault lines (`grep -i "BUG:"` had matched `printk: debug:`).
- Swaps: 8 atomic commits; the mode set was a no-op for the firmware (`Already set to timingID: 2 colorID: 1`, the
  120 Hz timing iBoot left running); fbcon took eDP-2 at 1.62 s; three plane commits blocked 15-19 ms (1-2 frames at
  120 Hz), the rest returned in under 1 ms, so swaps are consistent with working but unproven: the tracepoints were
  compiled out (`CONFIG_FTRACE`/`CONFIG_TRACING` unset in the DCP config) and the flip test used the wrong driver name
  (`apple`, not `appledrm`).
- Backlight: the "50 % write" wrote 300 into a panel already at 300 (no-op); brightness writes are untested, not broken.
- Modes: 120.00 (preferred, 1042130 kHz), 60, 59.94, 50, 48, 47.95; `vrr:0` on all six (expected on firmware 27 without
  the VRR patch).
- DT gaps: the dcp node copied `/arm-io/dcp`'s empty `clock-ids` while the firmware pipe belongs to `disp0` (clock-ids
  0x169, 0x1ca) -> `undeclared provider clock index 0`; `apple,artwork-display-gamut` and the panel `apple,color-gamut`
  absent. Driver items: log the A534 default-surface status, drop id 119 from the publish log, replace the hard-coded
  temperature 3029, silence -ENODATA on the backlight restore, make the EDT read serve ADT timing values. The next DCP
  payloads carry FTRACE/TRACING, a corrected check script and a DTB variant with the clock and gamut additions.

## OMACOM-WDT-KEEP-v30: the m1n1 stack rebased on omacom/m1n1 #30 boots the J716s (2026-11-07 22:07 UTC) — PASS

Payload `omacom-wdt-keep-20261107-3713d26f.bin` = m1n1 `v1.6.1-429-g6653bb2` (#30 + our five branches: PRs #33-#37) +
the 87-patch daily kernel, `chosen.asahi,t6050-n1=4`, self-test on. Primary slot first pass, 74 s to SSH, 18 CPUs, Wi-Fi
(N1 trained by the loader), Bluetooth. Loader log: `Primary WDT left armed`, `SMP: installed RVBAR relay`, N1 port up,
`kboot: MTP DAPF programmed on T6050`, and #30's USB host prep ran on the J716s for the first time (`USB0/1/2: left in
USB 2.0 host mode for the next stage`; `chosen` carries `apple,t6050-usbprep`); no USB gadget network, as expected.

Restore of the GPU daily afterwards: `fallback-after-failure`, pmu `300130` (error stage 0x30, in Linux), 39 s uptime
102 s after the reboot: the GPU daily's first attempt reset within about a minute of the hand-over and stage 1 booted the
prev twin (same kernel). This is the second 0x30 fallback today, and the plain GPU daily cannot be at fault by itself (it
booted first pass seven times in between). Both 0x30 cases came within two boots of an omacom-m1n1 session (the first one
was the power T1 boot, which followed the 0x00 fallback after the #26 session); the five boots in between (K1, K1 warm,
K2, stage C, camera I1) and their restores were clean. Hypothesis to test: state the omacom stage 2 leaves behind (USB
host prep, DAPF coverage, ANS handling) survives the warm restart and trips the next boot's early Linux. Consequence: the
power T1 "failure" is not proven to be the power patches; T1 is being re-run after a clean daily boot.

## POWER-T1 retest: the power kernel boots and observes (2026-11-07 22:12 UTC) — PASS

Same payload `power-t1-20261107-c15b58cd.bin` (kernel `7.3.0-g1d276f9e36c7`), booted after a plain reboot into the GPU
daily (primary, pmu `300030`). Primary slot first pass, 75 s to SSH, Wi-Fi up. So the earlier T1 failure was the
"reset after an omacom-loader session" case, not the power patches.

- cpufreq: `apple-cpufreq` on all three policies, min 300000, max 4308000 / 4308000 / 4608000, boost 4380000 listed on
  the M clusters (boost off), no sugov threads (fast switching kept), latency 400 µs. `cur(hw)` reads the real state.
- PMC: `observation only: 5 agents, 4 rails, nothing is written`; rail0-3 enable 0x00000000 (so the boot loader enables
  no voter, as predicted: DRAM and fabric run at the firmware floors today), agent0 (PMP) floor 0x15, agents 1-4 floor 0;
  debugfs status `mode: observe`, `dcs limit: state 0 of 7`. CLPC: `voter agent 1 is not enabled on rail 0/1` (expected
  in observe mode). All words well-formed for the T8142 layout (T2 desk check passes: no 0xffffffff, floors one nibble).
- Thermal: `macsmc_soc_die: hottest of TCMb`.
- Not measured this run: the 60 s idle floor and the load test (the first run's numbers were taken on the fallback
  kernel); to be captured on the next power boot. T3 (`pmc.observe=0`, floors written) stays attended.
- The restore of the GPU daily afterwards came back on `fallback-after-failure` pmu `300100` (error stage 0x00, counted
  restart) even with `esp-put.sh`: third 0x00/0x30 fallback today; the sessions whose restart got counted were the two
  omacom-loader sessions and this power-kernel session, while the daily, K1/K2, stage C and camera sessions restarted
  cleanly. Root-cause agent has all three data points.

## GL-NATIVE A/B: the native Gallium driver runs on the G17S (2026-11-07 22:18 UTC) — PARTIAL

/opt/mesa-aurora-gl (agx3c a8e86a80cdc + the 3 patches in `contrib/pending/gpu/gl-native/`), kernel `7.3.0-g3671d907d570`,
no reboot, zink tree untouched.
- Every GL submit is accepted by the M5 kernel (no EINVAL, no `submit failed`, no GPU errors): the storage lists and the
  M5 encodings are right in structure. Renderer `Apple M5 Pro (G17S B1)` on EGL surfaceless, GLES and desktop GL
  (3.2 core).
- gl-native-smoke 11/12 scenes pass with pixel checks (triangle, depth D32F/D24S8, texture, MRT, MSAA resolve, compute
  with and without shared memory, many draws, geometry shader, mipmaps, large scissor); FAIL stencil-blend (alpha 0x40
  instead of 0xff, RGB right). egl-offscreen-test PASS (first accelerated GLES frame, pixels right).
- gbm-scanout-test FAIL: the LINEAR scanout buffer imported into simpledrm reads black (render into a linear GBM target
  does not land); first-frame suite 1-3 pass, 4a fails the same way. gpubench-gl refused ("need desktop GL 3.3 or GLES
  3.0"): the native tree exposes GL 3.2 core.
- Open: the blend alpha, the linear render target, the GL version gate. Agent on it. zink stays the session default.

## Fallback analysis update (`contrib/pending/boot-ab/firstboot/`, f1506d7)

The 0x30 cases are the new payload panicking in its first ~5 s of Linux followed by `CONFIG_PANIC_TIMEOUT=10`
(reset 10-15 s after the attempted kernel started; calibrated against the deliberate sysrq panic: 22-26 s from reset to
the next kernel), not a reset a minute in; DCP-A at 18:38 had the same signature with no omacom session before it. iBoot
sets boot_stage 0x30 before stage 1, macsmc-reboot rewrites 0x30 at probe and 0x00 from its reboot notifier, so 0x30 =
died anywhere between hand-over and an orderly restart; 0x00 = died inside its own restart. Nothing inside the SoC
survives the SMC restart; what does: the N1 (warm), the USB-C PD controllers, SMC state, the PMU scratchpad. Main
suspect for the early panic: the warm N1 taken over in the first second (every payload ran `n1=4`). Installed on the
root: `m5-stage-mark.sh` with two oneshot units (boot_stage 0x33 after local-fs, 0x34 after network-online) so a
fallback's error stage tells kernel/initramfs (30) from after-root (33) from after-network (34); `firstboot-probe.sh`
recalibrated (first-pass <= 35 s, m1n1 reboot 36-54, Linux panic 55-74, apple_wdt 75-169, stage-1 wdt >= 170).
Experiment running: omacom #30 session -> esp-put daily -> idle 5 min -> reboot, 3 rounds, then omacom -> plain reboot
x3 (no writes); then the same without `n1` in the omacom payload if the first set reproduces.

## RESTART-EXP round 1-2: omacom session -> daily, with a 5-minute idle before the reboot (2026-11-07 22:21 UTC)

Two rounds of: boot the omacom #30 loader payload (primary, 73 s), esp-put the GPU daily from that session, idle 5 min
with Wi-Fi traffic (280/280 pings), `systemctl reboot`. Both restores came back on the primary slot, pmu `300000`,
75-76 s. The two restores from omacom sessions that fell back earlier today were rebooted within a second of the ESP
write. So with a settle time the omacom session restarts cleanly; the write-to-reboot gap matters after all, at least
for these sessions (esp-put's 5 s settle is not enough; 5 min is). The userspace stage marks work: `boot_stage` reads
0x34 (network up) on every booted session. Round 3 and the no-write control did not run (the payload file had been moved
by its agent); the control is re-queued with the review-fixed loader.

## RESTART-EXP2: power-kernel session, plain reboots without an ESP write (2026-11-07 22:38 UTC) — all clean

Boot power-T1 (primary), then `systemctl reboot` three times with no ESP write and ~60 s of Wi-Fi traffic before each:
all three came back on the primary slot, pmu `300000`, 75-77 s. The restore of the GPU daily (esp-put, now with the 60 s
settle) was clean too. So the power kernel's own restart path is fine when the machine is idle; the counted restart
earlier followed a reboot one second after a 40 MB ESP write. Together with rounds 1-2 of the omacom experiment this
supports the "restart while still busy after the write burst" model and the 60 s settle rule.

## POWER-T1 baseline (2026-11-07 22:51 UTC)

Power kernel `7.3.0-g1d276f9e36c7`, PMC observing, primary slot (60 s settle rule in force; all boots clean).
- Idle 60 s sampled 80-140 s after boot, battery full on the charger: SMC total system power (PSTR) mean 10.4 W (the GPU
  daily read 9.0 W in an earlier 60 s sample taken at the same point of its boot; a later, longer idle sample is needed
  before calling that a difference, since boot-time services were still settling). `time_in_state` deltas came back
  empty (cpufreq stats not available in this config), so the 300 MHz floor residency is not yet measured.
- Load (all 18 cores busy): the CLPC computes `-> dcs 7 soc 3` for all three clusters, `last_vote 0x37`, 4802 samples
  with 4802 update errors (every vote refused: observe mode), and the floors release afterwards; rail enables stay 0;
  `cur(hw)` reached 4308/4308/4608 MHz in the first T1 run. No memcpy baseline: `perf` is not installed on the root
  (install `perf` or use a small memcpy benchmark before T3).
- T3 (first PMC write) stays attended: payload `power-t3-20261107-98336aec.bin`, checklist in `contrib/pending/power/REPORT.md`.

## DCP-120 series: 120 Hz and VRR measurements (2026-11-07 22:59 UTC) — mode list confirmed, cadence still unmeasured

DCP kernel `7.3.0-dcp-g22ec57f56b27` (gpu-27 tree + `j716s-dcp.config` + FTRACE/TRACING + promotion 0001-0003 + the
VRR pair), m1n1 `n1-warm-gpu-dcp`, self-test on, 60 s settle rule; three boots, all primary first pass, 0 faults, no
DCP crash or swap-failed lines. Payloads `dcpc-120` (dcp9c DTB), `dcpc-120d` (dcp9d = dcp9c + `clk_disp0` 712 MHz on the
dcp node + P3 gamut), `dcpc-120d-vrr` (dcp9d + `appledrm.fw27_panel_vrr=1 appledrm.promotion_rates=1`).

- Firmware mode list (P1, from the TimingElements dictionary and the `iomfb_timing_mode` tracepoints, now compiled
  in): six timings at 3456x2234: ID 2 120.000 Hz preferred (score 17026, total 3536x2456, 1042130 kHz), and promoted
  ID 3 60.000, ID 4 48.000, ID 5 59.940, ID 6 47.952 (total 3536x2456), ID 7 50.000 (total 3536x2946); VRR range
  0-0 on all, DiscreteMediaRefreshRates empty. The mode set adopts timing 2 (`set_digital_out_mode finished with 8500
  to spare`). So the firmware already offers the fixed rates as timings; patch 0002 is a no-op and 0003's synthesized
  rates duplicate them (with `promotion_rates=1` the DRM list is 120.00 100.01 60.00 59.94 50.00 48.00 47.95, only
  100.01 synthesized). `files: contrib/validated/display/dcp120/`.
- V0: `vrr_capable` 0 by default; V1: 1 with `fw27_panel_vrr=1` (the 24-120 fallback); the firmware log shows the
  adaptive-sync parameter accepted at the mode set (`IOMFBParameter_adaptive_sync Req minRR = 0x0, mediaTargetRate =
  0x0`).
- P3 swap cadence FAIL: `modetest -M apple -s <conn>@<crtc>:3456x2234-120` returns `failed to set mode: Function not
  implemented`, so no flips were driven; V2 (VRR_ENABLED toggle) then ended with `Atomic Commit failed`. The test
  tooling, not the display, is the blocker: the agents are producing an atomic test program.
- dcp9d DTB: the firmware's clock complaints are gone (0 `undeclared provider clock` lines vs 4 with dcp9c); the P3
  gamut properties were read without complaint.
- Backlight: writes to `brightness` (150, 450) are accepted but `actual_brightness` stays 300; the driver logs
  `backlight restore unavailable: -61` and `no loader brightness reported; backlight starts at 300 nits without a
  panel change`: the brightness path needs work on firmware 27 (agent on it).

## OMACOM-WDT-KEEP-v30 review-fixed: the PR tips boot the J716s (2026-11-07 23:11 UTC) — PASS

Payload `omacom-wdt-keep-20261107-15618a15.bin` = m1n1 `v1.6.1-429-g02785a3` (the force-updated tips of omacom/m1n1
#33-#37 after the review fixes) + the 87-patch daily kernel, `chosen.asahi,t6050-n1=4`, self-test on, 60 s settle.
Primary slot first pass, 74 s, 18 CPUs, Wi-Fi (N1 trained by the loader) and Bluetooth up; loader log: watchdog kept,
RVBAR relay, N1 port up, MTP DAPF, #30's USB host prep on USB0/1/2; the restore of the GPU daily was clean (primary,
pmu 300000). The review fixes (N1 settings kept when the DT has them, storage checks on every stop, train once per
boot, one SMC deadline per command, watchdog-keep across the CDC path) are therefore exercised on hardware.

### DCP-120 series: why the measurements failed (journal analysis, 2026-11-07 23:30 UTC)

On all three boots the first swap after the boot mode set (swap 5) was accepted by the firmware but never reported
shown; at ~10.5 s `flip_done timed out` and `IOMFB transaction timed out: cmd=0 oob=0 present=1 accepted=1 swap=5`,
the driver marked the DCP crashed and refused every later commit with -EINVAL (modetest printed ENOSYS because
`drmModeDirtyFB` overwrote the errno). The stage C boot without the 120 Hz patches did not stall and its swaps carried
no timestamps; patch 0001 adds ARM-counter timestamps to every 120 Hz swap, the same thing that stalled swaps on the
desktop 26.6 panel until Aurora switched to a constant 120. Next boots (queued): the same payload with
`appledrm.fw27_counter_timestamps=0 drm.debug=0x16`, plus the VRR variant, driven by the new atomic test program
`vrrflip` (`contrib/pending/dcp/vrr/tools/`): one atomic mode set, continuous flips, phases fixed / vrr-on / vrr-on-50 /
vrr-off / vrr-off-50 with page-flip interval statistics and swap-completion counts from the tracepoints. The firmware did
accept the adaptive-sync parameter (`IOMFBParameter_adaptive_sync Req minRR = 0x0 ...`), confirming parameter 15.
Fixed rates vs VRR in the VRR patches already match the firmware: VRR only on timing 2, timings 3-7 as real mode sets;
the only synthesized mode is 100.01 Hz from the 120 Hz series.

## DAILY-N1K: next daily promoted, the kernel trains the Wi-Fi port (2026-11-07 23:16 UTC) — PASS

Kernel `7.3.0-g36845aa5f650` = the GPU daily tree (87-patch series + Aurora #1012 + the 27.2+ GPU port) + the kernel-side
N1 training series (wireless 0004-0010) + the F6 key fix (peripherals 0007) + the read-only NVRAM nodes (nvram 0001);
loader `m1n1-plain-n1-dt-gpu` (n1-warm-gpu + 0028: the port stays enabled and the host tunables are copied, no training);
no `chosen.m5pro,n1` variable; `chosen.m5pro,gpu=1`; battery on. 60 s settle rule.

- Test twin `daily-n1k-test-20261107-5c74c66c.bin`: primary first pass, 78 s, 18 CPUs, `port 0: trained by Linux, the
  boot loader left it down`, link retrained after the root-port reset, Wi-Fi connected, Bluetooth, GPU firmware 27.3
  G17S booted, `[drm] Initialized aurora`, haptic actuator, `spi-nor` probed (mtd nvram partition present), 0 faults.
- Warm restart with wlan0 in use: same result (the kernel trains the port again).
- Promotion: `boot.bin.prev` = the test twin, `boot.bin` = `daily-n1k-20261107-512a1c00.bin` (no self-test); first boot
  primary, 79 s, same checks pass. `DAILY-N1K: PASS`.
- The loader no longer trains the N1 on the daily; m1n1's N1 training (0023, 0025-0027, the n1 modes) is now an
  optional path kept for the omacom series and #65.
- Rollback: the twin on the prev slot; the previous GPU daily `e2b-daily-20261107-fd4b3b9e.bin` is kept on the Studio.

## RESTART-EXP3: omacom-loader session, plain reboots (2026-11-07 23:25 UTC) — all clean

From the review-fixed omacom loader session (m1n1 02785a3 + daily kernel): three `systemctl reboot` with no ESP write,
each after ~30 s of Wi-Fi traffic: all primary, pmu `300000`, 73-75 s. The "immediate" arm did not run as intended: the
restore of the new daily went through esp-put, whose default settle is now 60 s, so it was a write + 60 s case, and it
came back clean (primary, 300000). Tally after esp-put with the 60 s settle: 6 of 6 restores clean across the
omacom-loader, power-kernel and daily sessions; with the old ~1 s gap, 4 of 11 were counted or failed. Exp4 (busy
disk without an ESP write, and write + 60 s, three each) is running.

## RESTART-EXP4: a disk write burst right before the reboot reproduces the failure without any ESP write (2026-11-07 23:37 UTC)

From the omacom-loader session (m1n1 02785a3 + daily kernel), three times: `dd if=/dev/zero of=/root/burst bs=1M count=70
conv=fsync` on the ext4 root, then `systemctl reboot` within 1 s, no ESP write at all. Arm 2.1: `fallback-after-failure`,
pmu `300130` (error stage 0x30: the next boot of the same, unchanged payload died in early Linux and the twin booted,
42 s uptime at 103 s). Arms 2.2 and 2.3: clean (primary, `300030`). Then three times: re-write the same payload to the ESP
with esp-put's 60 s settle, reboot: all three clean. Restore of the daily (60 s settle): clean.

Conclusion: the failure is caused by rebooting while the SSD is still busy after a write burst, independent of the FAT ESP
(an ext4 burst reproduces it), and it shows up as the *next* boot failing early (0x30) or as a counted restart (0x00)
depending on where the restart stalls. A 60 s idle after any large write removes it (9 of 9 clean with the settle today,
across the omacom-loader, power-kernel and daily sessions; 5 of 14 failed with a ~1 s gap). The 60 s settle is now the
default in `esp-put.sh`; the loop scripts and the daily's own habits should avoid rebooting right after large writes until
the NVMe shutdown path is fixed (next: kernel-side analysis of apple-nvme shutdown vs an in-flight background write, and
what iBoot/ANS does on the next start).

## TB-T0: Thunderbolt kernel boot lost the machine (2026-11-08 00:02 UTC) — OPEN, needs hands

Payload `tb-t0-20261107-ee8f136e.bin` (kernel `7.3.0-g121f7cde7d92` = tb/j716s-daily with USB4/Thunderbolt built in,
T0 DTB with the ATC1/ATC2 acio routers, pcie tunnels and their DARTs/NHIs; m1n1 `n1-warm-gpu`; self-test on; 60 s settle)
written from the new daily (primary, `300030`). After `systemctl reboot` the machine never answered again: no SSH, no
Tailscale (node last seen at the reboot), 100 % ping loss for 50+ minutes. Neither the self-test revert (no network
within 90 s -> previous slot) nor the stage-1 watchdog (150 s -> previous slot) brought the network back, so either the
fallback twin (`daily-n1k-test 5c74c66c`) also fails to get network after this kernel ran (warm hardware state left by
the USB4/ATC bring-up, e.g. the N1 or the Type-C ports, which the kernel-side training may not recover), or the machine is
hung with the watchdog disarmed, or it is looping on the twin. The queued display, GL-session and camera I2 steps are
waiting behind it. Recovery: power button (cold start), then macOS if the loader slot needs the daily put back by hand.

### TB-T0: what the panel showed (2026-11-08, Rolando's photo)

Kernel `7.3.0-g121f7cde7d92` (the T0 Thunderbolt payload) hung in kernel init: `INFO: task swapper/0:1 blocked for more
than 1087 seconds ... Tainted: G S`, call trace `wait_for_completion -> __flush_work -> flush_work ->
deferred_probe_initcall -> do_one_initcall -> kernel_init_freeable`, repeating at 1209 and 1330 s. A deferred driver
probe blocked forever on a completion (prime suspect: the USB4/CIO controller or acio router probe without the loader's
combo-PHY tunables), so userspace and the self-test never started; Linux had taken over the watchdog, so no reset
happened. Rolando power-cycled it. Rule: Thunderbolt/USB4 bring-up payloads are attended-only; the kernel-side hang
needs a probe timeout (and a boot-time watchdog that only Linux's init completion pets) before another loop attempt.

### Reconciliation notes (2026-11-08 02:40 UTC)

- GL-NATIVE: the "PARTIAL, 11/12, 3 patches" section above is superseded: with patches 0004-0005 (and timer queries back)
  the native tree passes 12/12 scenes, the scanout test and gpubench on the machine (`contrib/pending/gpu/gl-native/REPORT.md`,
  22:50 UTC); the session switch is in progress.
- Fallback tallies: the exact counts differ slightly between sections because they were written as the runs came in; the
  authoritative table is `contrib/pending/boot-ab/firstboot/REPORT.md` (immediate reboots after a burst: about 1 in 3
  fail; with at least 60 s idle: 0 failures in 17 including the exp3/exp4 arms).
- POWER-T1 "FAIL" above is superseded by the retest (PASS) and the baseline section.
- m1n1 0028 (keep a down N1 port enabled, copy host tunables) lives in `contrib/pending/wireless/patches/m1n1/`; the GPU
  hand-off patch also numbered 0028 lives in `contrib/pending/gpu/patches/m1n1/`.

## DCP-120 constant timestamps: no stall, 120 Hz mode set, VRR works (2026-11-08 02:10 UTC) — PASS

Same DCP kernel (`7.3.0-dcp-g22ec57f56b27`, tracing on) with `appledrm.fw27_counter_timestamps=0` (= the v2 patch 0001,
constant 120 in the swap timestamp words) and `drm.debug=0x16`, dcp9d DTB (clock + gamut); two boots, both primary first
pass, 55 s to SSH; 60 s settle rule; GPU daily restored afterwards (primary).

- Stall check at 62 s on both boots: `flip_done timed out` 0, `IOMFB transaction timed out` 0, crashed 0, 14 swap
  completions already traced (fbcon). The first-swap stall of the earlier series is gone: counter timestamps were the
  cause, constant timestamps are the fix (120 Hz v2 series `contrib/pending/dcp/promotion/`).
- `dcpc-120d-ct0-vrr` (opt-ins `fw27_panel_vrr=1 promotion_rates=1`), `vrrflip` (atomic, `contrib/pending/dcp/vrr/tools/`):
  modes listed 120 (preferred), 100 (synthesized), 60, 59.94, 50, 48, 47.95; `vrr_capable 1`; atomic mode set at
  3456x2234@120 OK; `VRR_ENABLED 1` committed in a plain flip: the driver re-selects timing 2 with vrr on
  (`set_digital_out_mode ... vrr:1`, firmware `IOMFBParameter_adaptive_sync Req minRR = 0x180000` = 24 Hz, ~385 ms for
  the mode set), `VRR_ENABLED 0` re-selects with minRR 0. Phases (page-flip intervals): fixed p50 13.2 ms, vrr-on p50
  8.35 ms, **vrr-on-50 p50 20.8 ms** (a 50 fps-paced client is shown every 5 subframes, i.e. real adaptive refresh),
  vrr-off p50 8.34 ms, **vrr-off-50 p50 16.65 ms** (fixed 120 Hz alternating 16.7/25 ms as predicted). Swap completions
  per phase 400-452. The tool draws the 31 MB frame on the CPU into a dumb buffer, so the fps averages (50-59) and the
  p95 outliers (50-140 ms) are the test program's CPU fill, not the display path; a GPU-rendered client is the next
  measurement (Hyprland on the DCP). One `swap failed! status 4294967295` at 106 s (during vrr-off-50) without a
  crash flag: to be understood (a single rejected swap after the VRR-off re-select).
- The non-VRR boot ran the tool with a wrong option, so only the stall check and a 1-swap modetest ran there; its
  stall result is the one that matters.
- Conclusion for the daily: carry the 120 Hz v2 patches (constant timestamps + brightness guard) and the VRR pair
  rebased on v2 (opt-in by default); Hyprland `misc:vrr = 1` becomes usable once the session scans out through the DCP.

## GL-NATIVE: the native Gallium driver is the desktop's GL (2026-11-08 02:23 UTC) — PASS

/opt/mesa-aurora-gl at MESA_COMMIT 043a4c58080c4951fea3797fe45fc6898ce77632 (agx3c + the five patches in
`contrib/pending/gpu/gl-native/`), on the daily `7.3.0-g36845aa5f650`, no reboot.
- Headless A/B: all 12 steps pass on both trees. Native: eglinfo renderer `Apple M5 Pro (G17S B1)` (GL 4.6 core),
  gl-native-smoke 12/12 with pixel checks, gl-native-probe (blend/mask alpha, GBM LINEAR buffers, GBM window surface),
  egl-offscreen-test, gbm-scanout-test (LINEAR into simpledrm) and gpubench-gl render.light; zink the same.
- Session: `/etc/mesa-aurora/session.env` now points at the native tree (zink copy kept as `session.env.zink`); the
  restarted GPU session came up with Hyprland on the native driver (`GL_RENDERER: Apple M5 Pro (G17S B1)`, aquamarine
  renderer with high context priority and robustness), Quickshell running; `glmark2-es2-wayland` short run inside the
  session scored 1278 (zink: 597-890 during the earlier soak). No GPU errors.
- A 30-minute desktop soak on the native session is running next; the launcher keeps the 30 s fallback to the software
  session and `/etc/mesa-aurora/session.env.zink` is the one-file rollback.

## 2026-11-08 02:51 UTC: GL-NATIVE soak v3, PASS

Native Gallium GL as the desktop GL (`/etc/mesa-aurora/session.env` -> `/opt/mesa-aurora-gl`), kernel
`7.3.0-g36845aa5f650`, Hyprland running throughout. Six rounds of glmark2 over 24 minutes inside the live session:

| round | glmark2 | GPU error lines | Hyprland | hottest sensor |
|---|---|---|---|---|
| 1 | 988 | 0 | up | 28.3 °C |
| 2 | 937 | 0 | up | 28.6 °C |
| 3 | 937 | 0 | up | 29.0 °C |
| 4 | 995 | 0 | up | 29.2 °C |
| 5 | 942 | 0 | up | 29.4 °C |
| 6 | 930 | 0 | up | 29.6 °C |

GL_RENDERER `Apple M5 Pro (G17S B1)` every round, aquamarine `IMG_context_priority supported, requesting high`.
Scores are lower than the 1278 A/B figure because the compositor was running; no faults, no hangs, no fallback.
The native session stays. Log: `~/Work/agents/gpu-gl-native/loop/run-gl-soak-v3.log`.

## 2026-11-08 03:03 UTC: DAILY-DCP first boots, FAIL (early panic, fallback worked)

First daily with the DCP driving the panel: kernel `7.3.0-gbd53915f2ef1` (daily 36845aa5f650 + promotion v2 +
dcp9d display DT + VRR pair opt-in), loader `m1n1-plain-n1-dt-gpu-dcp`, variables `chosen.m5pro,gpu=1` +
`chosen.m5,t6050-display=1`, no `n1` line. Both twins (`daily-dcp-test` dfe0c6cc, `daily-dcp-test-vrr` 3606884e)
fell back: error stage 0x30, round trip 214 s against 103 s for a clean boot. Correction (03:40 UTC): the fallback
kernel started about 203 s after the reboot command, which is the stage-1 watchdog band of `firstboot-probe.sh`
(>= 170 s), not the Linux-panic band (55-74 s). The boot died before any Linux restart handler was registered:
m1n1 stage 2 never reached Linux, or Linux hung or panicked before macsmc-reboot and apple_wdt probed (a panic with
no restart handler halts and the 150 s stage-1 dog resets). Error stage 0x30 only says iBoot, m1n1 or Linux was
running. Stage 1 booted `boot.bin.prev` (the daily's test
twin 5c74c66c) both times; the daily was restored by the runner (slot primary, 59 s to ssh). Nothing from the
failed boots is on disk (no pstore region in the DT).

What is new in this combination: the DCP has only ever booted without the GPU hand-off (stage C and dcp120 carried
`chosen.m5pro,n1=4` + display, no `gpu=1`, kernel 22ec57f56b27). This was the first boot with the m1n1 GPU hand-off
plus the display hand-off plus `DRM_ASAHI=y` and `DRM_APPLE=y` together on the daily DT (reserved-memory,
power-controller, NVRAM nodes). Ranked causes (`contrib/pending/dcp/daily-dcp/FIRST-BOOT-ANALYSIS.md`): H1 the GPU driver and the DCP
take-over probing together in the initcall window before macsmc-reboot/apple_wdt (simpledrm 1488, aurora 1489,
appledrm 1490, macsmc 1500, macsmc_reboot 1710, apple_wdt 1751; stage C never had `gpu=1`, the daily has
`DRM_APPLE=n`); H2 the DCP on the daily-n1k base without the GPU; H3 m1n1 with both hand-offs plus 0028 (low);
H4 the kernel build (low). Memory carve-outs, shared DT state and reg/IRQ overlaps were ruled out by reading.
No pstore: iBoot zeroes DRAM and clears `/pram` on every boot (CRASHLOG results), so evidence has to come from the
panel or netconsole. Bisect payloads (one change each, verified against the twin byte for byte otherwise):
B2 no `gpu=1`; B2b `gpu=1` + `initcall_blacklist=__aurora_init`; B3 the daily-n1k DTB, no display variable;
B1 the `n1-dt-gpu` loader (no display hand-off; the DCP cannot drive the panel then, it is the DCP kernel as a GPU
daily). Boot order: B2; if it boots, B2b; if it falls back, B3 then B1. Running unattended
(`~/Work/agents/daily-dcp/loop/run-dcp-bisect.sh`).
Runner log: `~/Work/agents/daily-dcp/loop/run-daily-dcp-test.log`. The two-card Hyprland session files stayed
installed on the root; on the daily (simpledrm + aurora) the new launcher takes the old path, to be confirmed at
the next desktop start.

## 2026-11-08 03:22 UTC: LOOP-SAFETY watchdog twins, positive PASS with a caveat, negative NOT RUN

Kernel `7.3.0-ga0f2f30c967b` twins of next-daily-wifi (loader-trained N1, `chosen.m5pro,n1=4`), see
`contrib/pending/boot-ab/loop-safety/REPORT.md`.

- Positive `wdt-opener` (2daadc5b, `watchdog.open_timeout=300`, initramfs opener): booted, m5-selftest "network OK",
  up past 400 s with no reset, clean `systemctl reboot` back on the primary slot, booted again. Caveat: the hand-over
  to systemd did not happen. No `m5pro-watchdog.conf` drop-in was installed, `RuntimeWatchdogUSec=0`, `wdctl` said
  "Device or resource busy" and at shutdown systemd logged "Failed to open watchdog device /dev/watchdog0: Device or
  resource busy" then the kernel "watchdog did not stop!". The initramfs petter held the device for the whole boot;
  that is what prevented the 330 s reset. No `m5-wdt` lines reached the kernel log. Fix in progress (the
  pre-switch_root block, kmsg logging, an "initramfs reached" stage mark 0x31).
- Negative `wdt-noopener` (242a6abb, `open_timeout=120`, plain initramfs, drop-in removed first): the machine fell
  back to prev (count 1) but the journal holds no boot of the twin kernel; the fallback kernel started about 77 s
  after the reboot command, which is the "Linux froze after apple_wdt probed" band (75-169 s) bordering the
  Linux-panic band, not the 150 s expected from `open_timeout=120` + 30 s. The PMU error stage reads 0x30 but was
  0x30 before the test (stale). Inconclusive; rerun with the 0x31 mark so "never ran" and "ran and died" can be told
  apart. The opener twin with the same kernel, DTB, loader and variables booted twice, so the two twins differ only
  in the initramfs and the open_timeout value.
- The daily was restored after the series (primary slot, 58 s to ssh). The desktop came up on the daily with the new
  two-card launcher installed (simpledrm path): Hyprland running on tty2.

## 2026-11-08 03:46 UTC: DAILY-DCP bisect, rounds 1 and 2 (in progress)

Each payload differs from the failed twin (or from B2) in one part; `firstboot-probe.sh` classifies every boot.
Kernel `7.3.0-gbd53915f2ef1` throughout unless noted.

| boot | change | result |
|---|---|---|
| B2 | no `chosen.m5pro,gpu=1` (display hand-off, kernel N1 training) | fell back, delta 208 s, stage-1 watchdog |
| B3 | daily-n1k DTB, no display variable | booted, clean (GPU, Wi-Fi, desktop) |
| B1 | loader `n1-dt-gpu` (no display hand-off), twin DTB | booted, clean |
| B5 | B2 with the stage C DTB (dcp9d) | booted, clean: `card1` apple-drm, eDP-2 connected, six 3456x2234 timings, no flip or transaction timeouts, Hyprland up; no N1 port under dcp9d |
| B6 | B2 with the stage C loader and `chosen.m5pro,n1=4` (loader-trained N1) | running |

Conclusions so far: the kernel build is fine (B3, B1), the GPU + DCP combination is not the trigger (B2), the display
hand-off with the DCP kernel works on the stage C device tree (B5). The trigger is in the in-tree daily-dcp DTB's
additions over dcp9d under the display hand-off: the kernel-trained N1 port, the apcie power-controller settings, the
reserved-memory, NVRAM/SPI or GPU nodes. B6 splits the N1 path; round 3 payloads are being prepared for both outcomes.
Logs: `~/Work/agents/daily-dcp/loop/run-dcp-bisect.log`, `run-dcp-bisect2.log`; B5's journal `journal-B5.txt` there.

## 2026-11-08 04:10 UTC: DAILY-DCP bisect round 3 and the root cause

| boot | change from B2 | result |
|---|---|---|
| B6 | stage C loader + `chosen.m5pro,n1=4` (loader-trained N1) | fell back, 208 s, stage-1 watchdog |
| B10 | in-tree DTB without the six apcie power-controllers | fell back, 207 s |
| B12 | in-tree DTB with the kernel-training PCIe statics reverted to dcp9d | fell back, 208 s |
| B8 | in-tree DTB without port00 `pwren-gpios` (no N1) | fell back, 209 s |
| B11 | in-tree DTB without the GPU and NVRAM nodes | running, predicted to fall back |

Root cause (found by reading `src/kboot.c` of the n1-dt-gpu-dcp loader, section 9 of
`contrib/pending/dcp/daily-dcp/FIRST-BOOT-ANALYSIS.md`): `dt_set_display_t6050()` re-finds the display nodes by
phandle and bails with "DCP: T6050: a display node has no phandle" when `dcp` or `display-subsystem` has none. dtc
emits a phandle only for nodes some property references; the in-tree J716s DT labels both nodes but only extends them
(`&dcp { ... }`), so the in-tree DTB has no phandle on either (dcp9d, built differently, has 0xd3 and 0xd4). The bail
makes `kboot_prepare_dt()` fail, stage 2 prints "Failed to prepare FDT!" and drops into the proxy; with no host
attached nothing feeds the watchdog, and the stage-1 150 s dog resets the machine. That fits every boot: with the
display hand-off and the in-tree DTB everything fell back (twin, VRR twin, B2, B6, B8, B10, B12); without the hand-off
(B1, B3) or on dcp9d (B5, stage C) everything booted. The semantic DT diff missed it because the normaliser drops
`phandle` lines.

Fixes: (a) DTB with `phandle` added to the two nodes (`mk-dt-fix.py`, payloads `dcpfix-b4-nogpu`,
`daily-dcp-phfix-test`, `daily-dcp-phfix-test-vrr`), round 4 running; (b) loader patch
`m1n1-0029-dcp-give-display-nodes-a-phandle.diff` (give any display node without a phandle a new one, highest offset
first), being built and ported to omacom/m1n1 #35, which carries the same check.

## 2026-11-08 04:23 UTC: DAILY-DCP round 4: the phandle fix confirmed; GPU + DCP together is a second problem

| boot | payload | result |
|---|---|---|
| B4 | B2 + the two phandles in the DTB (display hand-off, no GPU) | booted, clean, delta 50 s: `card1` apple-drm, eDP-2, six timings, no timeouts, Hyprland up |
| daily-dcp-phfix-test | the twin + the two phandles (`gpu=1` + display) | fell back, delta 55 s, `attempt-linux-panic`, PMU 300100 (orderly restart after the panic) |

B4 against the five identical payloads that fell back at 208 s settles the first failure: the missing phandles on
`dcp` and `display-subsystem`. The second result is new: with the GPU hand-off and the display hand-off in the same
boot the kernel panics in its first seconds, after macsmc-reboot has registered (the restart was orderly). The same
kernel boots as a GPU daily (B1, B3) and as a DCP-only payload (B4, B5), so this is an interaction between the two
drivers or the two hand-offs. No console capture exists for it yet. Next: a capture kernel with the GPU driver as a
module so the panic lands in the journal, and code reading of the two probe paths
(`contrib/pending/dcp/daily-dcp/GPU-DCP-PANIC-ANALYSIS.md`, in progress). The loader-fix twin (phfix m1n1, in-tree
DTB) boots next to validate the loader side of the fix; its expected outcome is the same 55 s panic.

## 2026-11-08 04:26 UTC: DAILY-DCP VRR twin: GPU + DCP together BOOTED, two-card Hyprland session live

`daily-dcp-phfix-test-vrr` (be84bb7d: kernel `7.3.0-gbd53915f2ef1`, phandle-fixed DTB, `chosen.m5pro,gpu=1` +
`chosen.m5,t6050-display=1`, `appledrm.fw27_panel_vrr=1`) booted cleanly (delta 50 s) three minutes after the
non-VRR twin with the same kernel and DTB had panicked at 55 s. So the GPU + DCP early panic is intermittent, not
deterministic; the only static difference is the VRR module parameter.

On this boot: `card0` aurora (GPU), `card1` apple-drm (DCP, eDP-2 connected, six 3456x2234 timings), `renderD128`,
no flip or transaction timeouts, no DCP crash, no faults, Wi-Fi and Bluetooth up. The two-card session launcher took
the DCP path (`AQ_DRM_DEVICES=/dev/dri/card1`, render node `/dev/dri/renderD128`), Hyprland ran for user rolo on
tty2, and glmark2 inside the session reported `GL_RENDERER Apple M5 Pro (G17S B1)` at 911 FPS: the first desktop
with GPU rendering and DCP scanout on this machine. The verifier `hypr-dcp-verify` could not read Hyprland's state
when run as root over ssh (empty hyprctl fields, `as_user` helper not found under `timeout`, swap tracing printed a
PASS with no captured events), so the 120 Hz pacing, direct scanout and VRR numbers are not yet measured; the
verifier is being fixed. The daily was restored afterwards.

Correction (04:45 UTC): the 55 s fallback of `daily-dcp-phfix-test` (e03be5ac) was most likely a counted restart of
the previous (B4) session, not a GPU + DCP panic: clean boots in the same runner measure 49-51 s, so +4-6 s matches
the "counted restart, error stage 00, the new file is never read" class of `firstboot/REPORT.md`; a panic path skips
the reboot notifiers and would have left error stage 0x30, and a panic in the GPU probe (which runs before
macsmc-reboot registers on the good dual boot) would have ended in the stage-1 watchdog at about 208 s. The
`firstboot-probe.sh` bands predate the 20 s shutdown settle hook, which moved clean boots from about 27 s to about
50 s, so the probe mislabelled it. The loader-fix twin now booting is the re-run of that configuration.

## 2026-11-08 04:55 UTC: DCP session measurements from the VRR twin boot (verifier output re-read)

The six verifier failures on the `daily-dcp-phfix-test-vrr` boot were verifier bugs (a shell function handed to
`timeout`, a NUL byte in Hyprland's log making grep treat it as binary, a jq key with a dot). The captured traces and
logs are valid and say:

- Hyprland drives `/dev/dri/card1` (apple-drm) and renders on `renderD128` with the native GL tree; scanout buffers
  3456x2234 XR24 LINEAR, rendered into directly (no copy); explicit sync with timeline syncobjs on both cards; all six
  panel modes listed, 120 Hz preferred.
- VRR was on from the profile (`misc:vrr=1`): kernel log at 10.3 s "VRR_ENABLED 1", firmware minimum refresh 24 Hz,
  "3456x2234@120 Hz DSC=NO VRR=YES"; no DCP or GPU errors.
- 120 Hz pacing, vkcube composited: 2397 swaps in 20 s (119-120/s), interval typical 8.334 ms, p99 8.51 ms, max
  12.45 ms; 2396 of 2397 intervals one refresh; submit-to-complete 2.9 ms (p99 3.0). Idle desktop: 0 swaps in 3 s.
- glmark2 fullscreen: the panel showed 89 frames/s while glmark2 rendered 911 FPS unthrottled; the late compositor
  frames came out at 12.45 ms (three 4.17 ms DCP steps), never 16.7 ms, which is VRR presenting a late frame at the
  next half-refresh step. Caution: Mesa skipped draws because the AGX backend refused a fragment shader
  (`persp_mul_agx3`), so 911 FPS overstates the GPU; to report on the native-GL work.
- Not measured yet: direct scanout (mpv never started) and the 50 fps VRR pacing test. The fixed verifier
  (`contrib/pending/gpu/userspace/mesa-aurora/session-dcp/hypr-dcp-verify`) runs next on the promoted daily.

## 2026-11-08 04:53 UTC: DAILY-DCP PROMOTED: `daily-dcp-lfix-20261107-689facad.bin` is the daily

Kernel `7.3.0-gbd53915f2ef1` (daily 36845aa5f650 + 120 Hz v2 constant timestamps + dcp9d display DT + VRR pair,
opt-in off), loader `m1n1-plain-n1-dt-gpu-dcp-phfix` (display hand-off + GPU hand-off + N1 port kept enabled, gives
the display nodes a phandle), in-tree DTB, variables `chosen.m5pro,gpu=1` + `chosen.m5,t6050-display=1`, no self-test.
The first write-and-reboot was counted as a failed restart (first pass, 55 s, the intermittent counted-restart class;
the new file was never read) and stage 1 booted prev; a plain reboot 30 s later booted the new daily on the primary
slot: `card0` aurora, `card1` apple-drm with eDP-2 connected, no flip or transaction timeouts, no DCP crash, no
faults, Hyprland on the two-card session (`AQ_DRM_DEVICES=/dev/dri/card1`, render node `renderD128`), Wi-Fi
connected, Bluetooth `hci0`, backlight 300/600 and writes reach the panel. Rollback: `boot.bin.prev` =
`daily-n1k-test-20261107-5c74c66c.bin` (the previous daily's self-test twin; reaches the network; N1-aware loader);
`~/Work/agents/daily-n1k/loop/run-restore-daily.sh` now restores the new daily. Loop runners written before this
point still name the old daily as their restore target and must be updated before reuse.

## 2026-11-08 05:10 UTC: LOOP-SAFETY v2: negative PASS, positive hand-over PASS, systemd now owns the watchdog on the daily

Kernel `7.3.0-ga0f2f30c967b` twins with the v2 initramfs opener (`contrib/pending/boot-ab/loop-safety/`), error stage
cleared before each boot, `ESP_SETTLE=120`.

- Negative `wdt2-noopener` (`m5.wdt=off`, `watchdog.open_timeout=120`, drop-in removed first): the twin ran (its
  journal is on disk), wrote the marks 0x31 (initramfs), 0x33 (root) and 0x34 (network up, 8.5 s), the kernel stopped
  feeding the dog at the 120 s open timeout and it bit about 150 s in; stage 1 fell back to prev with error stage 0x34
  (fallback kernel 192 s after the reboot, the "apple_wdt bite" band). PASS: a boot that reaches userspace but never
  opens the device is reset and recovered, with the stage of death recorded.
- Positive `wdt2-opener` (`watchdog.open_timeout=300`): `m5-wdt` lines in the kernel log in order: initramfs reached,
  `/dev/watchdog0` opened and petted, `m5pro-watchdog.conf` installed, device released, "systemd opens it next";
  systemd 1.4 s: "Using hardware watchdog /dev/watchdog0", `RuntimeWatchdogUSec=1min`. The twin then ran 100 s with
  PID 1 feeding the dog (no reset) until its own self-test reverted it: `ping` of the fixed check address failed
  although wlan0 had associated at 6.5 s (the USB NIC also had carrier); one occurrence, not understood, unrelated to
  the watchdog. Hand-over PASS; the 400 s criterion was not reached on this boot (v1 reached it with the petter).
- Side effect, intended: the drop-in now lives on the shared root, so the daily runs with `RuntimeWatchdogSec=60`
  (`RuntimeWatchdogUSec=1min` on the restored daily-dcp-lfix boot). A PID 1 stall of over 60 s now resets the
  machine; s2idle is handled by the watchdog core's PM notifier and `apple_wdt` suspend/resume (to be confirmed with a
  lid-close sleep, attended). Test payloads built by the patched `mk-daily.py` carry `watchdog.open_timeout=300` and
  the v2 opener initramfs; the daily carries neither.

## 2026-11-08 05:28 UTC: VRR ROUND: verifier PASS on the daily and on the VRR twin; `daily-dcp-lfix-vrr` PROMOTED

Fixed verifier (`hypr-dcp-verify`, run as root over ssh, finds the user's Hyprland instance itself; every timed PASS
requires captured `dcp:iomfb_swap_complete` events).

Daily `daily-dcp-lfix` (VRR off): 19 passed, 0 failed, 3 warnings. Hyprland drives the apple card and renders on
`renderD128` (Apple M5 Pro (G17S B1)), scanout buffers 3456x2234 XR24 LINEAR rendered into directly, KMS explicit
sync and EGL native fence sync, mode 3456x2234 at 120.000 Hz, profile `m5pro-dcp` active. vkcube composited:
2405 swaps in 20 s, median 120.0/s, p50 8.333 ms, 0 late. Warnings: the idle desktop flipped 247 times in 3 s on
this boot (something animating right after login; 0 swaps in 3 s on the twin boots), Mesa skipped glmark2 draws
(the AGX backend refused `persp_mul_agx3`), and fullscreen mpv is not direct-scanned (`blockedBy ["CANDIDATE"]`,
composited; to look at).

VRR twin `daily-dcp-lfix-test-vrr` (54b4d1c9, `appledrm.fw27_panel_vrr=1`): 22 passed, 0 failed, 2 warnings
(the same Mesa and direct-scanout notes). `vrr_capable` on, aquamarine "capable of vrr", hyprctl `vrrCapable=true`,
`misc:vrr=1` active. vkcube: 2405 swaps, p50 8.333 ms, p99 8.49 ms, stdev 0.033 ms, 0 late, submit-to-complete
2.7 ms. glmark2 fullscreen: the panel showed 91 frames/s (late compositor frames land at 12.4 ms, three 4.17 ms
steps). 50 fps client, VRR off: intervals p50 12.5 ms, whole-refresh multiples {1: 622, 2: 578} (judder). 50 fps
client, VRR on: intervals p50 20.825 ms, p99 20.92 ms, 0 late, 80 % within 1.5 ms of 20 ms: the panel follows the
client. Kernel: `VRR_ENABLED 0 -> 1`, firmware `adaptive_sync minRR = 0x180000` (24 Hz), `3456x2234@120 Hz DSC=NO
VRR=YES`. No flip or transaction timeouts, no DCP crash, no faults.

Promotion: `daily-dcp-lfix-vrr-20261107-7e244836.bin` (sha256 7e244836c80aa6ca83b9794a1db8065bee690fbf024f6df6df3566784712db15)
= `daily-dcp-lfix` + `appledrm.fw27_panel_vrr=1`, daily form; identical ingredients to the twin that passed. Booted
clean on the primary slot (delta 50 s): `card0` aurora, `card1` apple-drm, DCP session active, Hyprland up.
`boot.bin.prev` stays `daily-n1k-test-20261107-5c74c66c.bin`; `run-restore-daily.sh` now restores the VRR daily.
Open: direct scanout for fullscreen clients, the Mesa shader refusal (native GL), the idle-flip warning on the daily boot.

## 2026-11-08 08:18 UTC: OMACOM-WDT-KEEP r2 (stack on #30 140a36b), PASS

Payload `omacom-wdt-keep-r2-20261108-e52ca584.bin` (m1n1 v1.6.1-430-g64c8ce2 = our omacom stack rebased onto
edimoldovan's late-heap commit, daily kernel a0f2f30c967b, `t6050-n1=4`, self-test on): booted on the primary slot,
54 s to ssh, 18 CPUs, N1 trained by the loader and adopted, Wi-Fi and Bluetooth up, stage-2 log shows
`FDT: retained heap [...]` and `FDT: late heap [...] retained` before the jump. The VRR daily was restored afterwards.

## 2026-11-08 09:55 UTC: desktop fixes with Rolando at the machine (VRR DCP daily)

- Speakers silent: the chain was linked (bring-up filter sink -> hidden RawSpeakers, 6 channels) but the raw speaker
  route was stored at 2.7 % in wireplumber's state, the sink at 48 %, under the kernel -30 dB ceiling. Set the route to
  100 % (`~/.local/state/wireplumber/default-routes`, backup kept), the sink to 60 %, the speaker sink as the default;
  Rolando heard the test tone. The ceiling stays until the listening test.
- Wallpaper missing: Omarchy 4.5's shell reads the image size with `magick identify`; `imagemagick` was not installed.
  Installed it and restarted the shell (`omarchy-restart-shell`).
- Terminals black and repeated "app failure" notifications: the native Gallium GL driver cannot build Alacritty's
  fragment program (`G17G Gallium could not build the native fragment program`, draws "outside the native profile"
  dropped). The desktop GL is back on zink (`session.env.zink` copied over `session.env`, `session.env.native-20261108`
  kept), desktop restarted: Hyprland on the DCP session with zink, Alacritty clean. Native GL stays the A/B variant;
  analysis of the app regressions in `contrib/pending/gpu/gl-native/APP-REGRESSIONS.md` (in progress).

## 2026-11-08 10:45 UTC: Omarchy convergence with Rolando at the machine (second batch)

- `rolo` added to `wheel` with a validated `%wheel ALL=(ALL:ALL) ALL` drop-in (Omarchy's NOPASSWD helpers kept).
- Omarchy package fill: 163 packages from the base and aarch64 lists (deferred: ufw, docker, dotnet, libreoffice,
  moonlight, qemu binfmt, db libs, the two Hyprland 0.56-pinned add-ons, kernel-modules-hook which the boot guard refuses).
- Wi-Fi moved from systemd-networkd + wpa_supplicant@wlan0 to NetworkManager (what Omarchy's Wi-Fi menu drives):
  self-reverting script `nm-switch.sh` (backup under /root/nm-switch-backup, the wlan .network file moved aside,
  networkd and wpa_supplicant@wlan0 disabled, NetworkManager enabled, keyfile profile from the existing passphrase).
  The first activation failed with "ssid-not-found" although the SSID was in the scan list: the network is WPA2/WPA3
  transition and the profile needed `802-11-wireless-security.pmf=1` (optional protected management frames); with it
  wlan0 connected. The USB NIC kept the machine reachable throughout.
- Hyprland crash into safe mode (10:35 UTC): not a config problem. The GPU driver logged recovery faults from
  Chromium-class clients (`chrome[14008]`, then `claude-desktop[4017]`, "GPU work of a client failed ... the client sees
  a lost device"), the recovery also failed Hyprland's context (ENODATA), zink then crashed in `dri_create_fence_fd`
  (SEGV) instead of reporting a lost context, and the respawned Hyprland could not initialise EGL while the GPU was
  recovering (abort, safe-mode screen). A session restart after recovery brought the DCP session back. Analysis of the
  isolation and the zink crash in progress (`contrib/pending/gpu/GPU-RECOVERY-KILLS-COMPOSITOR.md`); stopgap: run
  Electron/Chromium apps without GPU acceleration until then.
- Native GL gl2 tree (patches 0001-0008) installed at /opt/mesa-aurora-gl2 next to zink; the first "readable" window
  Rolando saw ran on software rendering (env file missing at that moment); the proper gl2 window was opened but the
  GPU crash interrupted the check. The A/B moves to a dedicated session, not next to the zink compositor.
- `j716-listen` (local listening-test TUI) installed; fixed its pre-play gate (the daemon prints speaker lines only
  during playback).

## 2026-11-08 11:15 UTC: DCP daily DEMOTED for now: GPU client faults wedge the display

Three times today a GPU fault from an ordinary client (Google Chrome, Claude Desktop, then quickshell on a fresh boot
with Chromium/Electron already running GPU-less) was followed by the aurora recovery declaring Hyprland's context
lost, a zink SIGSEGV in `dri_create_fence_fd`, and on the DCP daily a display pipeline stuck on a page flip that
never completes ("Cannot commit when a page-flip is awaiting", 0 `iomfb_swap_complete`), which only a reboot clears.
Evidence captured on the machine before the last two reboots (`/root/wedge-1056`, `/root/wedge-1112`: dmesg,
dma-buf fence table, sysrq blocked-task dump with one kworker in D, DRM state, Hyprland logs).

Analysis (`contrib/pending/gpu/GPU-RECOVERY-KILLS-COMPOSITOR.md`): on M5 the recovery has no blame evidence, the
unclassified dropped work poisons its VM (bystanders included), spared compute fences can stay unsignalled, and the
apple-drm atomic commit waits on the plane's in-fence with no timeout. Fixes being built as a test payload
(`contrib/pending/gpu/recovery/`): no poisoning by dropped work, bounded fence signalling on recovery, a 1 s bounded
fence wait in apple-drm, plus a deliberate-hang reproducer.

Interim: the boot slot is back on `daily-n1k-20261107-512a1c00.bin` (simpledrm scanout, GPU render through zink):
a client fault can still crash Hyprland there but cannot wedge the panel, and the session restarts within seconds.
GPU acceleration stays off for Chrome, Chromium and Electron apps (flags files). The VRR DCP daily returns once the
recovery fixes pass the reproducer. `run-restore-daily.sh` points at daily-n1k again. Tracker: issue #36.

## 2026-11-08 11:56 UTC — Hyprland crash #3 of the day (daily-n1k, simpledrm + GPU)

- Sequence (dmesg + crash reports): chrome faulted the GPU at uptime 2299 s (recovery gen 7)
  → Hyprland 868 lost device → zink SIGSEGV. Rolando ran `sudo m5pro-rescue` from tty3 at
  11:54 (evidence `/root/wedge-1154`): the session restart brought Hyprland 51873 up, quickshell
  51934 faulted the GPU at 2370 s (gen 8) → Hyprland crashed again → `start-hyprland` relaunched
  it with `--safe-mode`. The rescue script then judged "the desktop draws" and said nothing to do.
- Fix 1: `m5pro-rescue status` now reports SAFE MODE (rc 3) and `auto` restarts the session
  again (retries once). Installed on the MacBook; repo copy updated.
- Fix 2: `QT_QUICK_BACKEND=software` moved into `~/.local/bin/hypr-session` (exported before
  either session starts) so every launch path of the bar inherits it; `environment.d` and the
  user manager environment only covered uwsm launches. New session 11:56: Hyprland 58327 normal
  mode, quickshell 58394 with the software backend (it still holds the render node open; the
  blame-logging kernel will tell whether it submits work).
- Chrome stays GPU-enabled per Rolando; each Chrome fault still takes the compositor down until
  the recovery kernel (`j716s-daily-dcp-recovery2`) is tested. Evidence: `/root/wedge-1156`.

## 2026-11-08 12:08-12:19 UTC — GPU recovery kernel, first hardware run (daily-dcp-recovery2, PASS on the main question)

Kernel `7.3.0-g12c445fa5371` = daily-dcp + recovery patches 0001-0003 (`contrib/pending/gpu/recovery/`) + fault
patches 0001-0002 (`contrib/pending/gpu/faults/`), payload `daily-dcp-recovery2-test-20261108-55baf5ad.bin` (test
flags: `m5.selftest=1 watchdog.open_timeout=300`, VRR on). Booted first try at 12:02 UTC: DCP display, GPU render,
Hyprland pid 940. Stress 12:08:45-12:18:35 via `recovery-test.sh /usr/local/bin/stress-load.sh 590`: 3x vkcube,
glmark2-es2-wayland, two Qt Quick windows (GPU backend), a Chromium WebGL tab, with `fault-watch.sh` logging.

- **Hyprland survived the whole run (same pid 940), no crash report, swaps 1024 per 10 s after the load, no
  stuck page flip, no RCU stall.** Before these patches every recovery took the compositor down with ENODATA
  and, on the DCP daily, wedged the display.
- 3 GPU recoveries, all within 3 s at uptime 518-521 s, all with glmark2's 10-command queues in flight. Only
  glmark2 lost its device (EIO from the bounded path). vkcube x3, the QML windows, Chromium and Hyprland kept
  running. The remaining 9.5 min of load produced no recovery.
- **Cause, from the firmware's own record (new blame log): all three are reason 5, "DSF pause timeout: the GPU
  did not pause scheduling in time" (macOS restart reason 7).** The firmware blamed no queue; the fault
  registers are all zero, as before. This confirms the fault class H1 named in `faults/HYPOTHESES.md`.
  macOS writes the same 150 us bound (checked in the 27.x AGXG17X kext), so the next run tests whether a
  looser bound (`aurora.m5_pause_timeout_us=2000`) removes the faults or only moves them.
- Harness notes: the load script must live outside `/root` (the session user runs it; now `/usr/local/bin`),
  the baseline vkcube needs `--wsi wayland`, a `pkill -f` pattern inside an ssh command must not match its own
  shell (`[f]ault-watch.sh`), and check 4/5 of `recovery-test.sh` read FAIL by construction when the trigger is
  a load set (glmark2 is part of it). The swap baseline read 0 with vkcube alone and 1024 after (tracing
  enable order; not a display problem).
- Artefacts (Studio, private): `~/Work/agents/gpu-recovery/recovery2-recovery2/` (events, journal, test dir).
  Restore: the slot already held `daily-n1k-20261107-512a1c00.bin`; reboot into it at 12:20 UTC.

## 2026-11-08 12:24-12:41 UTC — same kernel with `aurora.m5_pause_timeout_us=2000`: zero recoveries (one run)

Payload `daily-dcp-recovery2-pause2000-test-20261108-08515814.bin` (same kernel 7.3.0-g12c445fa5371 and
flags as the 12:08 run plus the pause bound 2000 us; the driver logged "firmware scheduling pause timeout 2000
us" at boot). Booted first try at 12:26 UTC; same 10 min load 12:28:00-12:37:50 with `fault-watch.sh`.

- **0 GPU recoveries in 10 min** under the load that produced 3 (all "DSF pause timeout") at 150 us in the
  run just before. Hyprland pid 933 alive throughout, no crash report, no new page-flip error, no RCU stall,
  no client lost its device.
- One run each, and the 150 us run's three faults came in a single 3 s burst, so this is a strong lead, not
  proof. The firmware's own reason code and the parameter's effect agree with H1 (`faults/HYPOTHESES.md`):
  the GPU occasionally needs more than 150 us to pause scheduling on this machine, even though macOS ships
  the same 150 us bound (it may pause less often, or at different moments).
- The two "Cannot commit when a page-flip is awaiting" lines of each session are at session start (log lines
  599-600 of 2945 here), before any load, and the session draws afterwards; the recovery-test check only
  counts new lines, which is right. `recovery-test.sh`'s swap counter read 0 both before and after in this
  run (1024 after in the first run); the counter is unreliable as a display-health signal and the rescue
  tool's `draws()` has an arithmetic bug on it (fix pending).
- Artefacts (Studio, private): `~/Work/agents/gpu-recovery/recovery2-pause2000/` (events, journal, test
  dir, `wedge-p2000/` = Hyprland log + DRM state saved before the restore). Restore: `daily-n1k` written
  12:39, reboot 12:41 UTC.
- Next: build a real daily from this kernel (no test flags) with the 2000 us bound, promote it after a loop
  boot, re-enable GPU for the Electron apps, keep `fault-watch.sh` running during normal use to count any
  remaining recoveries and their reasons.

## 2026-11-08 12:43-12:58 UTC — daily-dcp-rec-p2000 promoted, then an OOM during the verifier (open)

`daily-dcp-rec-p2000-20261108-f185b487.bin` (kernel 7.3.0-g12c445fa5371, DCP + VRR, `aurora.m5_pause_timeout_us=2000`,
no test flags) booted first try at 12:45 UTC (probe: clean, 74 s), DCP session, pause bound logged. `hypr-dcp-verify`
ran at 12:47: 20 passed, 2 failed. During its glmark2 fullscreen step (uptime 113.8 s) the kernel ran out of memory:
48 GB total, 19 MB free, while the LRU/slab/shmem accounting held under 1.1 GB (active_anon 2 MB, file 2 MB, shmem
960 MB pinned, slab 28 MB, swap untouched), so about 46 GB sat in driver page/DMA allocations the OOM report does
not attribute. The OOM killer took uwsm, superwhisper, wireplumber, fcitx5, pipewire and the portals; Hyprland exited
without a crash report, `start-hyprland` relaunched it in safe mode, and the panel no longer updated afterwards
("nothing reaches the panel"; the two "Cannot commit when a page-flip is awaiting" lines are the usual session-start
pair, so this wedge is not the page-flip class). No GPU recovery in this boot. The session log shows four "drmModeAddFB2WithModifiers
unsupported and buffer has explicit modifiers / Failed to submit a buffer to KMS" groups, each after a swapchain
reconfigure to AR24 (the direct-scanout attempt for the fullscreen client), not a retry storm.
- Rate estimate: 46 GB over the glmark2 step, about 0.8 GB/s, which matches the 26.5 displayed frames/s the verifier
  measured times a 31 MB 3456x2234 framebuffer; working hypothesis: a per-displayed-frame leak in the apple-drm
  (DCP) path, introduced or exposed by recovery patch 0003 or by the fullscreen/direct-scanout attempt. Not seen in
  the two 10 min windowed stress runs on the same kernel, nor in the 05:28 verifier run on the daily without the
  patches.
- Per Rolando (12:53 UTC): no revert while he is not using the machine. Rebooted into the same daily at 12:57
  (clean, MemAvailable 43.7 GB) for an observed reproduction (`leak-probe.sh`: glmark2 windowed, fullscreen with
  direct scanout off, fullscreen; MemAvailable, shmem, dma-buf bytes and framebuffer counts per second, stop at
  12 GB). Analysis agent on the apple-drm commit path in parallel.
- Evidence (Studio, private): `~/Work/agents/gpu-recovery/oom-1254/` (dmesg with the OOM reports, the three
  session logs, DRM state, the verifier directory). Omarchy-side: the promotion runner was stopped before it turned
  the Electron GPU flags back on (still `--disable-gpu`).

## 2026-11-08 13:15 UTC — the 12:47 OOM explained: a Hyprland direct-scanout retry storm, not the kernel

Analysis of the dead session's log and the OOM report: 1557 "GBM: Allocated a new buffer" lines (519 swapchain
reconfigures x 3) and 260 modesets; each buffer 30883840 bytes = 48 GB, matching the 47 GB missing; Hyprland's
accepted fds grew from 131 to 1659 (one dma-buf fd per buffer, never released); the memory came back when the
process died; the scanout objects are apple-drm dumb buffers (`drm_gem_dma_create` -> `dma_alloc_wc` through the
DART), which no /proc/meminfo bucket counts. Mechanism: the fullscreen zink glmark2 offered a tiled buffer for
direct scanout; with `AQ_NO_MODIFIERS=1` aquamarine cannot add it ("drmModeAddFB2WithModifiers unsupported and
buffer has explicit modifiers", 4 times = once per client buffer, then cached), but Hyprland 0.57.1 keeps the
candidate and reconfigures the swapchain to AR24 and back to XR24 with a modeset on every client frame: six new
31 MB buffers per frame at 5-9 GB/s, the replaced ones never freed. The 26.5 displayed fps was a symptom (a
modeset per frame). Windowed and composited clients never become candidates, which is why the stress runs and the
later probes were flat; the storm also needs an idle cursor, which the untouched first session had.
- Patch 0003 (bounded fence wait) read line by line against the tree: no double swap, no skipped cleanup; the
  recovery and faults patches never ran a recovery in that boot. The 05:28 "good" verifier run used native GL,
  not zink, so it was not a kernel comparison.
- Fix (commit e62e3db): `hypr-gpu-session` exports `M5PRO_DCP_DIRECT_SCANOUT=0` whenever it runs aquamarine
  without modifiers, `m5pro-dcp.lua` reads it, `hypr-dcp-verify` fails on more than 4 swapchain reconfigures
  during glmark2. Direct scanout was never reachable on this path (blockedBy CANDIDATE on every measured run), so
  nothing is lost; `/etc/hypr-dcp-modifiers` turns it back on. The buffer leak itself belongs upstream (Hyprland
  0.57.1 / aquamarine 0.16): replaced swapchain buffers are not released.
- Reproduction attempts on the same boot (glmark2 windowed, fullscreen with and without direct scanout, the
  verifier's own steps, the full verifier at 13:04 and at 75 s uptime, a 0.5 s-sampled run with the cursor hidden)
  all stayed flat with `directScanoutBlockedBy: CANDIDATE`; the storm did not re-arm after the first session.

## 2026-11-08 13:54-13:58 UTC — video observe boot 1: AVE encoder probe-only bind PASS, ProRes observer blocked by the kernel blacklist

`video-observe-test-20261108-c8c92158.bin` (kernel 7.3.0-g0933f881d736 = daily-dcp-rec-p2000 + the stack in
`contrib/pending/video/observe-test/SERIES.txt`; loader = the daily's + the AVE hand-off patch; test flags). Booted
first try (58 s, DCP + GPU, Hyprland up).
- **AVE (hardware encoder): rung (a) PASS.** m1n1 handed over the iBoot-preloaded firmware and recorded both
  segment checksums in `/chosen` (`aurora,ave-text-crc32 c25b4ddb`, `aurora,ave-data-crc32 d2223517`); the
  kernel driver bound to `2283100000.video-codec` and logged "probe only: firmware TEXT c25b4ddb DATA d2223517
  needs qualification"; `/dev/video0` = "Apple AVE video encoder" (v4l2-ctl); no DART fault, no SError,
  MemAvailable unchanged. These checksums identify firmware build 9013.55.1 for Aurora's command-layout table.
- **ProRes observer: not run.** `module_blacklist=apple_prores` on the command line makes the kernel refuse
  even a manual `modprobe` ("Operation not permitted"), unlike a modprobe.d blacklist. The engine node is in the
  DT and sits unbound (`48d000000.video-codec`, status okay, no driver). Second boot queued with the same kernel,
  no kernel-side blacklist, a modprobe.d blacklist on the root instead
  (`video-observe2-test-20261108-8e71e548.bin`).
- Artefacts (Studio, private): `~/Work/agents/video-observe/observe-20261108-1354/`.

## 2026-11-08 14:01-14:08 UTC — video observe boot 2: ProRes engine observed (PASS)

`video-observe2-test-20261108-8e71e548.bin` (same kernel 7.3.0-g0933f881d736 and loader, no `module_blacklist`;
a modprobe.d blacklist was placed on the root instead). Booted first try (59 s). The observer bound at 2.6 s
(it loaded at boot despite the modprobe.d entry, which is fine for an observation): "observing the ProRes
engine: irqs 113 114, aux window present"; **id 0x00040018**; mode, irq_enable, irq_status, st0, st1 and the
five ring registers all 0; "observation only: no V4L2 device registered". No DART fault, no SError; the
engine powered through `ps_scodec` and back down. Both video blocks have now passed rung (a):
- AVE: firmware handed over and bound, TEXT c25b4ddb / DATA d2223517 (build 9013.55.1), `/dev/video0`.
- ProRes: `apr,n0` engine identity 0x00040018 read once at reset state.
Next for both: hand the identifiers to Aurora (AVE command layout for 9013.55.1 and the T6050 boot identity;
ProRes n0 tunables/descriptor), then rung (b). Artefacts: `~/Work/agents/video-observe/observe-20261108-0901/`.

## 2026-11-08 14:19-14:29 UTC — daily-dcp-rec-video promoted (video blocks carried in the daily)

`daily-dcp-rec-video-20261108-26ca25f0.bin` = kernel 7.3.0-g0933f881d736 (daily-dcp-rec-p2000 + the video observe
series: AVE node probe-only, ProRes engine node + observer, `t6050-media.dtsi`, bindings) with loader
`m1n1-plain-n1-dt-gpu-dcp-phfix-ave` (the daily's + the AVE firmware hand-off), no test flags, VRR on, pause bound
2000 us. Built by `mk-daily-video.py` (observe-test tools). Booted first try (clean, 58 s). Verifier **23 passed,
0 failed, 1 warning** (first fully clean run today). AVE bound probe-only with `/dev/video0`; ProRes observer id
0x00040018 again. `boot.bin.prev` unchanged (daily-n1k-test 5c74c66c).
- The AVE DATA segment checksum differs per boot (d2223517 twice, 73cbcb65 now) while TEXT stays c25b4ddb: iBoot's
  preloaded DATA carries per-boot content, so any firmware-layout table must key on the TEXT checksum only.
- Power: 18.7 W total system a minute after the verifier, load 1.0 with a terminal and the text-effects tool busy;
  not an idle figure. Settled idle to be compared against the 9.8 W baseline during normal use (the encoder's
  power domain is kept on for its DARTs; if idle rises, the AVE node goes back to disabled in the next daily).
- Restore target for test runners is now this payload; `fault-watch.sh` runs for the boot under
  `/root/fault-watch-daily/`.
- 14:30-14:35 UTC power follow-up on daily-dcp-rec-video: all `venc0_*` power domains read **off** in
  `pm_genpd_summary` (the encoder's domain is not kept on after the probe-only bind), so the AVE node costs no idle
  power; the SMC "Total System Power" swung 19.3 W -> 15.0 W within two minutes at load 0.1-0.2 with the panel at
  brightness 570, the same band the previous daily showed (15.0 W at 14:14). The 9.8 W README figure is a dimmed
  idle from an earlier day; a like-for-like idle series (panel level fixed, 10 min) is still to be taken. The
  AVE driver has no unbind attribute (sysfs write refused), so the A/B was by domain state, not by unbinding.

## 2026-11-08 14:40-14:48 UTC — hv27 rung (i): the rebased hypervisor-era m1n1 boots the daily (PASS)

`hv27-plain-selftest-20261108-8117f8a9.bin` = the daily (kernel 7.3.0-g0933f881d736) with loader
`m1n1-hv27-plain` (v2.0.0-132-g63e6053c: our series rebased onto Asahi `m5-hv` 2e685f21 + main up to 8c22e3c5;
SPRR patches 0009-0011 dropped as upstream covers them; SEP RNG query skipped on T6050; T6050 added to the hv
CPU-start table; AVE hand-off adapted; size 0x430000). Before the boot `boot.bin.prev` was set to the current
daily (26ca25f0), so every fallback now lands on it. Booted first try (58 s, primary slot), DCP session, GPU,
Hyprland; stage-2 log: "SEP: Preserving iBoot warm registration; seeding RNG from ADT", "FDT: KASLR seed
initialized" (the old "couldn't get enough random bytes" line is gone), still "MCC: Unsupported version:mcc,t6050".
Daily restored as boot.bin (26ca25f0, prev 26ca25f0), one clean boot after.
- The rescue tool reported "nothing reaches the panel" on the hv27 boot while 311 swaps were counted in 4 s with
  a forced window: the test tools leave the top-level trace instance's `tracing_on` at 0, so the rescue's
  counter never moved. Fixed (`swaps()` turns tracing on) and installed; it now reports the live desktop.
- Guest-file fetch for rungs (ii)/(iii): no APFS tooling on the root (`apfsprogs`/`linux-apfs-rw-dkms` exist in
  the Arch repos; the DKMS module would need headers for the custom kernel). The fetch script also runs on
  macOS, so the files come out of the Preboot volume at the next macOS boot.
- Next daily payload prepared: `daily-dcp-rec-video-hv27-20261108-c7f84366.bin` (same kernel, hv27 loader as
  the daily loader; identical bytes to the agent's `hv27-plain-test`), to promote at the next attended slot.
- Rungs (ii) and (iii-a) wait for the Studio-to-MacBook cable (Rolando away from home); plan in
  `contrib/pending/hv/PLAN-27.3.md`.

## 2026-11-08 15:50 UTC — upstream: PRs #1240-#1243 opened on aurora-silicon/linux (GPU recovery, fault blame)

See `contrib/validated/aurora/prs/REPORT.md`. Studio note: five sparsebundle build volumes (`linux-cs-gpurec`,
`linux-cs-capture`, `linux-cs-aurprs`, `linux-cs-hdr`, `linux-cs-sep`) became unreadable (APFS ENXIO) while four
container kernel builds ran at once (host `kern.maxfiles` pressure: each VM holds 60-110k fds); `kern.maxfiles`
raised to 1572864; the agents finished their builds from `git archive` inside the containers. The images need a
detach and re-attach (journal replay) once the running builds end; payloads live under `~/Work/agents/`, not on
those images. Rule from now: at most two concurrent container kernel builds.

## 2026-11-08 19:37-19:50 UTC — hv27 rung (ii): stage-2 USB proxy over the Studio cable (PASS); GICv3 virtual CPU interface confirmed

Rolando home, Studio-to-MacBook cable in place. `m1n1-hv27-proxy.bin` (3ea65595, bare loader, no payload) written to
`boot.bin` with `boot.bin.prev` = the daily (26ca25f0); `run-hv27.sh smoke` listening on the Studio; `systemctl reboot`.
- The proxy device (1209:316d) appeared on the Studio 70 s after the reboot command; smoke identified
  `m1n1 v2.0.0-132-g63e6053c base 0x10004270000 chip 0x6050 board 0xc` and disarmed the stage-1 watchdog (ctrl 0x0).
  Console: `Primary WDT left armed (m1n1.wdt=keep)`, `No valid payload found`, PIPE parked on all three
  `usb-drd` controllers (MUX_CTRL 0x42), `Running proxy...`. The gadget is active on every port, so the cable's
  port does not matter for the proxy. Rung (ii) PASS; nothing left m1n1.
- Read-only probes from EL2 while in the proxy (`contrib/pending/hv/tools/gic-probe.py`, `ich-probe.py`):
  `ID_AA64PFR0_EL1` = 0x1101000010110111 (GIC field 0, EL2 present, no EL3), `ID_AA64MMFR1_EL1` VH=1,
  **`ICH_VTR_EL2` = 0x90580007** (8 list registers, 5 priority bits, 5 preemption bits, SEIS=1, no GICv4, TDS=1),
  `ICH_VMCR_EL2` = 0xf84c0008, `ICH_ELRSR_EL2` = 0xff, `ICC_SRE_EL2` = 0xf, `ICC_SRE_EL1` = 0x7; the physical
  `ICC_*_EL1` registers are undefined at EL2 (trap). The T6050 therefore has the GICv3 **virtual** CPU interface
  without a GIC, the M1 pattern Linux KVM relies on.
- EL1 test (`icv-probe.py`, proxy `el1_call`): with `ICH_HCR_EL2.En` = 0 the EL1 reads of `ICC_CTLR_EL1` (0x4400)
  and `ICC_SRE_EL1` (0x7) already succeed; with En = 1 every `ICC_*_EL1` read from EL1 reaches the virtual
  interface: PMR 0xf8, IGRPEN1 0, IAR1 0x3ff (spurious), BPR1 3, RPR 0xff, IAR0 0x3ff. After writing a pending
  group-1 virtual SPI 40 into `ICH_LR0_EL2` and enabling group 1 from EL1, the proxy stopped answering: the
  virtual IRQ was taken at EL1 inside the proxy's EL1 call, where m1n1 has no IRQ handler. That is the expected
  behaviour of a working virtual interface, and a tooling mistake (the ack sequence must run with PSTATE.I set or
  inside a real guest). Watchdog disarmed -> power-hold needed; the next boot is the daily from the fallback slot.
- Guest files for rung (iii-a) (SPTM, TXM, Exclave bundle, trust caches) are not on the Studio (only the kernelcache
  is); they sit in the Preboot `restore/` folder on the MacBook. Plan: `apfs-fuse` as an Arch ARM package
  (`~/Work/agents/hv27/apfs/build.sh`; the agent's classifier blocks external-source builds, Rolando runs it),
  read-only FUSE mount of the Preboot volume on the daily, `fetch-27.3-guest-files.sh`, then back into the proxy.

## 2026-11-08 20:08-20:30 UTC — proxy recovery (fallback semantics learned); hyprland-m5pro installed

- After the wedged proxy session Rolando power-cycled the MacBook: every boot came back into the proxy loader
  (`boot.bin`), unplugged too. Cause: the stage-2 m1n1 resets the PMU boot-failure counter at its own init, so a
  power-hold (which does not count as a failed boot) leaves the counter at 0 and the stage-1 keeps choosing
  `boot.bin`. A **watchdog reset does count**: when a chainload attempt wedged the proxy (two attempts; the stock
  `chainload.py` places the 42 MB image at m1n1's base, which the M4+/M5 CTRR check refuses, and a copy with a
  `--base 0x10011a00000` placement hung the proxy mid-upload), the stage-1 WDT fired 150 s later and the stage-1
  booted `boot.bin.prev` = the daily (`slot=fallback-after-failure`, pmu scratch 300130). Rule: to leave a proxy
  session, let the watchdog fire (or wedge it); do not power-hold. `run-hv27-recover.sh` (agent dir) then put the
  daily back into `boot.bin` over SSH (boot.bin = prev = 26ca25f0). Chainloading a full daily payload over the
  proxy remains unsolved (placement + upload hang); not needed while the watchdog path works.
- `hyprland-m5pro 0.57.1-1` (direct-scanout failed-candidate latch, `contrib/validated/desktop/hyprland/`) installed
  with `pacman -U` (stock package kept in the pacman cache for rollback), `hyprland` added to the IgnorePkg line,
  session restarted via `getty@tty2`. `hyprctl version` shows the m5pro-ds-latch build. First look said "display
  wedged": a fresh idle session with no client produces no frames (one swap after the modeset, two benign
  "Cannot commit when a page-flip is awaiting" lines at start-up), and `hyprctl dispatch` on 0.57 wants the Lua
  call syntax, so the forced redraws never ran. With a client animating (the screensaver) 735 swaps in 4 s, rescue
  "the desktop draws". Follow-up: make `m5pro-rescue`'s draws() force damage with the 0.57 dispatch syntax so an
  idle session is not reported as wedged. `hypr-dcp-verify` run on the new package follows.
- 20:20-20:26 UTC `hypr-dcp-verify` on hyprland-m5pro: **22 passed, 0 failed, 2 warnings** (idle desktop flipping 343×/3 s
  = the Omarchy screensaver client was animating; no direct scanout for fullscreen mpv = blocked by USER, the launcher's
  `M5PRO_DCP_DIRECT_SCANOUT=0` under `AQ_NO_MODIFIERS`, as intended). glmark2 swapchain reconfigured 0 times. The latch
  package behaves like stock with scanout off; re-enabling direct scanout for a test of the latch itself is a later item.

## 2026-11-08 20:28-20:41 UTC — hv27 rung (iii-a): macOS 27.3 guest files fetched; SPTM/TXM/XNU start, all 18 cores enter the guest

- Guest files: `apfs-fuse` built as an Arch ARM package (Rolando ran the build; upstream needed `#include <cstdint>` for
  GCC 16 and a non-fatal container-keybag failure, the 27.x FileVault keybag format is unknown to it while Preboot
  itself is unencrypted). Preboot (volume 1 of the main container, apfs-fuse exposes it under `root/`) mounted
  read-only on the daily, `fetch-27.3-guest-files.sh` produced the tarball (558 MB), `run-hv27.sh prep` unwrapped
  SPTM, TXM, cL4 bundle (DNUB), Exclave trust cache and integrity catalog, kernelcache = the installed BootKC =
  derived kc.macho (26C5035r). All checks ok.
- Proxy loader back on `boot.bin` (prev = daily), reboot; `run-hv27.sh guest nodisk` with `HV27_WDT=keep`
  (hv tick and proxy requests pet the stage-1 watchdog). Runner fixes along the way: empty bash arrays under
  `set -u` on macOS bash 3.2, Preboot index parsing, apfs-fuse `root/` prefix.
- run_guest: ADT node `/arm-io/ans/iop-ans-nub` removed, SPTM/TXM/cL4 images and the 2 GiB SPRR pool placed
  (`RESERVED SPRR POOL` 0x10024688000-0x100a4688000), ADT uploaded, jump to 0x10021704388 at 20:35:23. Then PMGR
  reads/writes from the guest (power-state registers at 0x280600208, 0x2809002xx, 0x2883001xx, logged as
  "Dangerous write"), `hv_sprr` table-attribute notices, and **CPUSTART writes for all 17 secondaries**, each
  accepted (`HV: Entering guest secondary N at 0x10021704000`, cores 1-17). `hv_amcc: no amcc-metadata in
  error-handler, not hooking AMCC IRQs` as expected (our 0008).
- After CPU #17 (≈20:36) no further output: no guest serial text at all, although the hypervisor maps the virtual
  UART on `/arm-io/uart0` (present in the J716s ADT at 0x305200000) and points `defaults/serial_device` at it. The
  hypervisor itself is alive (watchdog kept, no reset for 5+ min). The run was launched non-interactively (nohup), so
  the hypervisor shell is not reachable in this session; next run goes through `run-hv27-tmux.sh` (tmux) so Ctrl-C
  and the shell work. Open: where XNU's console went (panel in verbose mode? dockchannel?), whether the guest is
  spinning or waiting for the root device.

## 2026-11-08 20:47-21:30 UTC — hv27 rung (iii-a) runs 2-5: what the guest does after the CPU starts

Panel observations by Rolando (the guest owns the display after `Shutting down framebuffer`): with `serial=3` XNU's
verbose text runs up to **"initializing serial KDP"** and stops there (runs 1, 2 and 4); no Apple logo. Nothing ever
arrived on the hypervisor's virtual UART (mapped on `/arm-io/uart0`, `defaults/serial_device` pointed at it), so
after XNU moves its console to serial we are blind.
- Run 3 (shell first, watchdog kept): the stage-1 watchdog is not fed while the hypervisor shell is idle; it reset
  the machine as the guest started. Shell-first runs need the watchdog disarmed.
- Run 3b (dockchannel UART traced in SYNC mode): the guest faulted at its first instructions (vector 0x200, VBAR not
  yet set), which the untraced runs never did; synchronous tracing of that UART breaks the guest's firmware, which
  uses it for its own console. Do not trace it.
- Run 4 (`--strip-node dockchannel-uart`, `serial=3`): identical to runs 1/2 (all 18 cores, panel stops at serial
  KDP, nothing on the virtual UART). So XNU's serial output does not simply go to the dockchannel; the suspicion
  is now XNU hanging in the uart0 driver init against the emulated UART.
- Run 5 (`serial=0`, node stripped): watchdog reset after one secondary start, no client attached (the tmux server
  the client ran in had died), so no exception context. Single data point.
- Tooling: a running hypervisor does not answer a new proxy client once the first one is gone, and the hypervisor
  keeps the watchdog fed while the guest runs, so a headless guest can only be ended by a power-hold. The tmux
  wrapper was replaced by a pipe-driven runner (`run-hv27-fifo.sh`) whose client survives the agent's tool calls.
- Run 6 (`serial=0`, dockchannel node kept, otherwise = runs 1/2) in progress: the panel is the console.

## 2026-11-08 21:31-21:40 UTC — **hv27 rung (iii-a) PASS: macOS 27.3 boots into IOKit under the m1n1 hypervisor on the J716s**

Run 6 = runs 1/2 minus `serial=3` (`HV27_ARGS="-v debug=0x14e wdt=-1"`, dockchannel node kept, watchdog kept,
pipe-driven client attached). Guest entry 21:32:39, all 17 secondaries entered within a minute, hypervisor quiet
after that. Panel (photographed by Rolando at ~21:38): XNU verbose boot deep in IOKit matching: the Exclaves
section, `AppleA7IOPNub` nubs, `RTBuddy(ACIO1)` / `RTBuddy(ACIOPHY0)` start (Thunderbolt coprocessor firmware
dated Oct 30 2026), `ApplePMGR: Started AppleT6050PMGR`, `[uart] Started AppleSerialShim`, `AppleCLPCv3 start`,
`AppleS5L8940XI2CController` i2c1/2/3/5/7/8, `AppleHPMARMSPMI` register-length warnings, `AppleHPMInterfaceType10/11`
starts, `AppleTCControllerAssignableTransport::probe failed` (expected: the proxy port's Type-C chain is stripped),
`admac-leap-s` / `admac-dispext1/2` ("Running on silicon"), `kpc: pm registered pmc_mask=0x7`.
- So the earlier stop at "initializing serial KDP" was XNU hanging while moving its console to the hypervisor's
  emulated uart0, not a boot failure. Until the virtual UART is fixed, the guest console is the panel; the
  hypervisor-side tracers (rung iv) do not depend on it.
- Expected end state of this run: a wait for the root device (ANS stripped). Everything the guest touches is real
  hardware passed through by the hypervisor; no SSD, no APFS, no xART.

## 2026-11-08 21:38-22:20 UTC — hv27 rung (iv) first attempts: tracing under SPTM emulation does not take yet

- Runs 7-10 (clean clients, `serial=0`): the guest reaches the DCP display stack (panel: `IOMFB: service matched
  AppleDCPExpert`, `AppleDCPLinkService` pipe 0 with firmware hash crc32 0x22783959, `UnifiedPipeline::start_ios_gated`
  "Created AP Services" and the pending HPD notification, Thunderbolt NHI `unpoweredStart`, USB-C port 3 registration,
  `AppleFileSystemDriver: using apfs-preboot-uuid`). Two stale-client failures in between: a client from an earlier run
  still held the proxy serial port; the runner now kills stale clients.
- Tracers installed before guest start (SEP + ESM group, earlier the dockchannel UART) fault the guest's first stage
  at its first instructions; the same guest boots without them. Tracers installed live after SMP bring-up (SEP/ESM,
  then DCP mailbox in SYNC mode while the DCP driver was visibly starting) apply on the client side (`dirty_maps`
  clear, `pt_update` done) but produce zero events. Working hypothesis: under SPTM emulation the guest's device
  mappings are created by the emulated SPTM path and are not rewritten by a later client-side map change, while
  pre-start hooks are hit by the first stage before it has vectors. Handed to a code study
  (`~/Work/agents/hv27/TRACE-UNDER-SPTM.md` when done); no more blind reboots for this.
- Method notes (m1n1 shell `exec` is the assembler helper, use `builtins.exec`; `live-trace.sh`, `cycle.sh`,
  `run-hv27-fifo.sh` in the agent dir) are in `contrib/pending/hv/tools/README.md` once published.

## 2026-11-08 22:21-22:29 UTC — hv27 daily promoted; PMP dump retry pending

- `daily-dcp-rec-video-hv27-20261108-c7f84366.bin` (kernel 7.3.0-g0933f881d736 as before, loader `m1n1-hv27-plain`
  v2.0.0-132-g63e6053c, 0x430000) written to `boot.bin`; `boot.bin.prev` = the previous daily 26ca25f0. First boot:
  slot primary, 18 CPUs, card0 aurora + card1 apple-drm, Hyprland (hyprland-m5pro) up, rescue "the desktop draws".
  **Current daily = daily-dcp-rec-video-hv27 (c7f84366).** The hypervisor-era loader is now the everyday loader, so
  hv sessions and the daily share one m1n1 tree.
- The guest ended at 22:21 had reached `ApplePMPv2(PMP0) started`, `RTBuddy(DCP)`/`(SIO)` starts, AppleSmartIO, the
  admac channels, AppleEpochManager, dlil init (panel photos): macOS starts the PMP itself inside the guest.
- PMP window dump (Joshua, #293): attempted in a plain proxy boot between the two steps; the client connected 8 s
  after the device appeared and the proxy went away before the first chunk; to be retried with the runner's device
  wait (next proxy boot). Nothing was read.

## 2026-11-08 22:30-22:37 UTC — HDR ladder on the J716s panel (payload hdr-test 41539cf4, kernel 7.3.0-g7cf4279b444b)

Attended, Rolando at the panel; runner `~/Work/agents/hdr/run-hdr-test-v2.sh` (restore target = the hv27 daily c7f84366).
- Rung 0: with `appledrm.log_color_modes` the DCP firmware lists **one colour element only**, six times: depth 8,
  colorimetry 16, eotf 0 (SDR), range 0, encoding 0. No 10-bit or PQ element is offered by firmware 27.3 on this
  panel path, so there is nothing for an HDR mode set to pick.
- Rung a (10-bit SDR): Hyprland `bitdepth=10` -> swapchain XRGB2101010 accepted, scanout XRGB2101010; the DCP set no
  new link mode (link depth unchanged, so the panel link stays 8-bit; dithering by the pipeline at best).
- Rung b (HDR10): `cm=hdr` with the EDID overrides -> Hyprland asked, but zero HDR_OUTPUT_METADATA commit lines and no
  refusal: the fw-27 connector carries no HDR properties, as the HDR study predicted (gate unchanged).
- Rung c (EDR, `fw27_panel_edr=1`, experimental): peak brightness not reported (the A128 query stays unanswered, EDR
  stays off), 0 swap failures, no present storm; flag reverted.
- Conclusion: HDR10 on the internal panel is blocked at the firmware-offered colour elements, not in Hyprland. Next
  step for HDR is the hypervisor trace of macOS's DCP mode set when it enables HDR/EDR on this panel (rung iv, dcp
  group), to see which element/eotf macOS requests and through which call.

## 2026-11-08 22:45-23:45 UTC — hv27 rung (iv): live tracing installs, then the guest panics

Cycles with the proxy loader on the slot (prev = hv27 daily), pipe-driven client, tracers installed live:
- Install verified: `hv_pt_walk` shows the traced pages as trace descriptors (read+write flags set, invalid PTE) in
  ASYNC mode and as hook-type entries in SYNC mode; `hv.mmio_maps` carries the PrintTracer above the HW entry; an
  explicit `dsb ishst; tlbi vmalls12e1is; dsb ish; isb` added afterwards. HCR_EL2.VM = 1 and VTTBR_EL2 = the
  hypervisor's table on the running core. So the mechanism is in place.
- Zero events in every configuration: SEP+ESM after SMP (6 min), SEP+ESM+DCP after SMP (link lost after 2 min,
  guest still alive on the panel), DCP only, SMC only (ASYNC then SYNC, 100 s each), single-core guest (`cpus=1`)
  with SEP+ESM+DCP+SMC. The pre-start PMGR hooks produced their 44 events during early boot only (the registers
  they cover are not touched later), so they say nothing about the late phase.
- What the paused guest shows after a live install (single-core run): the PC does not move between pauses 20 s
  apart; the code there is `wfe; b .-4` with DAIF masked at EL1t, XNU's halt loop after a panic; `ESR_EL12` =
  0x02000000 (EC 0, "unknown reason") with `FAR_EL12` in the device-mapping VA range. So the first traced access
  after the install ends in a fault delivered to XNU rather than an emulated access, XNU panics, and any ASYNC
  events stay unflushed in m1n1's buffer. The two panel photos of traced guests stopping at the same 101 s frame
  fit this. Next: the panel's panic text (framebuffer read through the proxy) to name the driver and instruction,
  then the hypervisor's emulation path for that access form under SPTM emulation (study: `TRACE-UNDER-SPTM.md`).
- Tooling lessons: a stale client holding the proxy port corrupts the next session (runner kills them); a daily
  younger than ~60 s reboots into the fallback; `pkill -f` patterns must not match their own shell; the `exec`
  name in the m1n1 shell is the assembler helper.
- 23:41 UTC, framebuffer read through the proxy (the guest's panel as a PNG, `runs/shots/` in the agent dir): the
  single-core traced guest had **panicked**: `panic(cpu 0 caller 0xfffffe003e5588c8): Undefined kernel instruction:
  pc=0xfffffe003c4fc398 instr=d51ffb68 @sleh.c:1953` = `msr S3_7_C15_C11_3, x8`, in
  `com.apple.driver.AppleT6050CLPC` (deps AppleARMPlatform, ApplePMGR, IOReportFamily, IOSurface); "Exclaves boot
  status: NOT_STARTED"; last started kext IONVMeFamily. So that run died on an Apple implementation-defined system
  register the hypervisor does not virtualise in the `cpus=1` configuration, not on a traced access. The multi-core
  traced runs (stalled at the same 101 s frame, link lost) still need the same screenshot check. The screenshot
  method (`iface.readmem` of the boot-args framebuffer, 31 MB, ~20 s) replaces photos of the panel from now on.

## 2026-11-09 00:07-00:40 UTC — hv27 rung (iv): from-start tracers install cleanly; a traced DCP access hangs the guest silently

- From-start install works: `hv27-trace-late.py` arms itself on the SPTM AMCC hook; at SPTM's first AMCC read the
  three mailbox pages (SEP 0x502608000, DCP 0x48ae08000, SMC 0x28c608000) become ASYNC trace descriptors
  (`PT[...] -> ASYNC.RW PrintTracer`), no first-stage fault, all 18 cores enter the guest.
- Zero events again; tripwires (whole 0x88000 coprocessor windows unmapped, then their 0x20_0000_0000 aliases)
  never fired. Screenshots through the proxy 60 s apart are byte-identical: the console is frozen at
  `AppleARMBacklight::start: Pre-strobe iDAC=2046 default`, the line that precedes `IOMFB: service matched
  AppleDCPExpert` in every untraced guest. So the guest hangs at its first DCP mailbox access when that page is
  traced; the hypervisor keeps feeding the watchdog, prints nothing, and everything after that point never runs,
  which is why all later observation windows were empty. Consistent with a stage-2 trap on a secondary core
  deadlocking against the proxy core (study 2, F5 note on the big hypervisor lock and the USB ring).
- Client-side changes in the hv27 proxyclient: `msr S3_7_C15_C11_3` (CLPC, plus CRm 13/15 siblings) patched to NOP
  / `mov Xd, xzr` in the SPTM-emulation text patcher; `pt_update` brackets its TLBI with `dsb ishst` / `dsb ish;
  isb`; `handle_brk` no longer reflects a BRK into a guest without vectors; the runner waits 6 s after the gadget
  enumerates (connecting earlier corrupts the first request). Tools: `shot.sh` (panel screenshot via the proxy),
  `cycle.sh pre` (tracers from the `-m` module), `HV27_TRACE_MBOX_ONLY=1`.
- Running: the same from-start trace on a single-core guest (`cpus=1`), where the trap lands on the proxy core.

## 2026-11-09 00:49-00:56 UTC — **hv27 rung (iv) FIRST CAPTURE: SEP, SMC and DCP mailbox traffic of macOS 27.3 on the J716s**

Single-core guest (`cpus=1`, CLPC register patched), tracers on the three mailbox pages installed from SPTM's first
AMCC read. 52,666 MMIO events in the first three minutes: DCP 51,543 (51,337 of them one status-register poll at
+0x114 from one PC), SMC 709, SEP 397. Layout as on earlier SoCs: A2I send at +0x800/+0x808 (64-bit message +
info), I2A receive at +0x830/+0x838, status at +0x110/+0x114. The SEP receive words carry ASCII endpoint names
(`hibe`, `stac`, `cntl`, `xars`, `xarm`, ...): the SEP endpoint advertisement during AppleSEPManager's attach, the
protocol the Linux SEP driver (Touch ID rung a) has to speak. Capture (private, guest kernel addresses inside):
`~/Work/agents/hv27/captures/trace-cpus1-sep-dcp-smc-20261109-0050.log`.
- Root cause of the earlier silence, now proven: the same traps on a secondary core hang the guest silently (the
  multi-core traced guests froze at the line before IOMFB start); on the proxy core they work. Until the
  secondary-core trap path is fixed, rung-iv captures run single-core.
- Method summary: proxy loader on the slot (prev = hv27 daily), `cycle.sh pre` with `HV27_TRACE_LATE=1
  HV27_TRACE=<groups> HV27_TRACE_MBOX_ONLY=1 HV27_ARGS="-v debug=0x14e wdt=-1 cpus=1"`, screenshots via `shot.sh`.
- 00:5x UTC: that single-core guest panicked after ~3 min on a sibling register, `msr S3_7_C15_C15_0` (`d51fff08`,
  same CLPC family, different op2), after the USB-C port stage. The text-patcher rule now covers every op2 of
  `S3_7_C15_C{11,13,15}` (NOP / `mov Xd, xzr`). Second single-core capture cycle launched 01:01 UTC with the same
  three mailbox pages; tracer groups `pmp`, `sio`, `aop` added for later runs.
- 01:05-01:12 UTC capture cycle 2 (same three pages, widened CLPC patch): 53,905 events in four minutes, SEP again
  exactly 397 (the attach conversation is deterministic and complete), SMC 15,077, DCP 38,434; the guest passed
  both earlier panic points and settled in AppleCentauriManager's loop (CentauriControlDext launch timeouts, N1 warm
  resets, PCI configuration of apcie0: it waits for a DriverKit extension that needs userspace). Third study
  (`contrib/pending/hv/HV-SECONDARY-TRAP.md`): no secondary-core deadlock found in the hypervisor's trace path;
  keep captures single-core, treat the multi-core stall as a guest-level issue for later.

## 2026-11-09 01:20 UTC — decode of the first capture (SEP, SMC, DCP), `contrib/pending/hv/captures/`

- **SEP (Touch ID track):** no boot-ROM traffic; the AP sends one warm-registration message on endpoint 0xFE
  (`0x100005dc001c00fe`: size field 0x1c = a 0x1c000-byte table, IOVA inside the ADT-derived DART window). The SEP
  answers with the discovery burst on 0xFD: hibe 0x14, stac 0x18, cntl 0x00, xars 0x10, xarm 0x13, pnon 0x15, hdcp
  0x0e (seven endpoints, 17 messages); inside it the SEP sends an xarm QUERY_PROTECTED (opcode 0x0e) that macOS never
  answers in the window. Then GET_ENTROPY (tag 8), OOL buffers per endpoint, a SECMODE exchange, hdcp (OOL + 14
  steps), stac (echo), xars (OOL + one message). Formats match the Linux rung-(a) plan; **the table size does not**
  (our T6050 profile clones T6040's 0x40000; macOS registers 0x1c000) and must be fixed before the rung-(a) boot.
  sbio/skdl/sse/scrd/sks never appear in the window (no root volume). macOS uses low tags, no NOP probes.
- **SMC:** standard RTKit v12 bring-up, then endpoint 0x20 INITIALIZE, `#KEY`, `NTAP` write, `RGEN`, key walk.
- **DCP:** standard RTKit boot plus syslog/oslog/ioreport/kdebug; the AP starts endpoint 0x37 (IOMFB) and sends 18
  mgmt type-0xf messages; the firmware consumes them and never answers; the 0x27701 poll = I2A empty. m1n1's own
  path sends SET_SHMEM on 0x37 first and waits for INIT_COMPLETE; macOS does neither here. Open: why the DCP
  firmware does not respond under the hypervisor (state left by the loader's DCP hand-off, or a missing step).
- Guest PCs are the shared `AppleASCWrapV6` inbox/outbox/status primitives (resolved against the 27.3 kernelcache).
  Tool: `mbox-decode.py LOG [--dev sep|dcp|smc] [--polls]`.
- 01:18-01:24 UTC capture cycle 3 (`pmp,apr`, mailbox pages): **PMP 21,585 events** in 3.5 min (~3,500 messages each
  way: RTKit bring-up then continuous traffic, the power-management handshake Joshua asked about in #293 and the
  basis for our floor work); ProRes `apr0` only 3 register touches (probe only, no workloads without userspace).
  Capture private, decode running. Cycle 4 (`ave`, `n1` = apcie0 root-complex registers) launched 01:24 UTC.
- 01:29-01:36 UTC capture cycle 4 (`ave`, `n1`): N1 PCIe root complex (apcie0 registers) 1,127 events in four
  minutes, the port's link/PHY register sequence AppleCentauriManager runs around its chip resets (the training our
  Linux N1 port lacks); AVE 235 reads of its power/clock bank (probe only). Capture private; decode queued. The
  rung-(a) SEP payload was rebuilt with the 0x1c000 table (`sep-a2-test-20261108-fb200ca2.bin`, kernel-only change).
  Cycle 5 (`aop`, `sio` mailboxes) launched ~01:37 UTC; a study on the unanswered DCP IOMFB endpoint is running.
- 01:40 UTC PMP decode (`contrib/pending/hv/captures/DECODE-PMP-20261109.md`): endpoint 0x20 speaks the protocol of
  m1n1's `pmp_init.py` (GET_IOVA_TABLE, MALLOC/FREE, SET_BUF, ADVERTISE, SET_VAL); the PMP is the sole requester
  (3,063 each way), the AP serves `iop-pmp0-nub` ADT properties and an IOReport buffer; no AP-originated voter or
  floor commands in the window; no SET_IOP_PWR (PMP already running); no oslog endpoint (ep 7 instead). The report
  region is the PTD aperture 0x284240000, whose offsets from the runtime ADT equal `apple_pmp_offsets_t6041`. The
  earlier "3 apr events" were the window registration lines: ProRes saw no accesses at all. Reply for #293 drafted
  (`~/Work/outreach-bodies/reply-293-pmp.md`), not posted. Next PMP capture: PTD window + PMC.
- 01:40-01:47 UTC capture cycle 5 (`aop`, `sio` mailboxes): zero events in six minutes while the guest reached its
  usual end state (N1 manager loop): the AOP and SIO coprocessors are not started in a guest without a root volume
  (their drivers come after userspace/Exclaves). Nothing to capture for audio/sensors in rung iii-a; rung iii-b.
  Cycle 6 (`pmp` mailbox + `ptd` = the PMP report window 0x284240000+0x14000) launched 01:47 UTC.

## 2026-11-09 01:50-02:00 UTC — cycle 6 (PMP + PTD window), N1 decode, DCP under the hypervisor cleared

- Cycle 6: 146,611 events in four minutes: PMP mailbox 22,403, **PTD report window 124,211** (6,425 sweeps of the
  0x2630-0x2698 area, i.e. ~27 per second; first touches: reads of tgt_read 0x1e00 and status 0x10, a write of
  0x80000000 to tgt_write 0x10f00). Joshua's "how often" has a number now; decode queued.
- N1 decode (`contrib/pending/hv/captures/DECODE-N1-AVE-20261109.md`): port 0 links up on every attempt
  (INTSTAT LINK_UP latched, LINKSTS 0x9b001001); macOS brings it up three times in the window; teardown matches
  Linux `port_disable` step by step; 19 differences against m1n1 0023 / Linux `pcie-apple` listed (reset-table
  0x104 = 0xfffffff0, RID2SID and MSI-map clears, CGDIS clear before LTSSM, CGEN after link-up, lane bit 28 clear on
  all lanes, phy-ctl bit 26, three unknown blocks, no L2 requirement, N1 at bus 2). PERST/CLKREQ, SMC and ECAM were
  outside the traced windows (cycle 7 covers them). AVE: `ave0.reg3` is the die-1 PMGR power-state array; only
  VENC0_SYS is cycled, no firmware boot.
- DCP (`contrib/pending/hv/DCP-UNDER-HV.md`): the "unanswered IOMFB endpoint" was the CLPC-panicked run; the second
  capture holds the full IOMFB bring-up (SET_SHMEM, INIT_COMPLETE, 330 callbacks). The panel stays in verbose text
  because `-v` sets `video.display = 0`. Next: a shared-memory tracer behind `dva=0x10000044000` for the 27.3 method
  tags (HDR, colour elements).
- 02:03-02:10 UTC capture cycle 7 (`n1x`: ECAM 0x1cb0000000+0x300000, GPIO page 0x29c000000, PMGR APCIE chain, root
  complex): 9,711 events in five minutes: config space 1,832 (root port and bus 1/2), GPIO 5,034 (mostly polls of
  +0x118/+0x11c), PMGR chain 273, root complex 2,614. Capture private; decode queued (`DECODE-N1-DEEP`). Cycle 8
  (`acio` = Thunderbolt coprocessor mailboxes acio1/2/3) launched 02:10 UTC.
- 02:13-02:19 UTC capture cycle 8 (`acio` = acio1/acio2 reg0+0x8000): zero events; `acio,v2` is not an ASC-wrapper
  node, its mailbox is elsewhere in the 1 MiB window (to be located from the ADT/driver before another run).
  Cycle 9 (DCP RPC logger `hv27-dcp-trace.py`: mailbox page + DART register writes, payloads read from shared
  memory through a DART walk seeded from the ADT) launched 02:19 UTC via the v2 runner copies.
- 02:35 UTC PTD decode (`contrib/pending/hv/captures/DECODE-PTD-20261109.md`): correction to the cycle-6 note: there
  is **no periodic sweep**; 91% of the 126,847 accesses are one 6,425-iteration busy-wait on an MC command handshake
  (0x11220 = 0x1002, 0x11228 = 0x600000, acked by 0x2690 = 2). All five T6041 offsets behave as `pmp-report.c` says
  (status 0x10, tgt_read 0x1e00, tgt_write 0x10f00, actual 0x1e80, fast_die 0x2580). macOS writes 20 request words
  before PMP-STATUS is 1 (the driver's "no request before start" comment is wrong for T6050); request bit N = PMGR
  id1 - 1 (checked to id 37); no DRAM/fabric floor is requested through the PTD (bits 0-11 never set), the only
  performance-level write is DVFS entry 0x1f0 (levels 0..14, domain unresolved); a CLPC-to-SMC float feed ticks
  every ~98 ms; AP mailbox rate ~310 msg/s (earlier 17/s estimate wrong). Missing in `pmp-report.c` for T6050:
  update 0x10000, dvfs_first 0x1f0, dvfs_count 0x30, the MC command pair, SMC/PPM/CLPC channels, LTS-VOLT-CAP.
- 02:29-02:37 UTC cycle 10 (DCP RPC logger chained after the late module, ASYNC): installed cleanly at SPTM's AMCC
  read (mailbox page + DART register page; DART stream IDs 23/24, 4-level tables seeded from the ADT), decoded the
  whole RTKit bring-up of the DCP (SET_IOP_PWR 0x220, HELLO v12, EPMAP, STARTEP 2/3/4/8 then 0x37, 0x20-0x25,
  0x28-0x2d, 0x31; IOP_PWR_ACK; SET_AP_PWR 0x20), then `SET_SHMEM dva=0x10000044000 flag=0x4` and `INIT_COMPLETE
  0x0040227b39590101`. On the first IOMFB message the handler read guest memory through the proxy from inside an
  ASYNC event callback while the hypervisor delivered an exception event on the same channel: protocol desync
  (`Reply data sentinel error`), client stuck. Cycle 10 standalone (without the late module) faulted the first stage
  at entry: the standalone AMCC-hook arming is wrong, chain it after `hv27-trace-late.py`. Cycle 11 = same, mailbox
  tracer in SYNC mode (guest stopped while the payload is read), launched 02:38 UTC.
- 02:40 UTC deep N1 decode (`contrib/pending/hv/captures/DECODE-N1-DEEP-20261109.md`, 30-row checklist): the N1's
  own config space is never accessed in this guest (no endpoint driver without a root volume): ECAM traffic is bus 0
  only (root ports 00:00.0 N1 and 00:01.0 SD reader). macOS programs the root-port bridge window before any endpoint
  exists (prefetchable 0xb80000000..0xb820fffff, 33 MiB, 64-bit; the live-macOS BARs sit one 32 MiB step higher: open
  question), brings port 0 up three times (link-up on the first INTSTAT read after LTSSM start each time, LnkSta
  Gen1 x1, Gen3 target the first time only, never retrains, L2 never reached, then PERST# assert and teardown).
  GPIO confirmed from the ADT: PERST# pad 80 (+0x140), CLKREQ# pad 76 (+0x130); PERST# released by a plain
  0x76a03 write right after lane bit 10, two events before LTSSM start (our order matches); macOS rewrites all
  CLKREQ# pads 58..77 from ..21 to ..11 before RC init (we do not). The 2,195 "polls" are read-write-read rounds of
  an unchanged value on pads 68-71, 55% of all events, not N1 traffic. PMGR: no APCIE power-up writes, only the
  generic flag-clear + AUTO_ENABLE sweep; APCIE_* sit in auto-PM idle. Root-port DBI sequence matches the ADT
  tunables and m1n1 0023 / Linux `port_configure`; after link-up macOS adds PTM, LTR, AER clears, L1SS + ASPM L1,
  bus numbers (N1 = bus 2). PHY/AXI2AF tunables untouched by macOS (iBoot?). Next N1 capture needs a root volume.

## 2026-11-09 02:45 UTC — state at the end of the night's capture run

- MacBook: sitting in a dead hypervisor session (client lost after the ASYNC RPC handler desync; hypervisor keeps the
  watchdog fed and ignores new clients). Needs a power-hold; `~/Work/agents/hv27/runs/after-powerhold2.sh` is armed
  and restarts cycle 11 (DCP RPC, sync mode) by itself afterwards. Slot: boot.bin = proxy loader 3ea65595,
  boot.bin.prev = hv27 daily c7f84366 (the fallback after any watchdog reset is the daily; a power-hold boots the
  proxy loader, which waits for a client).
- Captures (private, `~/Work/agents/hv27/captures/`): SEP/SMC/DCP x2, PMP, PMP+PTD, AVE+N1, deep N1 (ECAM/GPIO/PMGR),
  AOP/SIO (empty), ACIO (empty), DCP RPC partial. Decodes published under `contrib/pending/hv/captures/`.
- Method (all in the agent dir, notes in `contrib/pending/hv/tools/README.md`): single-core guest, tracers from
  SPTM's first AMCC read (`hv27-trace-late.py`), groups sep/esm/isp/ave/apr/dcp/darts/smc/pmp/ptd/sio/aop/n1/n1x/acio,
  `cycle.sh pre` / `cycle2.sh pre` (v2 = with the DCP RPC module), `shot.sh` screenshots, `mbox-decode.py`,
  `ptd-decode.py`, `n1-ave-decode.py`. Client-side fixes: CLPC register family NOP, pt_update barriers, handle_brk.
- Open: multi-core traced guests stall (secondary-core traps), ACIO mailbox offset, DCP RPC payload capture (sync
  run pending), rung iii-b decision (root volume) for Exclaves/camera/N1 endpoint/userspace-driven DCP (HDR).

## 2026-11-09 02:43 UTC — **DCP RPC capture works (IOMFB method tags with payloads, firmware 27.3)**

After the power cycle the watcher attached the sync-mode DCP RPC run (single core, `hv27-trace-late.py` +
`hv27-dcp-trace.py`, mailbox page SYNC, DART register page ASYNC, payloads read from guest memory through the module's
own DART walk, stream IDs 23/24). 6,610 RPC records in the first two minutes, 0 handler errors, 3 untranslated
DVAs. Sequence after SET_SHMEM/INIT_COMPLETE: AP call `A451` (out 4), then DCP callbacks `D603`, `D107`, `D108`,
`D109`, `D110` (property queries, out 4), `D406` (in 72), `D414` x many (in 80, out 4), `D413` (in 4168, out 4),
`D415` (in 76), each acknowledged by the AP. Output: `DCPRPC:` lines in the run log and the JSONL in the agent's
captures directory (private; the decode and the resulting 27.3 method table go to `contrib/pending/dcp/`).
- 02:50 UTC: 17,900 RPC records, 0 errors. Tags: AP commands A136 A137 A353 A378 A379 A381 A385 A390 A391 A451 A503
  A504 A515 A526 A529 A534 (+ OOB A384 A400); callbacks D102 D107 D108 D109 D110 D126 D127 D128 D201 D401 D406 D408
  D413 D414 D415 D451 D552 D561 D563 D565; steady state = D300 (8,593 ASYNC + 162 CB) and D006. Decode into a 27.3
  method table running. Module hardened (ASYNC = words only, no proxy reads in event callbacks; SYNC = payloads;
  standalone arming equal to the late module; ASCII-only output) and published with the other tracer modules under
  `contrib/pending/hv/tools/`. Finding from the hardening study: the "first-stage fault at entry" (IABORT at 0x200,
  x0 0x20003) also occurs without any tracer module (3 of 25 guest starts tonight, right after `hv_amcc:`): an
  intermittent early SPTM BRK, now stopped at its real PC by the `handle_brk` guard for the next occurrence.
- 02:57 UTC: MacBook returned to the normal slot layout (boot.bin = hv27 daily c7f84366, prev = 26ca25f0), slot
  primary, Hyprland up. Final DCP RPC capture: 22,038 records (private; decode into the 27.3 method table running).
  Rung iii-b approved by Rolando; runbook published (`contrib/pending/hv/RUNG-IIIB-RUNBOOK.md`); preflight (installer
  availability for 26C5035r, container space, VG UUIDs) to run over Tailscale next time macOS is booted, ceremony in a
  daytime session. #293 reply posted (PMP/PTD findings).

## 2026-11-09 03:15 UTC — DCP RPC decode (`contrib/pending/hv/captures/DECODE-DCP-RPC-20261109.md`)

- Content: AppleDCP bring-up only (28 AP calls, 330 callbacks, 8,590 ASYNC `D300` notifications every 41 ms); no
  swap, no `set_digital_out_mode`, no brightness or EDR call (no WindowServer in a no-root-volume guest).
- Method table: the firmware-27.3 table already in our tree (`/Volumes/linux-cs/wt-dcp-27`, branch `dcp/27.3`,
  716bce007fd3) is **confirmed for 20 of its 41 tags** by tag and in/out lengths, nothing contradicts it; A526/A529/
  A534 fit 27.3 and not 27.2; every callback tag is already in Linux's 27.0 `cb_handlers[]` with identical sizes. New
  or unknown in 27.x: A378 (44/40), A379, A381, A384 and A400 (OOBCMD), A515 (`0x800, 0x20`).
- **HDR on the internal panel:** the firmware gives macOS exactly one colour element too (ID 1, 8-bit RGB, SDR,
  EOTF 0, colorimetry 16); all six timings (120/60/48/59.94/47.95/50 Hz, ID 2 = 120 Hz preferred) reference it. A
  PQ link is impossible on this firmware; HDR must travel as EDR inside the swap on the SDR link (inference, no swap
  captured). `D300` id 20 = 300 nits; 1600.0 appears under ids 25/117/118/261 (candidate panel-peak source replacing
  the A128 call Linux lacks on fw 27). A WindowServer capture (rung iii-b) settles it; the swap request is 4,420
  bytes, above the module's 4,096-byte payload cap (raise it).
- Cross-checks for the Linux DCP driver's stage C: `D408` sr_getClockFrequency('PROV', 0) = 810,000,000 Hz on macOS
  (Linux answers 0: the "EDT ERROR ... Giving up on frequencies" line); `D003` reply {0x286720000, 0} confirms the
  PMC + 0x20000 offset; `A534` returns 1 while `complete_dfb_surface()` treats non-zero as failure (candidate for
  "Creating default FB surface failed"); macOS's default surface id = 3 (Linux 5), buf_size 0x025ec000 matches
  `apple_dcp_dfb_allocation()`; macOS answers `D109` create_PMU_service with false (Linux true).
- Module bug: ack pairing must be LIFO per context (6 acks mis-paired, their return values lost); D127 property
  blobs exceed the payload cap (reassembled). Fix in `hv27-dcp-trace.py` before the next DCP run.
