# J716s trackpad on the Aurora kernel (wt-aurora, aurora-j716s @ 4504ef7485be)

Static analysis only. Nothing was built and nothing was booted. Line numbers are for the unpatched
`/Volumes/linux-cs/wt-aurora` tree unless marked otherwise.

## Diagnosis in five lines

1. The booted Aurora kernel has no trackpad driver. `.config:7617 CONFIG_HID_MAGICMOUSE=m`, only `Image.gz` was built (no `.ko`, no `hid-magicmouse.o`), and initramfs-selftest has no `lib/modules`.
2. It cannot be `=y` as configured, because `drivers/hid/Kconfig:776-778` makes HID_MAGICMOUSE depend on `HID_APPLE_MTP_HAPTIC || !HID_APPLE_MTP_HAPTIC`, and `.config:7562` has HAPTIC `=m`. All of our own trees use `CONFIG_HID_MAGICMOUSE=y`.
3. With no magicmouse, the multi-touch HID device (presumably 0019:05AC:035A.0002; it has no log line) stays unbound, because `hid-apple.c:1277` claims every BUS_HOST Apple device and `:997-999` returns -ENODEV for anything that is not a keyboard, which keeps hid-generic off it (and `CONFIG_HIDRAW` is not set). So nothing creates and opens an "Apple MTP multi-touch" input device. So `dchid_open()` (`dockchannel-hid.c:798`) never runs, the firmware is never sent, power method 2 never runs and the AFE reset is never touched. That explains why there is no "multi-touch is now ready" (`:1003`) and no "Touch MT ready".
4. Our gp1c wiring is what Aurora's driver expects: the line on `input@8000`, logical 1 = reset asserted, line 28 active low (Aurora's own J713 does the same, `t8132-j713.dts:740-745`). Its SMC writes would be byte for byte the same as on our 7.2 kernel: OFF writes 0x01000000 to gp1c, ON writes 0x01000001.
5. Two smaller differences from our validated sequence remain. Aurora sends HasChanged(ON) with no 50 ms settle after the release (`:556-562`). It also runs this firmware in FIFO mode, where we use the ring. Patch 0001 fixes the first. The ring is a DTB fallback.

## Q1. How Aurora's dockchannel-hid uses the AFE reset for power method 2

**Acquisition at probe** (`dockchannel-hid.c:1620-1645`):
* If `multi-touch` has `apple,power-method = <2>` and no `apple,firmware-managed-reset`, the driver calls `devm_gpiod_get(dev, "apple,afe-reset", GPIOD_ASIS)` on the **transport node** (`input@8000`).
* A failure fails the whole probe, and with it the keyboard. The keyboard works, so on our boot the gp1c line was obtained.
* `GPIOD_ASIS`: the level is not changed at request time.
* `dchid_get_interface()` refuses to create a PM2 interface without that line (`:283-288`).

**When the reset runs.** Only from `dchid_open()` → `dchid_start_interface()` (`:695-770`), which is on the first open of the multi-touch HID device:
1. `dchid_get_firmware()`, then `dchid_send_firmware()` (0x95) (`:727-745`).
2. With `inherited_mtp` set (`:730-741`), the driver asserts the reset, waits 50 ms before the upload, then skips the OFF step. On J716s it is false: `rtkit-helper.c:278-282` sets `preserved` only for j713/t8132-mtp and j614s/t6041-mtp.
3. Without it, `dchid_pm2_set_power(OFF)` then `dchid_pm2_set_power(ON)` (`:748-757`).

**`dchid_pm2_set_power()`** (`:540-568`):

| step | wire / line | delay |
|---|---|---|
| WillChange | `40 02 01 <state> 00 00 00 00 00` | |
| OFF | `gpiod_set_value_cansleep(afe_reset, 1)` = reset asserted | 50 ms |
| ON | `gpiod_set_value_cansleep(afe_reset, 0)` = released | **none** |
| HasChanged | `40 02 01 <state> 01 00 00 00 00` | |

* Polarity is the gpiolib logical value, so `GPIO_ACTIVE_LOW` in the DT turns logical 1 into physical 0.
* With `<&smc_gpio_low 28 GPIO_ACTIVE_LOW>`, `gpio-macsmc.c:298-299` writes `CMD_OUTPUT | level` to gp1c:
  * OFF: 0x01000000 (pin low)
  * ON: 0x01000001
