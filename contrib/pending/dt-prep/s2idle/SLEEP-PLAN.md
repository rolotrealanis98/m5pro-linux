# s2idle on the J716s, Aurora kernel (j716s-series): plan

Kernel: `j716s-series` (`b9cea5ab1b7d`, same tree as `4f630b11270d`) plus `patches/s2idle-plan/0001`
(CONFIG_PM_DEBUG). Script: `s2idle-step.sh` (this folder; copy to `/boot/s2idle-step.sh`). Every step:
`bash /boot/s2idle-step.sh <step>`, logs in `/boot/r1-logs/sleep-<step>-<time>/` (`summary.txt`,
`dmesg.txt` from the step's marker on, `guards.txt`, `before/`, `after/`, `interrupts.diff`).

## 1. What a hang costs: the watchdogs in s2idle

- The A/B stage-1 arms WD1 (`chainload.wdt=150`, the `apple,t6050-wdt` block at 0x28836c000 + 0x10).
  `apple_wdt` takes it over at probe (WDOG_HW_RUNNING), sets its own 30 s timeout, and the watchdog core's
  `watchdogd` kthread pings it while no one has `/dev/watchdog` open.
- **`apple_wdt_suspend()` stops WD1** whenever it is active or hardware-running
  (`drivers/watchdog/apple_wdt.c:210-218`), and `apple_wdt_resume()` restarts it. That runs in the device
  suspend phase of every step from S2 on, so a hang in late/noirq suspend, in s2idle itself or in resume
  is never caught by WD1, whatever the SoC's clocks do.
- Before that phase (freezer, early device callbacks) WD1 is still pinged by the kernel thread, so a stuck
  freezer or a deadlocked callback does not trigger it either; only a hard lockup of every CPU does.
- Nothing in Aurora's cpuidle or s2idle work changes this: `4253ee01142c` (#826) only touches
  `cpuidle-apple.c`; `apple_wdt.c`'s last change is `6a64769d00af` (parent device, nowayout).
- Does the SoC's watchdog keep counting in s2idle? On this kernel s2idle is WFI on every core (both
  cpuidle states are WFI on T6050) with the tick frozen; no PMGR/PMP sleep sequence runs and the 24 MHz
  reference clock of the watchdog block stays up, so a timer that is left armed keeps counting. That is
  what the guard below relies on.
