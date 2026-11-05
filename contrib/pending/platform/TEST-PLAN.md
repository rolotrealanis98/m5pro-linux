# J716s platform test plan (keyboard backlight, power-off, thermal, s2idle)

For the hardware agent. Nothing here has run on the M5 yet. Steps are ordered
safest first. Tags: [SAFE] read-only or trivially reversible; [LOW] can fail
visibly but cannot hang the machine; [HANG-RISK] can hang it (recover by holding
power ~10 s); [NEVER] do not run in this phase.

## 0. Build, deploy, rollback

Kernel: asahi-wip-7.2 236788cd2 + main-tree diff (omarchy 0001-0009) + SMC
0010-0012 + platform 0040-0042 (+ cpufreq/trackpad/USB as their plans say).
Config: defconfig asahi.config omarchy-bringup omarchy-storage-net omarchy-smc
omarchy-platform (omarchy patch 0001 makes build-kernel.sh merge it; delete
vendor/linux/.config first so it is regenerated). Check the result:

```
grep -E '^CONFIG_(PWM_APPLE|POWER_RESET_MACSMC|PM_DEBUG|THERMAL_OF|CPU_FREQ_THERMAL)=y' .config   # 5 lines
grep -E '^# CONFIG_HIBERNATION is not set' .config
```

DTB: build/t6050-j716s.dtb (stage A, sha256 in build/SHA256SUMS), which also
carries the SMC agent's DT, the trackpad AFE DT, the cpufreq DT and the USB
agent's omarchy patch. Stage B: build/t6050-j716s-thermal-stageB.dtb (only at T4).
Keep the payload bootargs as they are today, including the SMC agent's
`initcall_blacklist=macsmc_power_driver_init` until its battery step passes.

Before installing a new payload, from the running system:

```
cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin.prev-1cpu   # keep the old 1-CPU rollback
cp /boot/m1n1/boot.bin      /boot/m1n1/boot.bin.prev        # current 18-CPU payload = rollback
sha256sum /boot/m1n1/boot.bin*
```

Rollback:
- R1 (Linux reachable): `cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin && sync && reboot`.
- R2 (new payload never reaches SSH): hold power until off; hold power to the
  boot picker; one-time boot Macintosh HD (do not "Always use"); in macOS
  `diskutil list` -> the FAT32 "OMARCHY" partition (GPT p4), `diskutil mount
  diskXsY`, `cp /Volumes/OMARCHY/m1n1/boot.bin.prev /Volumes/OMARCHY/m1n1/boot.bin`,
  restart. The stub stays the default startup disk.
- R3 (tethered try-before-install, preferred for the first kernel): rename
  `m1n1/boot.bin` to `boot.bin.hold`, reboot into the stage-1 proxy and boot the
  new Image.gz + DTB with tools/linux.py from the Studio (docs/boot-and-recovery.md);
  rename it back afterwards.

Logging for every step: `dmesg -w > /root/plat-<step>.log &` (on the Arch root)
or into /dev/shm for the suspend steps; the panel shows the kernel console
(`console=tty0 loglevel=8 no_console_suspend`), photograph it when a step hangs.
`m5-temps` (userspace/usr/local/bin) prints every sensor, zone and cooling device.

## Stage 0: baseline on the current system [SAFE]

```
cat /sys/class/hwmon/hwmon*/name; for f in /sys/class/hwmon/hwmon0/*_input; do echo $f $(cat $f); done
ls /sys/class/thermal /sys/class/leds /sys/class/power_supply
cat /sys/power/state /sys/power/mem_sleep
```
Record idle temps and fan rpm (all 18 cores busy-poll because of idle=nop, so
idle is warmer than macOS idle).

## Stage A: new kernel + stage A DTB

A0 [LOW] boot (R3 first). Expect in dmesg:
- `macsmc-reboot macsmc-reboot: Handling poweroff requests via SMC (restart left to other handlers)`
- no `Missing NVMEM cell` lines are expected to matter (they are warnings: the cells were removed on purpose)
- `/sys/class/leds/kbd_backlight` present, `/sys/class/thermal/thermal_zone0..6`,
  `cooling_device0..2` (type `cpufreq-cpu0`, `-cpu6`, `-cpu12`; cpu12 needs the cpufreq P-cluster DT)
- `macsmc_hwmon`: 12 temperature channels; any key the J716s SMC lacks shows
  as label `temperature-XXXX absent` with no temp_input (kernel 0041). TH0x, TB0T,
  TCHP, TW0P must not be absent.
If the boot hangs right after `apple-pmgr-pwrstate` / pwm lines: R2, then rebuild
with `initcall_blacklist=apple_pwm_driver_init` and report.

