# Aurora kernel on the J716s: current state and exact ingredients

**This file is the single source of truth for the Aurora payload ingredients** (it replaces
`pipe-park/STATE.md`, moved here with `git mv`). The newest boot is **R3-SERIES** (next section), built from the clean 58-patch series;
the canonical recipe for it is `series/SERIES.md`. R3-V, R3-R and R3-Q follow below, each as a delta on the one before
(they use the hand-assembled `aurora-j716s` branch).
Results and the boot tables: `../integration/RESULTS.md` ("Round R3"). Per-unit values (PHY tunables) are no longer
in the DT at all: m1n1 0021 fills them at boot.

# Current (daily with WFI idle, battery, SMC sensors and the right Type-C port, 2026-11-07 12:00 UTC)

`boot.bin` = `daily-20261107-dcec81ed.bin`: kernel `7.3.0-gf080637018df` (series + 0061 WFI override + 0062 PM_DEBUG,
soak and S1-S4 sleep tested) with the DTB of series 0059+0060, battery on, `kvm-arm.wfi_trap_policy=trap`, self-test
flag off. Idle on the charger 9.3 W (was 16.4 W). `boot.bin.prev` = the previous daily `275d84ec`.
Previous: `daily-20261107-275d84ec.bin` (series kernel `4f630b11270d`, same DTB).
Previous daily `ce3f10af` (battery only) was R3-S's promotion.
`boot.bin.prev` = R2-B `5091e1fe` (our 7.2 kernel). ESP: `boot.bin`, `boot.bin.prev`, `boot.bin.known-good` (audio
test payloads live on the Studio and are copied in for a run). Audio: mic works (A2), speakers boot safely but the first
tone faults the amps (B2); see `contrib/validated/integration/RESULTS.md`. Stage-1 is the A/B image (`chainload.fallback`, 150 s watchdog), slot reported as `primary`.

# R3-SERIES (2026-11-07), superseded as the daily by the battery build above

Payload sha256 prefix `8c8dd836`, booted by the self-revert loop (nobody at the machine) at about 10:10: network,
`card0-eDP-1`, trackpad (`Touch MT ready` at 1.34 s), `apple_idle`, `macsmc` bound through the native `apple,t6050-smc`
match, the CIO reset driver bound with its own T6050 entry, NVMe partitions at 0.37 s, no error lines after filtering
PMGR noise and the expected `pcie-apple` `-22`. **The exact recipe (patch list, config, DT, rebuild commands) is
`series/SERIES.md`;** this section only lists what goes into the payload.

| Part | R3-SERIES | Change from R3-X (= R3-V + simpledrm eDP) |
|---|---|---|
| m1n1 | `m1n1-plain-r2-pipepark-atc.bin`, sha256 prefix `28b26ebc` (`pipepark-atc`: 0020 + 0021) | none |
| Kernel | `7.3.0-g4f630b11270d`: the 58 patches of `series/patches/series/` on `aurora-silicon` `integration/aurora` `33bec4016c46` (worktree `wt-series`, branch `j716s-series`, tip `a83b052e9ffb`, re-authored 2026-11-07 to `Rolando Trevino <rolotrealanis@gmail.com>` with `Signed-off-by` and without assistant trailers; the content is byte-identical to `4f630b11270d`, which is the hash in the booted kernel version string). 0001-0044 are Aurora's commits carried as-is, 0045-0058 are ours | hand-assembled `aurora-j716s` branch replaced by the series |
| Config | `make defconfig asahi.config j716s.config` (16K pages), `RUST` off. `j716s.config` is `series/j716s.config` (patch 0058) | the config additions of R3-V/R3-X are now in the fragment |
| DT | the series' own source-form `arch/arm64/boot/dts/apple/t6050-j716s.dts` (patch 0057), compiled by the kernel build; `series/dt/t6050-j716s.dtb`, sha256 `8c4df67ac743a08b633f7e5233004180e5b18d9f82c56b9261ec76eb77458e6e`. Publishable, no per-unit values, no hand edits | source-form DT instead of the post-processed decompiled DTS. Differences from the old booted DTB: `series/dt/dt-diff.txt` |
| Driver fixes in the series | `apple,t6050-smc` match (0052), `apple,t6050-cio-reset` entry (0051: register `0x60`, the old `t8142` fallback used `0x30`), CPU order in `t6050-max.dtsi` (0054) | native matches instead of DT fallbacks |
| Initramfs | `initramfs-selftest.cpio.gz`, sha256 `ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a` | none |
| Bootargs | as R3-X: R3-Q's (below) incl. `initcall_blacklist=macsmc_power_driver_init` and `m5.selftest=1` | none |
| Seen on the console | `pcie-apple 1cb0000000.pcie: probe failed -22`: expected, the apcie0 port is untrained | none |