- **The guard: WD2.** The same block has WD2 (+0x20 count, +0x24 bite, +0x2c control; "WD1 and WD2 trigger
  a normal machine reset", `apple_wdt.c:22-24`) which no driver touches. `s2idle-step.sh` arms it through
  `/dev/mem` (CONFIG_DEVMEM=y, IO_STRICT_DEVMEM off) for `--guard` seconds (default 120, max 178) right before
  the sleep and clears it right after. If the SoC never comes back, WD2 resets it, iBoot boots stage-1, and
  the A/B logic does the rest. WD2's reset on T6050 is not verified: step S0 checks it once.
- Without a working guard a hang needs a 10 s power-button hold (the next boot still takes the A/B
  fallback if iBoot counts the unclean end).
- `kernel.panic=10` is set for the step, so an oops or panic during the test reboots through
  `apple_wdt_restart()` (it writes WD1 directly, suspended or not).

## 2. What the series has, against what the J716c/J714c sleep work used

| Prerequisite | Who used it | In j716s-series? |
|---|---|---|
| T6050 in `cpuidle-apple` (two WFI states, index 1 for s2idle so `tick_freeze()` runs) | erikwb #826 (`4253ee01142c`): J716c, 483 s of s2idle, all 18 CPUs entered the state; "Not tested: M5 Pro" | **Yes** (`drivers/cpuidle/cpuidle-apple.c:140,194`); binds with no DT node |
| WFI that idles instead of spinning: no `idle=nop`, arm64 WFI quirk for M4+ | Aurora integration | **Yes** (`arch/arm64/kernel/idle.c` `apple_wfi_quirk_init`); the script fails S1-S4 if `idle=nop` is on the command line |
| `CONFIG_SUSPEND` | edimoldovan `17b3cc9ca3a6` | **Yes** |
| `CONFIG_PM_DEBUG` + `PM_SLEEP_DEBUG` (`/sys/power/pm_test`, `pm_print_times`, `pm_debug_messages`) | edimoldovan `17b3cc9ca3a6` | **No**: `patches/s2idle-plan/0001` (kernel rebuild). Needed for S1-S3 and for the S4 debug lines |
| SMC lid + power button as wake events (`macsmc-input`, `pm_wakeup_dev_event`) | edimoldovan `4602eba4b9d2` (J714c, lid close/open via logind) | **Yes**: `macsmc-input` is an MFD cell without a DT node, always created; the SMC mailbox RX IRQ is `IRQF_NO_SUSPEND` (`drivers/soc/apple/mailbox.c:1735`) so an SMC message ends s2idle |
| RTC wake alarm (`rtcwake`) | not on T6050 anywhere | **No, and not by DT alone**: `rtc-macsmc` arms an alarm only with the PMU alarm nvmem cells and an SPMI peripheral IRQ (`t6030.dtsi:1197-1206` pattern); the gen-4 SPMI driver refuses interrupts ("Generation 4 interrupt layout is not supported"), so rtc0 has no `wakealarm`. S4 wakes by power button or lid |
| xHCI keeps its PHY across s2idle (`wakeup-source` honoured by xhci-plat) | edimoldovan `9f8535b38fcb` (J714c Ethernet adapter came back after sleep) | **No** in the driver; the script does the same at run time: `echo enabled > /sys/bus/platform/devices/xhci-hcd*/power/wakeup`. `dwc3-apple` already makes the core a syscore device so its domain stays on (`dwc3-apple.c:764-775`) |
| NVMe ANS stays up across sleep (post-M4 path, `apple_nvme_keep_link_powered`) | Aurora PR #936 | **Yes** (`664d45e329cf`) |
| Coprocessor power domains kept on in sleep (`apple,sleep-retained`) | Aurora `8fd377b7d93e`, used only by J713's GPU | Mechanism **yes**, no T6050 domain marked. Candidate if S3 loses USB (below) |
| N1 Wi-Fi suspend | Aurora centauri | `centauri_suspend()` returns `-EBUSY` unless the N1 finished booting: with port00 enabled but the N1 not up, every step from S2 aborts on it |
| logind/sleep.conf stage S | `contrib/pending/platform/userspace/stages` | Not installed by default (`10-m5pro-no-sleep.conf` refuses `systemctl suspend`); the script writes `/sys/power/state` directly, so it is not affected. Install stage S only after S4 passes 3 times |

Note: `contrib/pending/platform/userspace` says the kernel has no CONFIG_HIBERNATION; the Aurora config has
`CONFIG_HIBERNATION=y`. Never write `disk` to `/sys/power/state`; keep `hibernate.target` masked.

## 3. The steps

Common guard commands (the script runs them and refuses to start on a failure; `guards.txt`):

```sh
cat /sys/power/state                      # must list freeze (and mem)
cat /sys/power/mem_sleep                  # [s2idle]  (no deep: no PSCI SYSTEM_SUSPEND)
cat /sys/power/pm_test                    # S1-S3: exists = CONFIG_PM_DEBUG
cat /sys/devices/system/cpu/cpuidle/current_driver     # apple_idle
grep -o 'idle=[a-z]*' /proc/cmdline       # nothing
cat /sys/class/watchdog/watchdog0/state   # active (A/B stage-1 with chainload.wdt)
ls /sys/class/rtc/rtc0/wakealarm          # absent today -> S4 uses the button
```

Common failure signatures (dmesg; the script flags them):

| Line | Meaning |
|---|---|
| `Freezing user space processes failed after 20.0xx seconds (N tasks refusing to freeze ...)` | a task in D state; the list follows |
| `<drv> <dev>: PM: failed to suspend async: error -16` + `PM: dpm_run_callback(): <fn> returns -16` | a driver refused (centauri `-EBUSY` when the N1 is not up) |
| `PM: Some devices failed to suspend, or early wake event detected` | the step aborted cleanly; look one line up |
| `PM: Wakeup pending, aborting suspend` + `PM: last active wakeup source: <x>` | something woke it at once (lid, SMC event, USB) |
| `Unsupported test mode for suspend to idle` | pm_test above `platform`; not used here |
| `SError`, `Unable to handle kernel ...`, `Internal error` | a resume touched a powered-off block |
| no `PM: suspend exit`, no new log, Mac dark | hang: WD2 resets it after `--guard` s (S0 passed) or power-button hold |

### S0: WD2 calibration (once, before S2)

```sh
bash /boot/s2idle-step.sh wd2 --guard 30
```

Arms WD2 for 30 s and leaves it armed; nothing sleeps. Pass: the Mac resets about 30 s later and boots
normally (`summary.txt` says "WD2 armed", the run log ends with "alive 25s" or so). Fail: the script is still
alive at 90 s, disarms WD2 and writes "no reset" -> do not rely on `--guard`; run S2-S4 only with someone
at the Mac. If WD2 instead lands in recovery (WD0-like behaviour), use `--guard 0` and say so.

### S1 (optional): freezer

```sh
bash /boot/s2idle-step.sh s1
```

Expected: `PM: suspend entry (s2idle)`, `Filesystems sync: 0.0xx seconds`, `Freezing user space processes`,
`... completed (elapsed 0.0xx seconds)`, `OOM killer disabled.`, `Freezing remaining freezable tasks`,
`... completed`, then after 5 s `OOM killer enabled.`, `Restarting tasks: Starting`, `Restarting tasks: Done`,
`PM: suspend exit`. No device callback runs; WD1 keeps running.

### S2: freezer + devices (`pm_test=devices`)

```sh
bash /boot/s2idle-step.sh s2
```

Runs every device's `prepare` and `suspend` callback (WD1 stops here; WD2 guards), waits 5 s, resumes.
Expected after S1's freezer lines: `printk: Suspending console(s) (use no_console_suspend to debug)`, the
`pm_print_times` pairs `<dev>: PM: calling <cb> @ <pid>, parent: <parent>` / `<dev>: PM: <cb> returned 0 after <n> usecs`
for every device, `PM: suspend debug: Waiting for 5 second(s).`, the resume pairs, `OOM killer enabled.`,
`Restarting tasks: Done`, `PM: suspend exit`. The ssh session over the tether drops (the ATC0 gadget
disconnects) and comes back.
After: keyboard and trackpad work, `lsusb` lists the same devices (USB3 on ATC1, and ATC2 with the right-port
DTB), the NVMe reads (`after/nvme-read`), `watchdog0` is `active` again, `summary.txt` PASS.
Specific failures: `centauri ...: PM: failed to suspend: error -16` (N1 not booted: retry with Wi-Fi up, or
with port00 disabled in the DT); `dockchannel-hid` or `apple-mtp` errors (the trackpad path);
`dwc3-apple`/`apple-t6050-dp-phy` errors (Type-C).

### S3: + late and noirq (`pm_test=platform`)

```sh
bash /boot/s2idle-step.sh s3
```

Adds `suspend_late` and `suspend_noirq`. This is where genpd switches off every power domain whose devices
are all suspended (and `pmgr-pwrstate` notes `system_sleep`), so this is the step that finds a block that
loses its firmware or state. Expected as S2 plus the late/noirq `pm_print_times` pairs before
`PM: suspend debug: Waiting for 5 second(s).`
Specific failures: an SError or a dead device on resume (`dwc3-apple ... Failed to assert reset`, USB gone
after resume, `apple-t6050-dp-phy ... dummy PIPE park failed`): an ATC domain was switched off under the
PHY firmware. Candidate fix (a DT loop test), on ATC1 (and ATC2 with the right-port patch):

```dts
&ps_atc1_common { apple,sleep-retained; };
&ps_atc1_usb_aon { apple,sleep-retained; };
&ps_atc1_phymxwrap { apple,sleep-retained; };
&ps_atc1_usb { apple,sleep-retained; };
```

### S4: real s2idle

```sh
bash /boot/s2idle-step.sh s4                         # rtc if rtc0 has wakealarm, else button
bash /boot/s2idle-step.sh s4 --wake rtc --seconds 20 # = rtcwake -d rtc0 -m mem -s 20 (refused today)
bash /boot/s2idle-step.sh s4 --wake button --guard 150
```

`rtcwake -m mem -s 20` needs an RTC alarm that this kernel and DT cannot give (section 2), so the script
falls back to `echo mem > /sys/power/state` (mem = s2idle here) and waits for the power button or a lid
close/open; press it within `--guard` seconds or WD2 resets the Mac (which is also how a non-waking SoC
is recovered). Expected: S2/S3's suspend lines, then `PM: suspend-to-idle`, nothing while asleep, and on the
button `PM: Triggering wakeup from IRQ <n>` (the SMC mailbox), `Timekeeping suspended for <t> seconds`,
`PM: resume from suspend-to-idle`, the resume pairs, `PM: suspend exit`. `before/after s2idle_usage`
shows each CPU's s2idle entry count +1 (all 18, as on the J716c); `interrupts.diff` shows the SMC mailbox
IRQ. Specific failures: returns at once with `Wakeup pending` (an SMC notification or USB activity: retry
with nothing plugged in and on AC); never wakes on the button (SMC event not reaching `macsmc-input`; WD2
resets it); wakes but the panel stays dark (simpledrm has no suspend handling: check over ssh first).
Pass three times in a row before installing logind's stage S, then lid close/open with logind.

## 4. Order

1. Build the kernel with `s2idle-plan/0001` (and `hwmon/0002` if wanted) and the DTB to test with.
2. S0 once. 3. S1 (optional), S2, S3 on the base DTB: one variable at a time.
4. S2 and S3 again on the DTB with the right port (more devices in the suspend path).
5. S4 with the button, guard 150, someone at the Mac for the first run.