* That is exactly what our 7.2 tree writes. Its `gpio-macsmc.c:193-194` is the same code, and our 0001 drives the same logical values (`contrib/validated/legacy-7.2/trackpad/0001`, `dchid_reset_interface`).

**Firmware GPIO requests** (FIFO mode only):
* `dchid_handle_gpio()` (`:1126-1182`) handles event 0xa0 command 3 as a pulse: logical 1, then `msleep(10)`, then 0.
* `dchid_request_gpio()` (`:673-677`) maps a request named `afe-reset` to the same descriptor. Other names are looked up as `apple,<name>-gpios` on the transport node.
* In ring mode such a request gets `-EOPNOTSUPP` (`:662-665`).
* Our 6320.86.1 logs never showed a 0xa0 request. Event 0xa2 (the "firmware reset request" TripleU613 keys on) is not handled at all: `dchid_handle_event()` only knows 0xf0, 0xf1 and 0xa0 (`:1195-1203`).

**The `apple,afe-smc` T6041 path** (`:1499-1546`, `:474-492`):
* Active only when the node is `apple,t6041-dockchannel-hid` **and** has `apple,afe-smc = <&smc>`. In that mode `use_ring` is set (`:1574`).
* It checks that gp1c is a writable 4-byte key.
* `dchid_reset_interface()` then writes the pKW4 function payload `0x00010000 | (state == 0)` straight to gp1c between WillChange and HasChanged:
  * OFF: 0x00010001, then 50 ms
  * ON: 0x00010000, no delay
* That path serves J616s and power method 1 (`:758-765`). It is not reached for an interface with power method 2, which goes through `dchid_pm2_set_power()`.
* The payload has the same shape as the J716s ADT `function-afe-reset` template's low word (0x00010000 + level, with 1 = assert), written to gp1c instead of to pcIO.

**Boot-log evidence** (`~/Work/agents/aurora-kernel/r3o-dmesg.txt`, Aurora R3-O, same config):
* `:306` the firmware sets up `<1- "multi-touch">`.
* `:328` `touch_iface.c:458: Grape interface configuration completed`: the host enabled the touch interface (0xb4).
* `:327` `hid-generic 0019:0000:0000.0001: device has no listeners` (stm, created before the IDs).
* `:332-333` the keyboard (.0003) binds to `apple`.
* No line for .0002 (presumably multi-touch). No "Sending firmware", no "New AFE[0] cbor image received", no `touch_iface.c:495/512`.
* Compare the passing 7.2 boots: "Resetting multi-touch", then "New AFE[0] cbor image received", then "Touch MT ready" (`contrib/validated/legacy-7.2/trackpad/REPORT.md` §3).

**Why our line 28 active-low "did not work" on Aurora while it works on our kernel:**
* It was never exercised (diagnosis lines 1-3). The facts fit that and nothing else:
  * The firmware prints "Initializing comm interface <1- multi-touch>". That is consistent with `dchid_create_interface_work()` sending 0xb4 (`:897`) before `hid_add_device()` (`:943`).
  * No interface start and no reset follow, because no one opens the device.
  * The input devices are only the keyboard (hid-apple, `=y`) and SMC lid/power.
* Our 7.2 kernel opens the device because magicmouse is built in and binds every `BUS_HOST` Apple device of type `HID_TYPE_SPI_MOUSE` (`hid-magicmouse.c:2378-2400`, `:2634`). The input open callback calls `hid_hw_open()` (`:338-344`), which starts the firmware load.
* Remaining deltas against the sequence validated 3/3 on our kernel:
  * (a) No 50 ms settle after the release (fixed by r3r/0001).
  * (b) FIFO here, ring in our tree. FIFO carries keyboard, stm, actuator and tp-accel today. Aurora's J713 runs its M4-era MTP in FIFO with the same reset shape. MT reports over FIFO on 6320.86.1 are not proven.
  * (c) `iommus = <&mtp_dart 0>` only. Our tree attaches streams 0-4 to both `mtp` and the HID node. This matters if the MTP reads the 0x95 firmware buffer through another stream. It would show as a DART fault at "Sending firmware".
