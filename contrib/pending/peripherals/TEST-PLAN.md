# J716s peripherals: drafts and tests

Studio-only work; nothing here was booted. Base: series tip `a0f2f30c967b` (the daily's kernel tree).

| Path | What | Built |
|---|---|---|
| `patches/linux/0001` | dt-bindings: `apple,aop-motion` gains `t6050-aop-accel/-gyro` | n/a |
| `patches/linux/0002` | J716s DT: `als`, `las`, `accel`, `gyro` children of `&aop` | DTB, W=1 clean |
| `patches/linux/0003` | `j716s.config`: AOP sensor drivers and `MMC_SDHCI_PCI` built in | config resolves |
| `patches/linux/0004` | J716s DT: QSPI on, boot NOR, `nvram` partition 0x700000 + 0xc0000 (read-only by driver policy) | DTB |
| `patches/linux/0005` | J716s DT: SD reader (GL9755) on apcie0 port 1 + `dart_apcie1`, all disabled until the loader trains port 1 | DTB |
| `patches/linux/0006` | J716s DT: MagSafe controller `hpm5` (SN201202x, SID 8, no connector) | DTB |
| `patches/linux/0007` | hid-apple: F6 on host/SPI-bus MacBook keyboards is `KEY_DO_NOT_DISTURB`, not `KEY_SLEEP` | object compiles, no warnings |
| `patches/linux-atc0-host/0001` | T6050 combo PHY accepts port 0 with `apple,boot-link-released` | object compiles |
| `patches/linux-atc0-host/0002` | `t6050-j716s-atc0-host.dts`: ATC0 as a normal Type-C port instead of the gadget tether | DTB, W=1 clean |
| `patches/m1n1/0028` | kboot: copy the AOP accel/gyro calibration from the ADT into the DT (port of Aura's `dt_set_aop_motion_cal`) | file compiles (clang, m1n1 flags); not linked |
| `tools/s2idle-drain.sh` | one s2idle sleep on battery: drain in W from `charge_now` and the suspended time | `sh -n` |

The only W=1 warning on both DTBs is the existing `gpio@67700000` unit-name one.

Kernel worktree: `/Volumes/linux-cs/wt-periph`, branches `j716s-peripherals` (0001-0007) and `j716s-atc0-host`
(on top). m1n1: `~/Work/agents/peripherals-t6050/m1n1` (the N1-aware tree `2ce0f78e` + 0028).

## T1 Function row, Globe and Touch ID (attended, today's daily, no change needed)

Set `HandlePowerKey=ignore` and `HandleSuspendKey=ignore` in a logind drop-in first, so neither key acts during the test.
`evtest` on "Apple MTP keyboard", then on "Apple SMC power/lid events".

Pass, without Fn (`/sys/module/hid_apple/parameters/fnmode` = 3, media keys first):

| Key | Code |
|---|---|
| F1 / F2 | `KEY_BRIGHTNESSDOWN` 224 / `KEY_BRIGHTNESSUP` 225 |
| F3 / F4 | `KEY_SCALE` 120 / `KEY_SEARCH` 217 |
| F5 | `KEY_MICMUTE` 248 |
| F6 | today `KEY_SLEEP` 142 (logind suspends); with 0007 `KEY_DO_NOT_DISTURB` 591 |
| F7 / F8 / F9 | `KEY_PREVIOUSSONG` 165 / `KEY_PLAYPAUSE` 164 / `KEY_NEXTSONG` 163 |
| F10 / F11 / F12 | `KEY_MUTE` 113 / `KEY_VOLUMEDOWN` 114 / `KEY_VOLUMEUP` 115 |
| Fn + F1..F12 | `KEY_F1` 59 .. `KEY_F12` 88 |
| Globe alone | `KEY_FN` 464 |
| Touch ID, short press | `KEY_POWER` 116 value 1 then 0 on the SMC device |

Fail: no event, or F6 still 142 on a 0007 kernel.

## T2 AOP sensors (loop-safe boot, values attended)

Needs 0001-0003 in the kernel and m1n1 0028 in the payload. The ALS needs `apple/aop-als-cal.bin` in the firmware
tree: on the MacBook's macOS, `ioreg -r -a -n als -l` holds it as `CalibrationData` of the `AppleSPUVD6286` child
(the asahi-installer's `asahi_firmware/als.py` extracts it). It is per-unit: never commit it.

Loop pass lines:
- m1n1 log: `FDT: /soc@200000000/aop@290c00000/accel: 3 of 3 calibration properties` and the same for `gyro`.
- `dmesg`: `290c00000.aop: 13 AFK endpoints started`, the `announces als|las|accel|gyro` lines, no
  `Unknown sensor type`, no `AOP firmware crashed`, the headphone jack input still registered (audio unaffected).
- `cat /sys/bus/iio/devices/iio:device*/name` lists `aop-sensors-als`, `aop-sensors-las`, `aop-sensors-accel`,
  `aop-sensors-gyro`.
- Lid angle: `in_angl_raw` x `in_angl_scale` between 60 and 180 (degrees) with the lid open.
- Accelerometer at rest: the x/y/z vector magnitude is about 1 g.

Attended: illuminance changes by more than 10x when the sensor (top centre of the bezel) is covered and lit;
`in_angl` follows the lid; gyro reads near 0 at rest and changes when the machine is rotated.
Fail and rollback: the AOP crashes or the audio card disappears: drop 0002 (the services stay unbound).

## T3 Charge limit (attended, on the charger, no code change)

`/sys/class/power_supply/macsmc-battery/`: `charge_behaviour` shows `[auto] auto-discharge` (this SMC has CHLS, and
no CHTE/CH0C/CH0I, so no inhibit-charge or force-discharge). `echo 80 > charge_control_end_threshold`, then with the
battery above 80 %: `status` becomes `Not charging` within a minute and `current_now` stays at 0 or below. Rollback:
`echo 100 > charge_control_end_threshold`. The CHLS value may persist into macOS, where it shows as the battery
charge limit.

## T4 s2idle drain (attended overnight, no code change)

On battery, lid open: `tools/s2idle-drain.sh`; close the lid or let it sleep; wake in the morning with the lid or
the power button. Pass: one `DRAIN slept=... avg=... W` line, `slept` within 5 % of the wall-clock gap, and the
wakeup sources list only the lid or power button. Record `avg` and the capacity drop. The RTC alarm cannot wake this
machine (the PMU's alarm interrupt is not reachable on the polled SPMI bus), so there is no `rtcwake` variant.

## T5 NVRAM read-only (loop-safe)

Needs 0004 and `spi-apple-qspi.ko` (already in the module set). Pass lines: `cat /proc/mtd` shows one `nvram`
partition of size `000c0000`; `dmesg | grep -i -E 'qspi|spi-nor'` names the JEDEC part with no error;
`dd if=/dev/mtd0 bs=4k count=1 | xxd | head` is not all `ff`. Do not copy dumps off the machine into any repository
(the same NOR holds syscfg). No write test until the J716s has an entry in the driver's qualified list.

## T6 SD reader (loop-safe once m1n1 trains port 1)

With today's m1n1 the new port only adds `n1: port 1 not up: root port and DART disabled` to the m1n1 log (its
status registers are already read by the N1 training). With a port-1-capable m1n1: `pcie-apple ... adopted port 1,
endpoint 02:00`, `sdhci-pci 0000:02:00.0: SDHCI controller found [17a0:9755]`, `mmc0: SDHCI controller ...`; with a
card in the slot, `mmcblk0: mmc0:...` and a successful `dd if=/dev/mmcblk0 of=/dev/null bs=1M count=64`.

## T7 MagSafe controller (attended, MagSafe charger connected)

Needs 0006. Pass: a `tps6598x_source_psy_*_08` supply with `online=1`, `/sys/class/typec/port*/power_operation_mode`
`usb_power_delivery` for that port, `macsmc-ac` still `online=1` and the battery still charging. Rollback if charging
stops: drop 0006.

## T8 ATC0 host (attended, only after the gadget tether is retired)

Needs `linux-atc0-host/0001-0002` and a payload whose m1n1 does not run its USB gadget on ATC0. Pass: three
`xhci-hcd` hosts; a USB3 drive on the left-back port enumerates at 5000M or 10000M (`lsusb -t`); the other two ports
unchanged. Rollback: the regular `t6050-j716s.dtb`.
