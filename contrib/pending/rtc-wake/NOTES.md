# rtc-wake: PMU RTC alarm interrupt on the J716s (2026-11-23)

Branch `j716s-rtc-wake` (worktree /Volumes/m5pro/wt/rtc-wake) = `j716s-ane2293` 0c6bb36ed14a + 6 commits, local, not pushed:
- 4 cherry-picks (-x, original author Joshua Warren) of aurora-silicon/linux#1743 (`w71/spmi-gen4-irq`, draft): gen4 SPMI
  takes its AIC interrupt (peripheral sources 0..255, ack/pending bank +0x600, mask bank +0x400, fault source 263 at +0x620 bit 7).
  Applied clean on our tree (the driver already carried the fault-queue drain and the J714s recovery).
- 1 cherry-pick of #2007's DT commit (nub-spmi0 = interrupt controller on AIC 726, `interrupt-controller`, `#interrupt-cells = <2>`).
- 1 own commit: the draft wired `smc_rtc` (rtc-macsmc); the J716s's alarm RTC is `apple-pmu-rtc` (`pmu_rtc` in
  t6050-j714s-sleep.dtsi), so that commit reverts the smc_rtc part and gives `pmu_rtc` `interrupts-extended = <&nub_spmi0 2 IRQ_TYPE_EDGE_RISING>`
  (it already has `wakeup-source`). rtc-apple-pmu.c needed no change: it already takes an optional IRQ, `dev_pm_set_wake_irq`, W1C ack in the thread.
- Source 2 = alarm: ADT spmi-abbeyL1 `interrupts` = <2, 62>; `info-rtc_alarm_event` 0x2000 mask 2, ctrl en 0x40, alarm mask 0x200e bit 0
  (all match the abbey table in rtc-apple-pmu.c); #1743's K114c probe: alarm sets +0x600 bit 2.
- Parent line: ADT nub-spmi0 IOInterruptSpecifiers[1] = 0x2d6 = 726 -> AIC (interrupt-parent[1] is the AIC phandle, the others are the
  controller itself: [0] = 256, the RX notification, and the fault/error sources 257..285; matches SPMI_GEN4_FAULT_IRQ 263).
- Leaf chip has IRQCHIP_SKIP_SET_WAKE; the chained parent has no action so s2idle's suspend_device_irqs leaves it live.

## apple_wdt s2idle fallback (answer)
`apple_wdt_arm_s2idle_wake()` (drivers/watchdog/apple_wdt.c) is only called from `apple_wdt_suspend()` when
`wdt->irq > 0 && s2idle_wake_s != 0 && target == PM_SUSPEND_TO_IDLE`. The WD1 fallback is armed inside it, and fires at
`min(s2idle_wake_s + s2idle_fallback_s, max)` seconds (relative to the wake being due, not to the suspend). So with
`s2idle_wake_s=0` (the default) nothing is armed, and `s2idle_fallback_s=60` does nothing: expected, not a bug.

## Unknowns the test must settle
- Awake 2026-11-23: after `+8` the PMIC event read `alrm_pending: no`. #1743 saw the alarm latch +0x600 bit 2 on a K114c; the first test
  dumps the banks (dump-spmi.py) at t+4 and t+12 to tell "PMIC event never sets" from "controller latches, AIC line does not rise".
- Whether +0x400 bit 2 gates the AIC line (not measured upstream).
