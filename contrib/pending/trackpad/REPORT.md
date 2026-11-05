# J716s trackpad: host-driven AFE reset (power method 2)

Machine: MacBook Pro 16-inch M5 Pro, J716s (ADT J716sAP), T6050.
Kernel: worktree `/Volumes/linux-cs/wt-trackpad` (detached) = 236788cd2602 + commit
`f31c51d61 BASE` (the main tree's `git diff HEAD`, i.e. omarchy patches 0001-0009 incl.
0005 ring transport, + omarchy-m5 `dt/` overlay, branch j716s) + the two patches here.
Note: the main tree's changes are mostly *staged*, so plain `git diff` only shows the
Makefile hunk; `git diff HEAD` is the full state.

## 1. Result

The trackpad fails because nothing pulses or releases the trackpad AFE (analog front end)
reset. MTP firmware AppleMTPFirmwareMac-6320.86.1 accepts the nine-byte power-method-2
will/has requests that the ring transport already sends, but it never drives the AFE
reset and never asks the host to (no 0xA0 GPIO request in any log). In macOS the host
runs `function-afe-reset` itself. The patch does the same:
OFF = will(OFF), assert, 50 ms, has(OFF); ON = will(ON), release, 50 ms, has(ON),
on SMC key `gp1c` = `<&smc_gpio_low 28 GPIO_ACTIVE_LOW>`, described on the multi-touch
child node. If the property is absent or the GPIO cannot be obtained, the driver runs
exactly today's sequence.

## 2. What the J716s runtime ADT says

`/Users/rolo/Work/studio-artifacts/adt-runtime-j716s.bin`, via m1n1 `load_adt`:

| node under /arm-io/dockchannel-mtp/mtp-transport | properties |
|---|---|
| (transport) | hid-merge-personality MTP_SYS, role MTP, hid-transport-mux mtp-aop-mux |
| multi-touch | bootloader-type CBOR, hid-merge-personality C1FD2,3, image-tag, `function-afe-reset = <654 pKW8 'pcIO' 0x00010000 0x011c0000>` |
| stm | bootloader-type HIDDevice, `function-stm-reset = <654 pKW8 'pcIO' 0x00010000 0x011d0000>` |
| keyboard, actuator, tp-accel | no functions |

Phandle 654 = `/arm-io/smc/iop-smc-nub/smc-pmu`. The J716s ADT has NO `PowerMethod`,
`reset-sequence`, `power-sequence` properties: those are macOS IORegistry properties
(nickyrice04/ilinux mtp-input README, live registry of a J716c whose function-afe-reset
bytes are identical): `PowerMethod 2`, `reset-sequence = "function-afe-reset\0" 32 00 01 00`,
`power-sequence = ... 00 32 00 01`, entry = {enable delay ms, disable delay ms, enable
type, disable type}, 0x32 = 50 ms.

Decoding pcIO word 1 = bank<<24 | pin<<16 with every pcIO user in the same ADT:

| function | word 0 | word 1 | bank/pin | SMC key (omarchy-m5 docs/research/smc-keys-j714s.json) |
|---|---|---|---|---|
| sd_pwr_en | 0 | 0x00190000 | 0/0x19 | gP19 (= smc_gpio 25, M3 Pro SD pwren, ACTIVE_HIGH) |
| dp2hdmi_pwr_en | 0 | 0x001a0000 | 0/0x1a | gP1a |
| hdmi_pwr_en | 0x00800000 | 0x000f0000 | 0/0x0f | gP0f |
| stockholm enable | 0x00800000 | 0x010e0000 | 1/0x0e | gp0e |
| afe-reset | 0x00010000 | 0x011c0000 | 1/0x1c | **gp1c** |
| stm-reset | 0x00010000 | 0x011d0000 | 1/0x1d | gp1d |

