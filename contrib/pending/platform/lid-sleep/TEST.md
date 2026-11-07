# Lid-close sleep on the J716s: the false lid-open (2026-11-07)

(Saved by the coordinator from the agent's hand-back.) Tree j716s-series c2e1be601fb4 (= the daily 7.3.0-gf080637018df).

## Cause
The SMC firmware itself emits the "lid open" HID event (`03 00 01` in its syslog, 0x72030001 as the notification) about
230 ms after the close while the lid is physically shut, once the AP starts suspending; macsmc-input decodes it correctly
(type 0x7203 = lid, middle byte = closed flag) and reports it as a hard wakeup (`pm_wakeup_dev_event(dev, 0, true)` while
`wakeup_mode` is set between `.prepare` and `.complete`), so the suspend aborts; logind then reads "Lid opened".
Linux sends the SMC nothing at suspend (no PM callbacks in macsmc.c, no sleep key; the MTP helper sends nothing in
s2idle; dockchannel-hid only suspends the HID layer). The MTP "enter Dependent Mode" at the same instant is the trackpad
coming back on because it was told the lid opened (the AFE is driven over SMC gp1c on the J716s), i.e. following the
SMC, not causing it. Working hypothesis: the SMC's lid state depends on the system's sleep state; macOS tells the SMC
about sleep, Linux does not (protocol unknown). Upstream behaviour (Hector's driver + Janne's s2idle fix), same in
edimoldovan's and betizzel's trees; why betizzel's J714s sleeps 23 s on lid close is unknown (its AFE reset is in firmware).

## Options
(a) re-read the SMC lid key `MSLD` before trusting an open report during suspend (in the patch); (b) ignore an open report
in the first N ms of the sleep measured with CLOCK_BOOTTIME (monotonic stops in s2idle) - in the patch as
`macsmc_input.lid_wake_settle_ms=2000` (0 disables); (c) ordering/filtering: not possible (the false event equals a real
opening); timers cannot debounce (tick frozen in s2idle).

## Patch (worktree /Volumes/linux-cs/wt-lid, branch j716s-lid-sleep, 82a7d71d217e; patches/0001; only macsmc-input.c)
`macsmc_input_lid_wake_ok()` reads `MSLD` inside the notifier (safe: SMC replies are handled in recv_early from the
mailbox IRQ thread); a refused open report produces no input report and no wakeup; `.prepare` records the sleep start;
`.complete` re-reads `MSLD` after any wakeup; `lid_lock` serialises; every decision is logged with event, time into sleep
and MSLD. Limits: if MSLD also says open, the lid alone may not wake (use a key, the trackpad or the power button); a
close-then-open within 2 s while entering sleep does not wake; the SMC still sends the false event.
Kernel: /Volumes/linux-cs/wt-lid-out Image.gz 7.3.0-g82a7d71d217e (sha256 cf4c2d3f...); payload
`payload/lid-sleep-20261107-d332cf88.bin` (battery, selftest on, stack DTB).

## Userspace-only interim workaround
`/usr/lib/systemd/system-sleep/50-j716s-lid-wake` (0755): on `pre`, if logind says LidClosed, write `disabled` to
`/sys/bus/platform/devices/macsmc-input/power/wakeup` and touch a marker; on `post`, re-enable. Then neither the lid
nor the power button wakes that sleep (dockchannel-hid wakeup is separate: a key or trackpad click wakes); logind still
logs "Lid opened" on resume. `HoldoffTimeoutSec` does not help; an inhibitor only blocks the suspend.

## Test (attended)
Deploy the payload (prev = the daily); check `uname -r` = 7.3.0-g82a7d71d217e and
`/sys/module/macsmc_input/parameters/lid_wake_settle_ms` = 2000; `echo 1 > /sys/power/pm_print_times; echo 1 >
/sys/power/pm_debug_messages`; `echo LIDTEST > /dev/kmsg`; close the lid >= 30 s; open; expect `macsmc-input: lid open
72030001 at +~150 ms in sleep, MSLD=...: ignored|no wakeup`, `Timekeeping suspended for >= 20 s`, resume within 2 s of
opening, suspend_stats success +1. Readings: `MSLD=1 ... ignored` + an SMC `03 00 01` and a wakeup on opening = pass;
`MSLD=0 ... no wakeup` and no event on opening = SMC state stuck at open, sleep survives but the lid does not wake it
(key wakes; partial pass, needs the SMC sleep protocol); still waking at 0.7 s = look at `last active wakeup source`.
Control: `lid_wake_settle_ms=0` should reproduce the old behaviour if MSLD agrees with the event.
