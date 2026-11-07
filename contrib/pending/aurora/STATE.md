# Aurora kernel on the J716s: current state and exact ingredients

**This file is the single source of truth for the Aurora payload ingredients** (it replaces
`pipe-park/STATE.md`, moved here with `git mv`). The newest working payload is R3-R; R3-Q's ingredients follow
unchanged below it, because R3-R is R3-Q plus the items in the next section. Results and the boot tables:
`../integration/RESULTS.md` ("Round R3"). Per-unit values (PHY tunables) are not in this repository.

# R3-R: trackpad (the newest working boot, 2026-11-07 about 01:45)

Payload sha256 prefix `b457425e`, booted by the self-revert loop. Recipe: `trackpad/R3-R-RECIPE.md`; analysis:
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
| Payload build | `trackpad/mk-r3r.py` (variants `ring`, `pcio`, `power`); it refuses a kernel without magicmouse, 0001 or 0002 | |
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
("Round R3"), `pipe-park/ANALYSIS-R3O.md`, `pipe-park/R3-Q-RECIPE.md`. Per-unit values (PHY tunables) are not in this repository.

| Part | What |
|---|---|
| m1n1 | `m1n1-plain-r2-pipepark.bin`, sha256 `a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46`: ccbb51bc (R3-N's stage 2, v2.0.0-71-gd956947e) plus 0020 (T6050 PIPE park). Same binary as R3-O. 0021 (ATC tunables from the ADT) is **not** in it |
| Kernel tree | `/Volumes/linux-cs/wt-aurora`, branch `aurora-j716s`, tip `4504ef7485be`: 31 commits on `aurora/integration` (`33bec4016c46`), listed below. Config as for R3-N (`make defconfig asahi.config`, 16K pages, boot-path drivers `=y`, `tools/README.md`) |
| DTB | `t6050-j716s-typec-fixed7.dtb`, sha256 `1eb0fcef30554d7f6873c03372466daa837c0d2af7bba8eb138f0d1323347d25`. Lineage: J716c DT (PR #945) -> j716s derived -> fixed6 (CPU order, compatible fallbacks, AFE reset line, Type-C chain; **no** PHY tunables) -> fixed7 (fixed6 plus the 14 combo-PHY tunables generated from this unit's ADT). Per-unit, not committed. R3-P would use fixed6 with m1n1 0021 instead |
| Initramfs | `initramfs-selftest.cpio.gz`, sha256 `ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a` (`tools/mk-selftest-initramfs.sh`: DIAG block plus the self-revert service) |
| Payload layout | m1n1 (0x400000 B) + `chosen.bootargs=` line + `chosen.asahi,show-notch=1` + `Image.gz` + DTB + initramfs (`mk-r3q.py`) |
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
here with `git am` from `pipe-park/kernel-r3q/` under new hashes. Recipe: `pipe-park/R3-Q-RECIPE.md`.

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