A1 restart path unchanged [LOW]: `reboot` must come back exactly as before
(watchdog restart -> stage-1 -> Linux).

K1 keyboard backlight [LOW]
```
cat /sys/class/leds/kbd_backlight/{max_brightness,brightness}
echo 32  > /sys/class/leds/kbd_backlight/brightness   # dim
echo 255 > /sys/class/leds/kbd_backlight/brightness   # full
echo 0   > /sys/class/leds/kbd_backlight/brightness   # off
cat /sys/kernel/debug/pwm 2>/dev/null                  # period 40000 ns
```
Pass: keys light up and dim; no PMGR errors for fpwm0 in dmesg. Then reboot and
check systemd restores the level (systemd-backlight@leds:kbd_backlight).

## Thermal

T1 which SMC key is which cluster [SAFE, but watch temperatures]
```
m5-temps > /root/t1-idle.txt
for c in 12 13 14 15 16 17; do taskset -c $c sh -c 'while :; do :; done' & done
for i in $(seq 12); do sleep 5; m5-temps >> /root/t1-p.txt; done; kill %1 %2 %3 %4 %5 %6
# repeat with cores 0-5 (t1-m0.txt) and 6-11 (t1-m1.txt), 60 s cool-down between runs
```
ABORT (kill the loops) if any reading passes 100000 or if fans stay at idle rpm
while a cluster key passes 95000. Decide: the cpu-p zone key is the candidate
that rises with cores 12-17 and not with 0-11; same for M. If none of the
candidates tracks a cluster, replace candidates in t6050-j716s-platform.dtsi
(keep TH0x/TB0T/TCHP/TW0P first; keep the channel comments right) and repeat.
Tg08 cannot be loaded (no GPU driver): record only.

F1 fans [SAFE]: from the T1 logs, fan1/fan2 rpm vs temperature. Expected: the
SMC ramps them by itself. If they stay at idle while the SoC passes 90 C, stop:
the optional userspace/usr/local/bin/m5-fan-floor (needs
`macsmc_hwmon.fan_control=1`, writes F0md/F1md + F0Tg/F1Tg; coordinate with the
SMC agent first) becomes necessary.

T2 thermal emulation [SAFE] (no trips in stage A, so nothing acts):
```
z=$(grep -l cpu-p-thermal /sys/class/thermal/thermal_zone*/type); z=${z%/type}
echo 60000 > $z/emul_temp; cat $z/temp; echo 0 > $z/emul_temp; cat $z/temp
```

