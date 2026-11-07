# R3-R: trackpad on the Aurora kernel (kernel rebuild needed)

You build the kernel. I did not build or boot anything. The m1n1, initramfs and bootargs are the same as
R3-Q. The DTB is new (fixed8), and the kernel adds four patches and one config change.

## 1. Kernel (`/Volumes/linux-cs/wt-aurora`, branch aurora-j716s @ 4504ef7485be)
```
cd /Volumes/linux-cs/wt-aurora
git log --oneline -1            # 4504ef7485be phy: apple: t6050: restart the PHY firmware ...
git am ~/Work/agents/trackpad-aurora/patches/r3r/0001-*.patch \
       ~/Work/agents/trackpad-aurora/patches/r3r/0002-*.patch \
       ~/Work/agents/trackpad-aurora/patches/r3r/0003-*.patch \
       ~/Work/agents/trackpad-aurora/patches/r3r/0004-*.patch
scripts/config --file .config -e HID_MAGICMOUSE -d HID_APPLE_MTP_HAPTIC
```
Then run `olddefconfig` and build `Image.gz` with the same make variables as for R3-Q, for example
`make ARCH=arm64 LLVM=1 olddefconfig`. Check the config before building:
```
grep -E '^CONFIG_HID_MAGICMOUSE=y$' .config
grep -E '^# CONFIG_HID_APPLE_MTP_HAPTIC is not set$' .config
```
* **The config change is the trackpad fix.** `HID_MAGICMOUSE` is `=m` today, no modules are built, and
  Kconfig keeps it at `m` while `HID_APPLE_MTP_HAPTIC=m` (`drivers/hid/Kconfig:776-778`). That is why
  the haptic driver must go to `n`, or to `y`. `n` matches our validated 7.2 config. The cost is no
  haptic feedback on click; the click itself is still reported.

| patch | what | +/- | sha256 |
|---|---|---|---|
| 0001 HID: dockchannel-hid: settle 50 ms after releasing the AFE reset | our sequence; logs "multi-touch: AFE reset asserted/released" | 17/6 | see SHA256SUMS |
| 0002 hwmon: (macsmc) keep a fan whose optional keys are missing | port of our 0003 | 24/16 | |
| 0003 power: supply: macsmc-power: initialise work items before the notifier | port of our 0004 | 7/3 | |
| 0004 power: supply: macsmc-power: read battery identity strings at their key size | Aurora 54b12371013e, macsmc-power.c part (Dj) | 32/7 | |

* All four pass `git apply --check` on wt-aurora, individually and in sequence. Together with
  optional-pcio/0005 they give tree 088117b3, the same tree as my scratch worktree
  `/Volumes/linux-cs/wt-tpa` (detached HEAD, read-only use).
* clang 23 `-fsyntax-only` with the tree's flags is clean.

## 2. Payload
```
python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py
```
This writes `payloads/R3-R-aurora-trackpad-j716s-fixed8-selftest.bin` and `payloads/SHA256SUMS-R3-R`.
* Layout as R3-Q: m1n1 (0x400000), then a `chosen.bootargs=` line, then `chosen.asahi,show-notch=1`,
  then Image.gz, the DTB and the initramfs.
* The script refuses an Image.gz without magicmouse built in (`magicmouse hid parse failed`), without
  0001 (`AFE reset %s`) or without 0002 (`no minimum key %s`). It refuses the current R3-Q kernel.

| input | path | sha256 |
|---|---|---|
| m1n1 | `~/Work/agents/pipe-park/build/m1n1-plain-r2-pipepark.bin` | a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46 |
| kernel | `/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz` (rebuilt) | printed by the script |
| DTB | `~/Work/agents/trackpad-aurora/dt/t6050-j716s-typec-fixed8.dtb` | 6592850c2794db7f358bc12b9a94ec6c13e5cd2c76093109b6f0e40b8b127293 |
| initramfs | `~/Work/omarchy-m5/build/initramfs-selftest.cpio.gz` | ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a |

Bootargs (as R3-Q):
```
earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 initcall_blacklist=macsmc_power_driver_init m5.selftest=1
```

