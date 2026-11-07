Add the 16-inch MacBook Pro with the M5 Pro (J716s)

Base: integration/aurora 6a08a08e5755 with #404 (9 commits, unchanged) underneath, then two of
edimoldovan's commits from `edimoldovan/linux-aurora` `t6050-j714c`. The other 10 commits are this
PR's (9 of ours and one of Dj's); it can be rebased once those land.

What it does:
- `soc: apple: rtkit`: the handshake timeout becomes per instance; nvme-apple gives the T6050 ANS
  10 s instead of 1 s. The ANS that iBoot hands over on the J716s sometimes needs about 3 s, and
  with 1 s the root device never appears ("ANS did not boot", -62).
- `hwmon: (macsmc)`: a fan whose optional min/max/target/mode key is missing keeps the attributes
  it has, instead of losing the whole fan (the T6050 SMC spells the mode keys F0md/F1md).
- `arm64: idle`: T6050 idles in WFI even when the boot loader appends idle=nop. m1n1 appends it on
  M4 and later; this kernel already preserves the registers WFI loses, so idle=nop only made
  every idle core spin. `apple_keep_idle_nop` keeps the old behaviour.
- `HID: dockchannel-hid`: wait 50 ms after releasing a host-driven AFE reset, as the driver already
  does for a firmware-managed reset. With 768d807c3cf9 this also applies to the J714c.
- `Input: macsmc-input`: during system sleep, check a lid-open report against the SMC's MSLD key
  before waking the system.
- `dt-bindings: arm: apple`: the J716s board.
- `gpio: macsmc`: the J716s gets the J714c's pcIO line table; its Apple Device Tree has the same
  trackpad AFE reset template, pKW8('pcIO', 0x10000, 0x11c0000).
- `arm64: dts: apple`: t6050-j716s.dts, on #404's T6050 files: memory, the boot framebuffer as the
  built-in panel, the serial console, the keyboard and trackpad (power method 2, AFE reset on SMC
  pcIO 28), the keyboard backlight, and the SMC sensors with the F0md/F1md fan keys.
- `arm64: configs`: j716s.config, the boot-path drivers built in, like the j813 fragments.
- `power: supply: macsmc-power` (Dj): the battery identity keys (BMDN, BMSN, BMDT) are read at
  the key's size, not the buffer's. The J716s battery results below were taken with it in the
  tree; the J716s has not been tested without it. It applies to this tree unchanged.

Must land first (included here so the branch builds and can be tested):
- #404 (edimoldovan): T6050 and J714c.
- edimoldovan 38e75c9f1c07 "Power off and restart through the SMC": the t6050-smc.dtsi part.
- edimoldovan 768d807c3cf9 "drive the trackpad AFE reset line": the pcIO line table in gpio-macsmc,
  which the J716s entry extends. Rebased onto #404's t6050-j714c.dts. The original has no
  Signed-off-by from its author: it needs his, or it should land first on its own and this PR
  drops its copy.

Depends on: omacom/m1n1#26 (T6050 CPU release, the NVMe register window, the MTP DAPF, nine I2C
nodes). The J716s's ANS sits at the J714c's addresses, which #26's NVMe window check matches; #26
has not been booted on a J716s.

The J716s-only pieces, here and in later PRs: the board DT, the SMC sensors on this board, the
lid-open confirm, WFI idle, the 10 s rtkit handshake (edimoldovan's tree still waits 1 s), and,
later, the right Type-C port with nub-spmi-a1, the adopted-link s2idle fix for the N1 port, and the
J716 speakers in the J616s TDM format.

Not included: USB on both Type-C ports, PCIe with the N1 (Wi-Fi and Bluetooth) and the SD reader,
audio, the GPU and the display controller. Follow-ups, each on edimoldovan's matching work once it
is in this tree:
- USB, both ports, with the right port's HPM on nub-spmi-a1 (after his T6050 USB work, e.g.
  56a7a10ed938);
