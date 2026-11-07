# SMC test plan: M5 Pro J716s (ordered; each step gates the next; `dmesg > smc-Tn.log` each step)

## T0 Build and boot setup
- Apply patches/omarchy-m5/0001, 0002 to omarchy-m5; copy patches/linux/0010-0012 into its patches/linux/; apply to the
  kernel; build.
- Cmdline: the usual args plus `initcall_blacklist=macsmc_power_driver_init ignore_loglevel` until T6 passes.
- Do not run smc-proxy-probe.py in the same power cycle before booting Linux (it starts SMC EP 0x20).
- Prefer the initramfs shell (no logind) or configure logind as in T4.  Mount debugfs: `mount -t debugfs none /sys/kernel/debug`.

## T-1 (optional, separate m1n1 session) J716s key dump
- `hv/smc-proxy-probe.py` on J716s, diff against docs/research/smc-keys-j714s.json. Expect F0md/F1md, no F0Md; F1Ac/F1Mn/F1Mx/F1Tg;
  BCF0 size 4; TCHP/TW0P/SBAV/TH0x. Reboot before Linux.

## T1 Does the SMC probe (gate)
- `dmesg | grep -iE 'macsmc|28c600000|smc|rtkit'`: PASS = `macsmc 28c600000.smc: RTKit: Initializing (protocol version 11|12)`.
  FAIL signatures: `Failed to wake up SMC`; `Timed out initializing SMC` / `boot stage=2`; `RTKit buffer request outside SRAM
  region`; `Firmware min version N is too new`; `Failed to get key count`; `SMC crashed!`.
- `ls /sys/bus/platform/drivers/macsmc/` shows 28c600000.smc; `ls /sys/bus/platform/devices/ | grep macsmc` shows
  macsmc-input, macsmc-power, macsmc-gpio, macsmc-hwmon, macsmc-rtc.
- If silent: `cat /sys/kernel/debug/devices_deferred`; `.../28c600000.smc/waiting_for_supplier`; `ls /sys/bus/platform/drivers/apple-mailbox/`.
- Hang at SMC: rollback arg `initcall_blacklist=apple_smc_driver_init,macsmc_power_driver_init`.

## T2 SPMI / PMIC nvmem (RTC prerequisite)
- `dmesg | grep -iE 'spmi|nvmem'`: no `FIFO lacks reply data`, no `timed out`. `ls /sys/bus/spmi/devices/` (USID 0e);
  `ls /sys/bus/nvmem/devices/` (spmi_nvmem0).
- Read only the RTC cell: `dd if=/sys/bus/nvmem/devices/spmi_nvmem0/nvmem bs=1 skip=$((0x2100)) count=6 2>/dev/null | xxd`
  (record it; rollback for T3). Do not read wide PMIC ranges.

## T3 RTC
- `dmesg | grep -i rtc`: `macsmc-rtc macsmc-rtc: registered as rtc0`, `setting system clock to <today> UTC`.
- `for r in /sys/class/rtc/rtc*; do echo $r $(cat $r/name) $(cat $r/date) $(cat $r/time); done`; `date -u` matches.
- Optional: `hwclock -w`, reboot, `hwclock -r`. Rollback: write back the T2 bytes or let macOS re-sync.

## T4 Lid and power button
- Initramfs, or on the rootfs after `/etc/systemd/logind.conf.d/smc-test.conf` with `[Login] HandlePowerKey=ignore
  HandlePowerKeyLongPress=ignore HandleLidSwitch=ignore HandleLidSwitchExternalPower=ignore HandleLidSwitchDocked=ignore`
  and `systemctl restart systemd-logind`.
- `grep -A8 'Apple SMC' /proc/bus/input/devices`: Name="Apple SMC power/lid events", EV=23, SW=1, KEY includes 116.
- `evtest /dev/input/eventN`: lid close `SW_LID 1`, open `0`; short Touch ID press `KEY_POWER 1/0`. Without evtest:
  `xxd /dev/input/eventN` (24-byte records); `evtest --query ... EV_SW SW_LID; echo $?` 0 open / 10 closed.
- `dmesg | grep 'Unknown SMC button event'`: record any. Do NOT hold the button >= 4 s (forced shutdown).

## T5 hwmon: fans and thermal
- `for h in /sys/class/hwmon/hwmon*; do echo $h $(cat $h/name); done` lists macsmc_hwmon. In it:
  `grep . *_label *_input fan*_min fan*_max fan*_target`: fan1/2 labels, fan*_input ~2300-2600 idle (0 if stopped),
  fan*_max 7826, temps 20000-60000 m°C, power "Total System Power" 3e6-30e6 µW, "Battery Voltage" 11000-13100 mV.
- `dmesg | grep macsmc-hwmon`: no `Fan F0Ac: no ... key`; `no mode key F0md` means J716s lacks it (report).
- Load test: `for i in $(seq 18); do yes >/dev/null & done` 60 s; power/temps rise, fans rise under auto; `killall yes`.
- Optional fan control (taints): boot `macsmc_hwmon.fan_control=1`; `echo 4000 > fan1_target` (approaches 4000 in ~15 s);
  `echo 0 > fan1_target` returns to auto. Abort if fans stop or temps > 80000.

## T6 Battery and charger (remove the gate)
- Boot without macsmc_power_driver_init in the blacklist, add `panic=0 pause_on_oops=300 ignore_loglevel`. If it panics,
  photograph the panel; retry once with `initcall_debug`. Rollback: re-add the blacklist arg.
- `dmesg | grep -iE 'macsmc-power|battery|BCF0'`: no `Unexpected BCF0 key size`, `Battery critical`, `Emergency shutdown`.
- `ls /sys/class/power_supply/` -> macsmc-battery macsmc-ac. `cat macsmc-battery/uevent`: STATUS consistent with plug state;
  CAPACITY 0-100 = macOS %; VOLTAGE_NOW ~11-13.1e6; CHARGE_FULL ~8.4-8.8e6 µAh on the 16-inch; CHARGE_NOW <= CHARGE_FULL
  (~20e6+ means B0RM byte order wrong, report); CYCLE_COUNT = macOS; TEMP 200-400; CHARGE_BEHAVIOUR `[auto] inhibit-charge`.
- `cat macsmc-ac/{online,input_power_limit}`; unplug/replug flips online, STATUS follows within ~2 s.
- thermal_zone type includes macsmc-battery; hwmon lists macsmc_battery.
- Optional: `echo 80 > charge_control_end_threshold` (CHLS, may persist into macOS; rollback 100); `echo inhibit-charge >
  charge_behaviour` (rollback auto).
- PASS -> drop `initcall_blacklist=macsmc_power_driver_init` from the default cmdline.

## Rollback summary
- `initcall_blacklist=` per driver: apple_smc_driver_init, macsmc_power_driver_init, macsmc_hwmon_driver_init,
  macsmc_rtc_driver_init, macsmc_input_driver_init, macsmc_gpio_driver_init, apple_spmi_driver_init, apple_spmi_nvmem_driver_init.
- DT: previous t6050-j716s.dtb. Config: revert 0002. RTC: T2 bytes. Fan: `echo 0 > fan*_target`, reboot. Charge: 100 / auto.