fixed8 is fixed7 minus the driverless `smc/gpio { compatible = "apple,smc-pcio-gpio"; }` node. The AFE
reset is unchanged: `<&smc_gpio_low 28 GPIO_ACTIVE_LOW>` on input@8000. Regenerate with
`python3 -I ~/Work/agents/trackpad-aurora/mk-fixed8.py`, which is deterministic and gives the same sha256.

## 3. What to expect
* About 0.19 s: `input: Apple MTP multi-touch as ...` and `magicmouse 0019:05AC:...: input: HOST HID ...`
  (new). The keyboard, stm, actuator and tp-accel lines stay as in R3-Q.
* When the device is first opened (desktop, logind or selftest), these lines must appear in this order:
  1. `dockchannel-hid 294b30000.input: multi-touch: AFE reset asserted`
  2. 50 ms later, `... multi-touch: AFE reset released`
  3. `RTKit: syslog message: bootloader.c:537: (*)New AFE[0] cbor image received`
  4. `Interface multi-touch is now ready`
  5. `touch_iface.c:512: Touch MT ready`
* If no "AFE reset asserted" appears once the root is up, nobody opened the device. Open it once:
  ```
  grep -A9 'Apple MTP multi-touch' /proc/bus/input/devices | grep Handlers   # eventN
  timeout 10 cat /dev/input/eventN | wc -c                                   # swipe meanwhile; > 0 = pass
  ```
* The open after switch_root loads `apple/tpmtfw-j716s.bin` from the rootfs. A
  `Direct firmware load for apple/tpmtfw-j716s.bin failed` line means the rootfs lacks it. Our 7.2 boots
  loaded it from the same root, so this is unlikely.
* **Pass:** "Touch MT ready", and events on eventN while swiping. Do this three boots in a row, as on 7.2.

## 4. Failure signatures and next payload
| what you see | meaning | next |
|---|---|---|
| no `Apple MTP multi-touch` input at all | magicmouse not built in | check `zcat /proc/config.gz \| grep MAGICMOUSE` |
| `multi-touch: failed to assert the AFE reset: -1` | gpiolib -EPERM: gp1c read as input at request time | R3-R-pcio |
| `released`, then `Failed to attach to AFE (-6)` / `No HINT_L` | reset polarity or timing on this path | R3-R-pcio |
| `New AFE[0] cbor image received` but `iface multi-touch start timed out`, or Touch MT ready but no events | FIFO transport | R3-R-ring |
| a DART fault right after the reset lines | the MTP reads the firmware through a stream other than 0 | tell me (needs `iommus` streams 0-4 on mtp and input@8000, not prepared) |

* **R3-R-ring** (same kernel): `python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py ring`.
  * DTB `t6050-j716s-typec-fixed8-ring.dtb` (73834dbc...) puts `"apple,t6041-dockchannel-hid"` first,
    which selects the ring as our 7.2 tree does.
  * Watch the keyboard: in ring mode all reports move to the ring.
* **R3-R-pcio** (rebuild):
  1. Also run `git am ~/Work/agents/trackpad-aurora/patches/optional-pcio/0005-*.patch`.
  2. Rebuild, then run `python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py pcio`.
  * DTB `t6050-j716s-typec-fixed8-pcio.dtb` (543cfded...) uses `<&smc_pcio 2 GPIO_ACTIVE_HIGH>`, Aurora's
    J716c shape. Same pin (gp1c), different SMC key (pcIO).
  * The script checks for 0005's string.

## 5. R3-S: without the macsmc_power blacklist (only after R3-R boots clean)
Same kernel and DTB:
```
python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py fixed8 power
```
* This drops `initcall_blacklist=macsmc_power_driver_init` and adds `panic=0 pause_on_oops=300
  ignore_loglevel` (SMC T6 plan).
* **Risk:** our 0003/0004 were already in integration B2 and B2 still hard-hung in macsmc-power probe at
  ~7.8 s. Patch 0004 here (Aurora's key-size identity reads) is the new candidate fix, not a proven one.
* If it hangs right after `Apple SMC power/lid events`, photograph the panel and go back to R3-R.
* Pass: `ls /sys/class/power_supply` shows `macsmc-battery macsmc-ac`. Then do the T6 checks
  (`~/Work/agents/smc/TEST-PLAN.md` §T6).

## Rollback
As for R3-Q: restore `boot.bin.prev`. The DTB and kernel differ from R3-Q. m1n1 and the initramfs do not.