- PCIe and the N1, with the kernel-side port training (ff95947ecddb, 0f96cc6c00e1, 17ada56a25c9),
  the ASPM-free adopted port (ab24d156868e), and our s2idle fix for adopted ports: his
  apple_pcie_suspend_noirq() still refuses suspend with -EBUSY while the N1 port is up;
- audio, on his AOP and speaker commits (f21e1ea10bbd, 369cac02ce47, 8838ca614344) with the J716
  speakers in the J616s TDM format on top;
- the display (his DCP work, 9ffa4ecf3cb3) and the GPU: on the J716s the 27.2+ InitData port boots
  the G17S firmware and renders.
- m1n1: #26 has not been booted on a J716s; a chainloaded stage 2 with the kernel appended may also
  need our stage-1 RVBAR forwarding (aurora-wip m1n1 bring-up, commit 3).
- one shared J714c/J716s .dtsi for what the two board files have in common, once #404 has landed.

### Testing

MacBook Pro 16-inch, M5 Pro (J716s, Mac17,8), SoC T6050, system firmware and OS firmware both
mBoot-20457.60.65.0.1 (macOS 27.3 beta 1, 26C5035r), Omarchy root on the internal SSD.

These changes were tested on the tree they come from: Linux 7.3 (aurora-silicon integration/aurora)
with the same driver changes and an equivalent J716s device tree, booted by our m1n1 (not
omacom/m1n1#26). This branch has not been booted on the J716s.

- 18 CPUs online: pass
- root file system on the internal SSD, every boot with the 10 s handshake: pass
- keyboard and trackpad ("Touch MT ready" on every boot), with the AFE reset driven as SMC GPIO gp1c
  of the second bank, which the J716s ADT names as the same line: pass; through pcIO 28 as in this
  branch: not tested
- kbd_backlight: pass
- macsmc-ac online, macsmc-battery reporting charge (the AC adapter stayed in), with Dj's
  identity-read change in the tree: pass
- SMC fan, power, voltage and current sensors (fans 0 rpm at idle, min 1350, max 5349 and 5777 rpm):
  pass
- the panel is card0-eDP-1: pass
- idle power on the charger, WFI against idle=nop: 9.8 W against 16.4 W (SMC total system power);
  56-minute idle soak with an FP check on all 18 CPUs: pass
- s2idle: freezer, devices, platform and a real suspend with power-button wake: pass
- lid close sleeps and lid open wakes through the MSLD check: pass; the hold-back path for a false
  lid-open report did not run (no false report came during that sleep)
- power-off: pass; restart through the SMC, back to the boot loader: pass
- a fan key missing from the SMC (the hwmon change's new path): not tested, the device tree has the
  F0md/F1md override
- this branch, on hardware: not tested
- `tools/aurora-ci/check-commits.py`: pass (blocking check); checkpatch notes as below
- `tools/aurora-ci/compile-check.py --per-commit`, defconfig + asahi.config + j716s.config:
  pass, every commit builds, no new W=1 warnings (rtkit, nvme-apple, idle, cputype.h
  users, dockchannel-hid, macsmc-hwmon, macsmc-input, gpio-macsmc, macsmc-power)
- `tools/aurora-ci/dt-check.py` against #404's head: pass; no new schema or binding problems apart
  from the NCO reference clock without clock-frequency (as on the J714c); style: kernel comment
  indentation only
- `make CHECK_DTBS=y apple/t6050-j716s.dtb`: the same NCO clock-frequency warning only; dtbs with
  W=1: no warnings
- `scripts/checkpatch.pl --strict`: our commits are clean apart from the MAINTAINERS note for the
  two new files; on the carried commits, the `Co-Authored-By` form, the missing author
  Signed-off-by on 768d807c3cf9, and one alignment note in Dj's change (kept as written)
- other T6050 boards: not tested (edimoldovan's two commits and the AFE settle change also reach the
  J714c)