The J714s key dump (same T6050 SMC) has gP01..gP1d and a sparse lower-case bank with
only gp01 gp02 gp03 gp0e gp1c gp1d. Bank 0 cannot be `gp` (no gp19); every bank-1 pin in
the ADT exists as a gp key. So bank 0 = gP = `smc_gpio` (apple,smc-gpio), bank 1 = gp =
`smc_gpio_low` (apple,smc-low-gpio, the mfd cell added by HEAD 236788cd2), and the AFE
reset is line 28 of smc_gpio_low. Sowyu/m5-azahi (J714s) reached the same mapping
("ADT pcIO reset commands select SMC bank 1, pins 0x1c/0x1d. The SMC's gp1c/gp1d keys
were confirmed on this hardware", apple,smc-low-gpio, flag 1 = active low). Asahi's M3
Pro DT also puts MTP afe/stm reset on smc_gpio_low (25/26). On T8142 (J815) the ADT names
gP1c directly (sh1ftmaker). Same pin number 0x1c across M5 parts.

## 3. What dmesg says

Firmware `AppleMTPFirmwareMac-6320.86.1~81`, personality MTP_SYS, Built 2026-10-28.

Failing boot (`m5-logs/arch-diag-20261104-174838/dmesg.txt`, kernel
7.2.2-01023-g666335fea5e3-dirty = studio-artifacts gcc build):

    23.171 dockchannel-hid: Resetting multi-touch
    23.347 RTKit syslog: bootloader.c:537: (*)New AFE[0] cbor image received
    23.457 RTKit syslog: afe_bl_trp_hbpp.c:174: Failed to attach to AFE (-6)
    23.493 RTKit syslog: afe_bl_trp_hbpp.c:175: AFE[0] Chip Boot Failure for HBPP: No HINT_L (-6)
    23.529 RTKit syslog: afe_pwr.c:821: AFE[0] bootload failed: 1
    25.481 dockchannel-hid: iface multi-touch start timed out

No "GPIO command", "Requesting GPIO" or "T8132 SMC reset GPIO operation is not
established" line: the firmware sent no GPIO request; all four 0x40 requests were ACKed.

Passing boot, SAME kernel and payload, after the other agent's warm reboot at ~23:08
(M5 clock), read over the bridge:

    18.901 dockchannel-hid: Resetting multi-touch
    19.026 RTKit syslog: bootloader.c:537: (*)New AFE[0] cbor image received
    19.110 RTKit syslog: touch_pwr_mgr.c:229: [TPM] Mac Power Manager State Machine Started
    19.110 dockchannel-hid: Interface multi-touch is now ready
    19.134 RTKit syslog: touch_iface.c:495: Touch interface ready
    19.140 RTKit syslog: touch_iface.c:512: Touch MT ready
    19.171 RTKit syslog: touch_pwr_mgr_fsm.c:300: Sending Cumulus Report to enter Dependent Mode (9A)

So the unpatched path is intermittent, as Sowyu reports for J714s (native boots alternate
between Touch MT ready and AFE attach failure): the AFE keeps whatever state the previous
boot left because nobody drives its reset. A host-driven reset makes every boot start the
same way. One passing boot proves nothing; the test plan uses three boots.

## 4. The change

Kernel patch `0001-HID-dockchannel-hid-drive-the-AFE-reset-for-power-me.patch`
(drivers/hid/dockchannel-hid/dockchannel-hid.c only, no module parameters):
- `apple,power-method` read per interface node; default 2 in ring mode, 1 otherwise
  (= today); invalid values warn and use the default.
- `dchid_get_afe_reset()`: at multi-touch start (HID open, firmware found, method 2),
  if the multi-touch node has `apple,afe-reset-gpios`, get it from that child node with
  `devm_fwnode_gpiod_get(..., GPIOD_ASIS)`. Absent / -EPROBE_DEFER / error: one warning,
  afe_reset stays NULL, old sequence runs; a later start retries.
- `dchid_reset_interface()`: method 1 = four-byte request (unchanged). Method 2 =
  will(state); if the line exists, set it (1 = assert for OFF, 0 = release for ON), log
  `multi-touch: AFE reset asserted|released`, sleep 50 ms; then has(state). No line = the
  exact will/has pair sent today.
- Ring mode: a firmware GPIO request named `afe-reset` reuses the host line (was
  -EOPNOTSUPP), and the requested pulse is 50 ms (macOS config action 0/3 = set 1, 50 ms,
  set 0). FIFO mode unchanged.

Why the child node: `dockchannel_hid_probe()` returns -EPROBE_DEFER for any
`apple,*-gpios` on the transport node, and smc_gpio_low has never probed on this
machine; if it failed to probe, a parent-node property would defer the keyboard forever
(a failed supplier keeps can_match set, so fw_devlink never relaxes the link either).
On the child node plus `post-init-providers = <&smc_gpio_low>` (supported here,
drivers/of/property.c:1413, FWLINK_FLAG_IGNORE), neither the probe loop nor fw_devlink
waits for the GPIO chip.

DT patch (`dt-j716s-afe-reset.patch` for omarchy-m5 `dt/`, `git apply --check` passes on
branch j716s; `0002-...` is the same change in the kernel tree):
- t6050-smc.dtsi: add `smc_gpio_low: gpio@67700000 { compatible = "apple,smc-low-gpio"; }`
  and rename `smc_gpio: gpio` to `gpio@67500000` as in t6030.dtsi (the mfd matches by
  compatible; nothing uses the path). Also removes `macsmc-low-gpio: Failed to locate
  of_node`. Shared with J714s, harmless there (gp keys exist on J714s too).
- t6050-j716s.dts: `#include <dt-bindings/gpio/gpio.h>`; on `&mtp_hid/multi-touch`:
  `apple,power-method = <2>; apple,afe-reset-gpios = <&smc_gpio_low 28 GPIO_ACTIVE_LOW>;
  post-init-providers = <&smc_gpio_low>;` with a comment citing the ADT property.

`firmware-managed-reset` (aurora c15edd5f86, J813) was not chosen: J716s routes the reset
function to the host SMC in the ADT, and the firmware-only path (today's code) fails
intermittently with No HINT_L.

Build: `Image.gz` + `dtbs` with the command from the task, exit 0, no diagnostics in
dockchannel-hid.c (only pre-existing host-tool warnings in gen-hyprel.c). Kernel release
string `7.2.2-gf31c51d6187d-dirty`. DTB checked with dtc: multi-touch has
`apple,afe-reset-gpios = <phandle(gpio@67700000) 0x1c 0x01>`.

## 5. Sequence and polarity

power-sequence {0, 50, 0, 1}: power-on = type 0, no delay; power-off = type 1, then 50 ms.
reset-sequence {50, 0, 1, 0}: reset = type 1, 50 ms, type 0. In both, type 1 = reset
asserted, type 0 = released. Wire sequence after the 0x95 firmware upload (iface 1):

| step | action |
|---|---|
| OFF | `40 02 01 00 00 00 00 00 00`, gp1c := 0 (assert), 50 ms, `40 02 01 00 01 00 00 00 00` |
| ON | `40 02 01 02 00 00 00 00 00`, gp1c := 1 (release), 50 ms, `40 02 01 02 01 00 00 00 00` |

= aurora 90916bb664 (J700) plus a 50 ms settle before has(ON) (the settle aurora
c15edd5f86 uses). sh1ftmaker 0026 pulses again at ON; both end released after >= 50 ms held.

GPIO_ACTIVE_LOW because: every earlier MTP AFE/STM reset in asahi is ACTIVE_LOW and the
M2 trackpads work with it (t8112 smc_gpio 8, t602x smc_gpio 25, t603x smc_gpio_low 25);
word-0 bit 16 (0x00010000) is set on exactly the two reset functions and clear on the
power enables (which asahi drives ACTIVE_HIGH), consistent with an invert flag; Sowyu
(J714s) and sh1ftmaker (J815) also use ACTIVE_LOW. Conflict: aurora's J700 DT has
`<&smc_gpio 19 GPIO_ACTIVE_HIGH>` "level 1 asserts the reset" (compile-tested only, J700
word 0 unknown).

## 6. What remains a guess

1. Polarity (inferred, not measured). If wrong, every boot fails with No HINT_L after
   `AFE reset released` (keyboard unaffected). `payload-trackpad-active-high.bin` differs
   only in that flag (DTB diff: one cell, 0x01 -> 0x00).
2. gp1c on J716s specifically: key list is from the J714s dump; checked at boot by the
   test plan (macsmc-low-gpio probe, line in /sys/kernel/debug/gpio).
3. The 50 ms settle before has(ON) is not in macOS's power-sequence (enable delay 0).
4. Whether macOS also sends the 0x40 will/has requests (nickyrice04 saw none from macOS;
   sh1ftmaker's firmware RE says 0x40 v2 is the power request). Both kept; firmware ACKs them.
5. The kernel build itself: today's deployed kernel is studio-artifacts/Image.gz (gcc,
   g666335fea5e3). This payload is the first LLVM build of 236788cd2 + main-tree diff with
   no boot record in m5-logs. If it does not reach SSH, the cause may be unrelated; roll back.
6. Close/reopen, suspend/resume are not covered (reset runs on the first successful start
   only, as today).

## 7. Files (/Users/rolo/Work/agents/trackpad)

| file | sha256 / note |
|---|---|
| 0001-HID-dockchannel-hid-drive-the-AFE-reset-for-power-me.patch | kernel driver patch (format-patch on BASE f31c51d61) |
| 0002-arm64-dts-apple-t6050-j716s-host-driven-trackpad-AFE.patch | DT change, kernel tree |
| dt-j716s-afe-reset.patch | DT change for omarchy-m5 dt/ |
| payload-trackpad.bin | fcc402401b33325cac937037deb050660756a4d615182470b7dde3afad001a0d (ACTIVE_LOW) |
| payload-trackpad-active-high.bin | 59b5d00e8dc5bbf612bc069b45622b7a61b11ad898135f6861ec31d4bc87a260 (fallback) |
| t6050-j716s.dtb / t6050-j716s-active-high.dtb | 5bc152d2... / 7a1d2c0d... |
| Image.gz | 1dd78a8bd708545db0493599ddba466212618625090eeb5d8ea4f4a43e7c0572 |
| build.log | full build log |

Payload inputs: m1n1 = /Users/rolo/Work/m1n1-linuxbuild/m1n1-plain.bin (Nov 4 18:05, newer
than 18:00), initramfs = omarchy-m5/build/initramfs-tp.cpio.gz, firmware =
omarchy-m5/build/firmware-test (apple/tpmtfw-j716s.bin), default PAYLOAD_ARGS (kboot adds
idle=nop arm64.nowfxt, as on the current boot). Both payloads contain their DTB and the
Image.gz (byte search verified); the build is reproducible (same sha256 twice).
Side effect: mk-esp-install.sh overwrote omarchy-m5/build/m1n1-payload-j716s.bin and
build/initramfs-esp-install.cpio.gz (the 18:05 versions; the 18:05 payload is the one
deployed now, sha256 a2407e83..., still on the ESP as /boot/m1n1/boot.bin).