T3 manual throttling through the cooling devices [LOW] (needs the cpufreq plan's stage 1):
```
c=$(grep -l cpufreq-cpu12 /sys/class/thermal/cooling_device*/type); c=${c%/type}
cat $c/max_state; echo 5 > $c/cur_state; cat /sys/devices/system/cpu/cpu12/cpufreq/scaling_max_freq
echo 0 > $c/cur_state; cat /sys/devices/system/cpu/cpu12/cpufreq/scaling_max_freq
```
Pass: scaling_max_freq drops 5 OPPs and returns.

T4 stage B DTB (trips + cooling maps) [LOW], only after T1 and T3, rebuilt if
T1 changed keys. Check `trip_point_*_temp` in the cpu zones, then:
```
echo 96000 > $z/emul_temp; sleep 2; cat $c/cur_state   # > 0, cpu12 max freq drops
echo 0 > $z/emul_temp; sleep 5; cat $c/cur_state       # back to 0
```
Run the T1 load for 10 minutes and confirm no throttling below 95 C. No critical
trips exist yet (they need P2).

## Power-off

P0 [SAFE] read the PMU scratchpad bytes the full driver would write (read
only, only these 16 bytes; never write this device):
```
n=$(ls -d /sys/bus/nvmem/devices/*pmic* /sys/bus/nvmem/devices/*abbey* 2>/dev/null | head -1)
[ -n "$n" ] && dd if=$n/nvmem bs=1 skip=$((0xf800)) count=16 2>/dev/null | xxd
```
Record before and after each P step (boot_stage 0xf801, error/panic counts 0xf802,
shutdown flag 0xf80f bit 3, as guessed from chapel/stowe).

P1 SMC power-off with the root read-only [HANG-RISK, low]:
```
echo 1 > /proc/sys/kernel/sysrq; sync; echo u > /proc/sysrq-trigger; sleep 2
echo o > /proc/sysrq-trigger
```
Panel should show `Preparing for reboot (offw)`, `Preparing SMC for atomic mode`,
`Issuing power off (off1)`. Outcomes: (a) the machine turns off; a power press
boots stage-1 -> Linux: PASS. (b) it restarts: off1 without shutdown_flag
reboots on this firmware (note it; P5). (c) `Unable to power off system` WARN
or a frozen panel: hold power; FAIL, keep the logind safe default and boot with
`initcall_blacklist=macsmc_reboot_driver_init` until analysed.

P2 [LOW once P1 passed] `systemctl poweroff` from the full Arch session, then
power on. PASS = off, clean fsck-free boot. Then install
userspace/stages/logind-20-poweroff-verified.conf (power key and lid lock).

P3 [LOW] hold the power button: expect `Triggering forced shutdown!` then a
clean SMC power-off before the SMC's own forced cut.

P4 (later, optional) SMC restart [HANG-RISK]: DTB without `apple,poweroff-only`;
`reboot` must land in stage-1 m1n1 -> Linux, not the boot picker or recovery.
Only with R2 ready.

P5 (later, only if P1 = (b)) add `shutdown_flag` alone after P0 shows bit 3 of
0xf80f behaving as on M1-M3 (set by macOS shutdown, clear after boot). Never add
boot_stage / counters before iBoot's use of them on T6050 is understood.

## s2idle (all [HANG-RISK], last)

Prerequisites: P2 passed (so a hang is a known-recoverable state), stage A
booted, kernel has 0042 (`cat /sys/module/pmgr_pwrstate/parameters/sleep_power_off`
-> -1), the logind/sleep safe defaults installed (nothing triggers sleep by
itself). The EEM SSH link drops whenever devices suspend: run each step
detached and reconnect afterwards, e.g.
`setsid sh -c 'echo freezer > /sys/power/pm_test; echo freeze > /sys/power/state; echo rc=$? > /dev/shm/s.rc' &`.
Root read-only for S2-S4 (`echo u > /proc/sysrq-trigger`), logs in /dev/shm,
copy them off before rebooting.

S0 [SAFE] `cat /sys/power/state /sys/power/mem_sleep /sys/power/pm_test`;
expect `freeze` (and `mem`, mapped to s2idle) and `[s2idle]`;
`echo 1 > /sys/power/pm_debug_messages; echo 1 > /sys/power/pm_print_times`.

S1 first experiment: freezer only.
`echo freezer > /sys/power/pm_test; echo freeze > /sys/power/state`
Tasks freeze for 5 s and thaw; no device callback runs. PASS = returns 0,
`PM: suspend exit` in dmesg.

S2 devices: `echo devices > /sys/power/pm_test` + freeze. Every driver's
suspend/resume runs (NVMe shuts the ANS down and reboots it over RTKit; dwc3
gadget drops the link; apple_wdt stops/starts; cpufreq governors stop), no
noirq phase, no PMGR writes. Watch for `nvme ... RTKit` resume errors, `PM:
Device ... failed`, and per-device times. If NVMe does not come back the root
is gone: hold power, R1 after boot.

S3 platform: `echo platform > /sys/power/pm_test` + freeze. Adds late/noirq
suspend; with 0042 genpd marks domains off without touching PMGR. Never run
this with `pmgr_pwrstate.sleep_power_off=1` (writes to auto-gated T6050
domains hang the bus).

S4 real s2idle, wake by the power button:
`echo none > /sys/power/pm_test; echo freeze > /sys/power/state`, wait 20 s,
short-press power (macsmc-input wakeup; KEY_POWER is swallowed while
suspended). Then again with lid close/open as the wake. The keyboard/trackpad
cannot wake (no wakeup in dockchannel-hid) and there is no RTC alarm
(rtc-macsmc has none), so rtcwake is not available. CPUs keep busy-polling
(idle=nop), the panel stays lit (no DCP driver): expect no power saving yet.

S5 resume health after S4: NVMe I/O (`dd if=/dev/nvme0n1 of=/dev/null bs=1M count=64`),
keyboard and trackpad input, EEM link back, `cpufreq` policies, `m5-temps`,
kbd backlight level, framebuffer intact, `dmesg | grep -iE 'fail|error|timeout'`.

S6 20 cycles with the root read-write, then install stages/logind-30 and
sleep-30 (lid -> suspend) and remove 10-m5pro-no-sleep.conf.

## [NEVER] in this phase
- `echo disk > /sys/power/state`, hibernation of any kind (kernel built without it).
- CPU hotplug: spin-table CPUs have no `online` file; do not try `nosmp`/`maxcpus`
  games to emulate it, and never boot without `idle=nop arm64.nowfxt`, with
  `idle=wfi`, or with cpuidle enabled (WFI/WFIT lose state on M4+/M5).
- Writing the PMIC nvmem device, `apple,smc-reboot` with boot_stage/counter cells,
  NVRAM or boot policy (bputil/kmutil) as part of these tests.
- Manual SMC fan mode (`macsmc_hwmon.fan_control=1`) outside F1's decision.
- `pmgr_pwrstate.sleep_power_off=1` on T6050.