ESP layout (500 MB, prune `boot.bin.failed` after each self-revert):

| File | Holds |
|---|---|
| `boot.bin` | R3-SERIES (daily) |
| `boot.bin.prev` (the revert target) | R3-X |
| `boot.bin.b2` | B2 (our 7.2 stack) |
| `boot.bin.known-good` | known-good |

**Open points from the series work:** ask Aurora how their m1n1 boots J716c with the old CPU order; cpufreq
fallback (`apple,t8112-cluster-cpufreq`) against a `t6050` soc info; `dtbs_check` not run; `apple,internal-panel` on
simpledrm needs a binding patch; hwmon disabled in the DT until `F0md`/`F1md` are read; battery no longer blacklisted (R3-S).

**Attended queue** (details: `../integration/RESULTS.md`): R3-U (m1n1 0024 + opt-in DCP handoff), W0/W1/W2 Wi-Fi
(`../../pending/wireless/aurora-n1/R3-W-RECIPE.md`), R3-S battery, audio (`../../pending/audio/aurora/R3-AUDIO-RECIPE.md`: R3-AUDIO-A `a7c05d1a` mic and jack,
R3-AUDIO-B `34e96037` speakers; Rust kernel `00e8df6f` from tree `wt-aurora-audio` `1d2ac24c066e` = R3-X tree + 11
audio patches; `speakersafetyd`, `asahi-audio`, `alsa-ucm-conf-asahi` must be built with
`../../pending/audio/aurora/build-audio-pkgs.sh` before the speaker boot).

# R3-V (2026-11-07; the base of R3-X, the delta below is against R3-R)

Payload sha256 prefix `8864d45e`, booted by the self-revert loop (nobody at the machine). R3-T (`08902f08`) is the same
payload on kernel `6d9f1ec652a6`; R3-X (`734594ed`; R3-V + simpledrm eDP patch 0029 + `apple,internal-panel` on the framebuffer
node) booted and is `boot.bin.prev` behind R3-SERIES.

| Part | R3-V | Change from R3-R |
|---|---|---|
| m1n1 | `m1n1-plain-r2-pipepark-atc.bin`, sha256 prefix `28b26ebc` (full: `28b26ebcf91e11e512ef100aae0b3e66d174ebf8a380c243dea4763ae2459a33`), banner `v2.0.0-72-gf7555558` = `pipepark-atc` = stage 2 of R3-N + 0020 (PIPE park) + 0021 (ATC tunables from the ADT) | 0021 added (R3-R's `a28b1815` had 0020 only) |
| Kernel tree | branch `aurora-j716s`, tip `302945c1ecb3` = `6d9f1ec652a6` (R3-R) + PR #937 (PCIe) + PR #938 (T6050 centauri, 16 patches) | +PR #937, +PR #938 |
| Config | R3-R's, plus `SECURITY_LANDLOCK` (pacman's download sandbox), `ZRAM`, `PINCTRL_APPLE_GPIO`, `RFKILL`, `CFG80211`, `APPLE_CENTAURI`, `BT_HCICENTAURI`, `BACKLIGHT_CLASS_DEVICE` | the eight listed |
| DT | `contrib/pending/aurora/dt/t6050-j716s-aurora-decompiled.dts` (retired, see git history) (compiled `t6050-j716s-typec-fixed8-notun.dtb` (retired, see git history) next to it): fixed8 **without** the 14 `apple,tunable-*` lists; m1n1 0021 fills them (14 properties seen in the live DT on R3-T). Publishable, no per-unit values | fixed8 (per-unit) for the committed DT |
| Initramfs | `initramfs-selftest.cpio.gz` (DIAG block + self-revert service), the same file as R3-Q/R3-R: sha256 `ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a` | none |
| Bootargs | R3-Q's (below) incl. `initcall_blacklist=macsmc_power_driver_init` and `m5.selftest=1` | none |
| Seen on the console | `pcie-apple 1cb0000000.pcie: probe failed -22`: expected, the apcie0 port is untrained (m1n1 0023 is opt-in); harmless | new with PR #937 |