* gpiolib refuses a set on a line not marked output (`gpiolib.c:3789-3790`, -EPERM). The direction comes from gp1c's PINMODE read at request time. That is the same in both trees.

## Q2. Aurora's `apple,smc-pcio-gpio` (j716c/t6050-platform)

**Where.** It is not a separate driver. It is part of commit `54b12371013e` "mfd: macsmc: Support T6050 power and pcIO consumers" (Dj, 2026-10-26). `64f198a02f63` then reworks the cell tables. Size (`patches/pcio-ref/`):

| file | change |
|---|---|
| `drivers/gpio/gpio-macsmc.c` | +73/-1: `macsmc_pcio_set/get/get_direction/probe` |
| `drivers/mfd/macsmc.c` | +35/-?: a T6050 cell profile (input, power, hwmon only) plus the pcIO cell |
| `drivers/power/supply/macsmc-power.c` | +41/-8: `macsmc_read_identity()`, not pcIO |
| bindings | new `apple,smc-pcio-gpio.yaml` (40 lines), `apple,smc.yaml` +5 |

Total 160+/14- for 54b1237 and 46+/30- for 64f198.

**What it does:**
* Probe checks that `pcIO` is a writable 8-byte key (`apple_smc_get_key_info`). It reads `apple,output-commands` as a u64 array (at most 64, each unique, low 16 bits clear).
* It exposes one output-only line per entry.
* `set` writes `put_unaligned_le64(template | !!value)` to `pcIO` with `apple_smc_write()`.
* `get` returns -EOPNOTSUPP. Direction is always output.

**The output-commands table.** Each u64 is `(hi << 32) | lo` of the ADT `pKW8('pcIO', lo, hi)`:
* `hi` = bank << 24 | pin << 16.
* `lo` = flags. Bit 16 is set only on the two reset functions, consistent with an invert flag (inference, see `contrib/validated/legacy-7.2/trackpad/REPORT.md` §2, §5).
* The level goes in bits 15:0.

| line | template | lo / hi | meaning |
|---|---|---|---|
| 0 | 0x001a000000000000 | 0 / bank 0 pin 0x1a | gP1a, dp2hdmi_pwr_en |
| 1 | 0x000f000000800000 | 0x800000 / bank 0 pin 0x0f | gP0f, hdmi_pwr_en |
| 2 | **0x011c000000010000** | 0x10000 / **bank 1 pin 0x1c** | **gp1c**, low bank line 28, multi-touch `function-afe-reset` |

So `<&smc_pcio 2 GPIO_ACTIVE_HIGH>` reaches the same pin as `<&smc_gpio_low 28 GPIO_ACTIVE_LOW>`:
* pcIO OFF writes lo 0x00010001: level 1, with the SMC function applying the invert.
* gpio-macsmc writes CMD_OUTPUT 0 to gp1c directly.

**Dependencies on macsmc.** No new SMC API: `apple_smc_get_key_info`, `apple_smc_write`, `APPLE_SMC_WRITABLE` and `<linux/unaligned.h>` all exist in integration (`dockchannel-hid.c:1539-1542` already uses them).

**Cherry-pick result** (`git apply --check` against wt-aurora; nothing applied):
* `0001` (54b1237) FAILS:
  * `apple,smc.yaml:16`: integration added a t8152 `oneOf` entry.
  * `drivers/mfd/macsmc.c:554`: integration has the T8152 telemetry early return and a different low-gpio block.
  * gpio-macsmc.c, macsmc-power.c and the new yaml apply on their own (`--include`).
* `0002` (64f198) FAILS at `drivers/mfd/macsmc.c:63`: it is built on 54b1237's T6050 table.
* Even rebased, 54b1237's T6050 profile does not fit this DT. fixed7's SMC is `"apple,t6050-smc", "apple,t8103-smc"`, so the profile would replace the full cell list and drop macsmc-gpio, reboot and rtc. Reboot and rtc are restored only with 64f198, and reboot carries the boot_stage fix the iBoot counter needs.
* A minimal port is in `patches/optional-pcio/0005`: the gpio-macsmc and binding hunks unchanged, plus only the pcIO cell, under its own name `macsmc-pcio-gpio`. Reusing `macsmc-gpio` would collide with the existing `macsmc-gpio` cell as a second `PLATFORM_DEVID_NONE` device, and SMC probe would fail. It applies cleanly (111+/2-) and passes a clang `-fsyntax-only` check with the tree's flags. Not built.