(ESP layout when R3-V was `boot.bin`: `boot.bin.prev` = R3-T; superseded by the layout under "Current (R3-SERIES)".)

# R3-R: trackpad (2026-11-07 about 01:45)

Payload sha256 prefix `b457425e`, booted by the self-revert loop. Recipe: `trackpad/R3-R-RECIPE.md` (retired, see git history); analysis:
`trackpad/ANALYSIS.md`.

| Part | R3-R | Change from R3-Q |
|---|---|---|
| m1n1 | `m1n1-plain-r2-pipepark.bin`, sha256 `a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46` | none (0021 still not in it) |
| Kernel tree | branch `aurora-j716s`, tip `6d9f1ec652a6` = R3-Q tree (`4504ef7485be`) + r3r 0001-0004 | +4 commits (35 above `aurora/integration`) |
| r3r 0001 | `HID: dockchannel-hid`: settle 50 ms after releasing the AFE reset, logs "multi-touch: AFE reset asserted/released" | the log lines are what proved the reset ran |
| r3r 0002 | `hwmon: (macsmc)` keep a fan whose optional keys are missing (port of our 0003) | inert at boot: hwmon is disabled in the DT |
| r3r 0003 | `power: supply: macsmc-power` initialise work items before the notifier (port of our 0004) | inert while the battery driver is blacklisted |
| r3r 0004 | `power: supply: macsmc-power` read battery identity strings at their key size (Aurora's `54b12371013e`, macsmc-power part) | the new candidate for the 7.8 s probe hang (R3-S) |
| Config | `HID_MAGICMOUSE=y`, `HID_APPLE_MTP_HAPTIC=n`, `HIDRAW=y`; the rest as R3-Q | **the trackpad fix**: magicmouse was `=m`, forced by the haptic driver `=m`, and no modules load. Cost: no click haptics |
| DTB | `t6050-j716s-typec-fixed8.dtb` = fixed7 minus the driverless `apple,smc-pcio-gpio` node. AFE reset unchanged: `<&smc_gpio_low 28 GPIO_ACTIVE_LOW>` on `input@8000`. Per-unit, not committed (`trackpad/mk-fixed8.py` regenerates it from fixed7) | fixed8 for fixed7 |
| Initramfs | `initramfs-selftest.cpio.gz`, sha256 `ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a` | none |
| Bootargs | as R3-Q, `initcall_blacklist=macsmc_power_driver_init` still on | none |
| Payload build | `trackpad/mk-r3r.py` (retired, see git history) (variants `ring`, `pcio`, `power`); it refuses a kernel without magicmouse, 0001 or 0002 | |
| ESP | `boot.bin` = R3-R; `boot.bin.prev` = R2-B (the revert target); `boot.bin.r3q`, `boot.bin.b2`, `boot.bin.known-good` | |

Not used: the `ring` and `pcio` fallbacks, and `trackpad/patches/optional-pcio/0005` (Aurora's pcIO GPIO line
2, same pin as gp1c). They were prepared in case gp1c failed; it did not.

**Pending on this kernel:** R3-S (R3-R without the battery blacklist, adds `panic=0 pause_on_oops=300
ignore_loglevel`), run only with Rolando present because a probe hang is not self-recoverable without the A/B
stage-1 watchdog; USB replug; Wi-Fi (PR #937 and the N1 firmware handoff); display driver (firmware-compat
gate); GPU (gated off); cpuidle beyond WFI (m1n1 `idle=nop`); m1n1 0021 so the DT carries no per-unit tunables.

# R3-Q: exact ingredients (the first working USB3 boot of the Aurora kernel on the J716s)

Payload `R3-Q-aurora-fwrestart-j716s-fixed7-pipepark-selftest.bin`, sha256 prefix `4083b7df`, booted
2026-11-07 about 01:00 by the autonomous loop. Result and analysis: `../integration/RESULTS.md`
("Round R3"), `pipe-park/ANALYSIS-R3O.md`, `pipe-park/R3-Q-RECIPE.md` (retired, see git history). Per-unit values (PHY tunables) are not in this repository.

| Part | What |
|---|---|
| m1n1 | `m1n1-plain-r2-pipepark.bin`, sha256 `a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46`: ccbb51bc (R3-N's stage 2, v2.0.0-71-gd956947e) plus 0020 (T6050 PIPE park). Same binary as R3-O. 0021 (ATC tunables from the ADT) is **not** in it |
| Kernel tree | `/Volumes/linux-cs/wt-aurora`, branch `aurora-j716s`, tip `4504ef7485be`: 31 commits on `aurora/integration` (`33bec4016c46`), listed below. Config as for R3-N (`make defconfig asahi.config`, 16K pages, boot-path drivers `=y`, `tools/README.md`) |
| DTB | `t6050-j716s-typec-fixed7.dtb`, sha256 `1eb0fcef30554d7f6873c03372466daa837c0d2af7bba8eb138f0d1323347d25`. Lineage: J716c DT (PR #945) -> j716s derived -> fixed6 (CPU order, compatible fallbacks, AFE reset line, Type-C chain; **no** PHY tunables) -> fixed7 (fixed6 plus the 14 combo-PHY tunables generated from this unit's ADT). Per-unit, not committed. R3-P would use fixed6 with m1n1 0021 instead |
| Initramfs | `initramfs-selftest.cpio.gz`, sha256 `ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a` (`tools/mk-selftest-initramfs.sh`: DIAG block plus the self-revert service) |
| Payload layout | m1n1 (0x400000 B) + `chosen.bootargs=` line + `chosen.asahi,show-notch=1` + `Image.gz` + DTB + initramfs (`mk-r3q.py` (retired, see git history)) |
| ESP | R3-Q as `boot.bin`, R2-B as `boot.bin.prev` (the revert target) |

Bootargs:
```
earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 initcall_blacklist=macsmc_power_driver_init m5.selftest=1
```
`m5.selftest=1` stays in the command line; it is inert while the network comes up within 90 s.
`initcall_blacklist=macsmc_power_driver_init` keeps the battery driver out (Aurora lacks our 0004 INIT_WORK fix and 0003 fan key).

## What changed from R3-O to R3-Q

Only the kernel: the three PHY commits at the top of the list below. They are Aurora's `j716c/thunderbolt`
commits `6f93def30893` (park the PIPE from a dummy producer on any clock), `e604b7f414b4` (carry on when the
PIPE lock is not acknowledged) and `b8f2be0fef93` (restart the PHY firmware on its original data), re-applied
here with `git am` from `pipe-park/kernel-r3q/` under new hashes. Recipe: `pipe-park/R3-Q-RECIPE.md` (retired, see git history).

## Kernel commits above `aurora/integration`

`git -C /Volumes/linux-cs/wt-aurora log --oneline aurora/integration..aurora-j716s` (newest first). This list is R3-Q's (tip `4504ef7485be`); R3-R's tip `6d9f1ec652a6` adds the four r3r commits above it.

```
4504ef7485be phy: apple: t6050: restart the PHY firmware on its original data
8cc14a33c4dc phy: apple: t6050: carry on when the PIPE lock is not acknowledged
b570d2d2002a phy: apple: t6050: park the PIPE from a dummy producer on any clock
da5a44d086e6 phy: apple: t6050: Accept every Type-C port but the debug port
96145a9c7a01 phy: apple: t6050: Stay on USB2 when the PIPE never left the dummy
dc5f10049de5 phy: apple: t6050: Enable the dummy PIPE PHY for the USB3 lock
40b26dfd67d0 usb: dwc3: apple: Add the bare-metal T6050 controller
68ed87930047 dt-bindings: phy: apple,t6050-dp-phy: Type apple,port-index as uint32
e12115750327 phy: apple: t6050: Hold the USB domain for the combo PHY's USB2 banks
6f385a16bc8f dt-bindings: phy: apple,t6050-dp-phy: Allow the USB domain on combo PHYs
160ea6b94c33 phy: apple: Add T6050 DisplayPort and USB combo PHY
d832ff2ffb0b dt-bindings: nvme: apple: Allow the boot loader's RTKit handoff on T6050
9fc7bc6a2626 nvme: apple: Add the T6050 ANS on bare metal
969fe7d59454 dt-bindings: nvme: apple: Add the T6050 ANS
0277c3399e1c soc: apple: sart: Add SARTv4 for T6050
581663e0d80c dt-bindings: iommu: apple,sart: Add the T6050 SART
4c77a4dae7e4 soc: apple: rtkit: wait up to 10 s for RTKit handshakes (T6050 ANS needs ~3 s)
6a6d7dfdc307 arm64: dts: apple: add t6050-j716s (MacBook Pro 16-inch M5 Pro), derived from j716c
116500d14b78 Merge branch 'aurora/pr-945-j716c-dt' into aurora-j716s
301c0e3ca376 arm64: dts: apple: j716c: Add the N1 on PCIe port 0
264b181bfe77 pinctrl: apple-gpio: Use the uncached regmap on T6050
73f8f630ae9e arm64: dts: apple: Add J716c (MacBook Pro 16-inch, M5 Max)
d7ca54c8c120 arm64: dts: apple: t6050: Add the PMU's power-on policy cell
deeb9b481082 dt-bindings: spi: apple,qspi: Add t6050
b0c7ed56f1c9 dt-bindings: iommu: apple,dart: Add the T6050 DART
50b1dd7f52f6 dt-bindings: watchdog: apple,wdt: Add T6050
9114ae0fbdf0 dt-bindings: interrupt-controller: apple,aic2: Add T6050
5fcc18040192 dt-bindings: arm: apple: Add the Mac Studio (M5 Ultra, 2026)
4416c03ef34e dt-bindings: mailbox: apple,mailbox: Add T6050 ASC mailboxes
3f32758b9afa arm64: dts: apple: Build the J775D device tree
265f24a3ebfe arm64: dts: apple: Add the J775D (Mac Studio, M5 Ultra) device trees
```

Landmarks: `6a6d7dfdc307` is the J716s device tree, `4c77a4dae7e4` is our 0016 (RTKit 10 s wait), the
NVMe/SART commits are PR #936, the combo-PHY and dwc3 commits are PR #939 plus Aurora's PIPE commits, and
`116500d14b78` merges PR #945 (J716c DT).

## 2026-11-07 17:00 UTC
- Daily: `daily-wifi-20261107-4feff24c.bin` = series tip `a0f2f30c967b` (87 patches) + m1n1 `n1-warm` (0020-0023, 0025-0027)
  + stitched-FTAB initramfs; chosen `n1=4`, `pcie_aspm=off`, battery on; rollback = its test twin `ee3d0dd8`.
  Every payload must carry the N1-aware m1n1 from now on (a loader without 0027 hangs once on a warm N1).
- Open on the daily: lid sleep confirmation on this kernel, speaker listening check, netconsole path (double NAT).