## Q3. Route

**Chosen: (b), with one line of (c).** Keep our gp1c wiring, which already has the placement, line and polarity Aurora's driver expects. Fix the config, and port only the 50 ms post-release settle from our sequence.
* **Config:** `HID_MAGICMOUSE=y`, which requires `HID_APPLE_MTP_HAPTIC` to be `n` or `y`. Recommended: `n` for R3-R, which mirrors our validated 7.2 config (that tree has no haptic driver).
* **r3r/0001** (17+/6-): `dchid_pm2_set_power()` sleeps 50 ms after the release before HasChanged, as it already does for firmware-managed reset. It logs "multi-touch: AFE reset asserted/released" at info level and a failure to drive the line as an error. Aurora's routine set-up messages are `dev_dbg` and the tree has no DYNAMIC_DEBUG, so without this a boot log cannot show whether the reset ran.
* **DT fixed8:** fixed7 minus the driverless `smc/gpio { apple,smc-pcio-gpio }` node. Nothing references phandle 0x48. The AFE reset is unchanged: `<0x51 0x1c 0x01>`.
* **Fallbacks, already built:**
  * `fixed8-ring`: `"apple,t6041-dockchannel-hid"` first, which selects the ring at `:1574`, as our 7.2 tree does with t8132.
  * `fixed8-pcio`: Aurora's J716c shape, `<&smc_pcio 2 GPIO_ACTIVE_HIGH>`, which needs optional 0005.

Why not (a): it is about 110 lines plus an MFD rework to reach the same pin through a different SMC key. It is not proven on J716s, and the unmodified commits do not apply.

Why not a full (c): Aurora's driver already has our sequence except the settle.

## Battery patches

Our `0003-hwmon-macsmc-keep-fans...` and `0004-power-supply-macsmc-power-init-work...` both fail `git apply --check` on wt-aurora (`macsmc-hwmon.c:524`, `macsmc-power.c:834`). Ported:
* **r3r/0002 (hwmon):** optional keys warn instead of dropping the fan. Manual control needs min, max, target and mode, and Aurora's newer `apple,fan-manual-control` check is unchanged. In fixed7 the hwmon node is `status = "disabled"`, so this is inert at boot.
* **r3r/0003 (power):** `devm_work_autocancel()` initialises `critical_work`, and `dbg_log_work` is initialised before the notifier. The re-INIT after `blocking_notifier_chain_register()` (`macsmc-power.c:1192-1193`) is gone.
* **r3r/0004 (power, Dj's code):** the macsmc-power hunk of 54b1237, which applies unchanged. BMDN, BMSN and BMDT are read at their key size instead of the buffer size.

**Caveat: 0003 and 0004 alone do not justify dropping the blacklist.** Integration B2 (our 7.2 tree) already carried 0003-0005 and still hard-hung in macsmc-power probe at about 7.8 s (`~/Work/agents/integration/RESULTS.md:148-152`). r3r/0004 is the only new candidate for that hang, because it changes probe-time SMC reads and Aurora wrote it for T6050. That is a hypothesis. So R3-R keeps the blacklist, and dropping it is a separate payload, R3-S.

## Not verified / not done
* No kernel log from the Aurora boot was read. The diagnosis uses the facts you gave, the tree's .config and the absence of built objects.
* Who opens the input device on this rootfs (selftest, logind or libinput) was not checked. If nothing does, open it once by hand (recipe §3).
* edimoldovan's J714c tree was not checked. TripleU613's FT21 was read only in `patches/2026-11-06/ft21-reset-fresh/REPRODUCE.md`. It uses firmware-managed PM2 plus a manual pcIO pulse after event 0xa2, on an asahi 7.2 base, and its pointer use was still unconfirmed at publication. That does not match our host-driven 3/3 result, and Aurora does not handle 0xa2.
