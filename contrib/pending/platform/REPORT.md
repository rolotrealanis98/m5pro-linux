J716s (M5 Pro, T6050) platform/power design: report (2026-11-04, compile-checked only, nothing run on the M5)
(Written as .txt: the tool permission layer refused REPORT.md.)

Tags: [ADT] J716s runtime ADT (hardware-description properties only); [dump] J714s SMC key dump;
[log] ~/Work/m5-logs; [code] kernel tree; [compile]; [inferred]; [guess]; [web].

== Bottom line
- Keyboard backlight: plain PWM, as on every Asahi MacBook. ADT /arm-io/pwm0/kbd-backlight on fpwm0 @ 0x505040000
  (PMGR FPWM0 = ps_fpwm0), 25 kHz -> pwms = <&fpwm0 0 40000> + pwm-leds "kbd_backlight". Needs DT + PWM_APPLE=y
  (asahi.config has =m; the rootfs has no modules). [ADT][compile]
- Power-off: built-in SMC power-off, restart kept on the watchdog. New DT flag apple,poweroff-only (kernel 0040) and
  no PMU scratchpad cells. That removes both reasons omarchy-m5 kept smc_reboot disabled (SMC 'phra' restart
  outranking the wdt; unverified PMIC offsets). [code][compile]
- Thermal: /sys/class/thermal was empty only because no DT zones exist. Stage A adds 7 monitoring-only zones on
  macsmc-hwmon temperatures (no trips, no polling) and 3 cpufreq cooling devices. Stage B (separate patch) adds
  passive 95 C trips on the P and M clusters after the hardware agent identifies the SoC keys. Fans stay with the
  SMC (it ran them at stage 0 with no OS). [compile]
- ALS: not feasible yet; report only. The J716s AOP routes through an exclave (iop-aop-nub routes ->
  aop-exclave-mailbox, SecureRTBuddyAOP). Asahi's AOP stack is Rust (RUST is off in this build) and knows no M4/M5
  AOP. No DT shipped. [ADT][code]
- s2idle: plausible as a functional "freeze" (no hotplug needed, wake IRQs survive). Zero CPU power saving while
  idle=nop stays. One concrete hang found in advance: genpd's sleep power-off writes PMGR registers of auto-gated
  domains, which hangs the T6050 bus. Kernel 0042 skips PMGR writes in system sleep on T6050. Staged plan in
  TEST-PLAN (freezer -> devices -> platform -> real), ordered last.

== Deliverables (~/Work/agents/platform)
- patches/linux/0040-power-reset-macsmc-reboot-add-apple-poweroff-only.patch (kernel): apple,poweroff-only
  registers only the power-off(-prepare) handlers; the notifier ignores SYS_RESTART; binding makes nvmem cells
  optional.
- patches/linux/0041-hwmon-macsmc-keep-temperature-channel-numbers-stable.patch (kernel): a missing temperature key
  keeps its channel (label "<node> absent", no input), so thermal-sensors = <&smc_hwmon N> cannot shift.
- patches/linux/0042-pmdomain-apple-leave-T6050-domains-alone-in-system-sleep.patch (kernel):
  pmgr_pwrstate.sleep_power_off (-1 auto = keep domains on in system sleep on T6050 only, 0 never power off,
  1 always); a skipped power-off also skips the matching power-on.
- patches/omarchy-m5/0001-j716s-keyboard-backlight-smc-poweroff-thermal-zones-stage-A.patch: new
  dt/t6050-j716s-platform.dtsi (fpwm0, pwm-leds, &smc_reboot, hwmon channels, zones, #cooling-cells); one #include
  in t6050-j716s.dts; new configs/omarchy-platform.config; build-kernel.sh installs/merges the optional platform
  files (KCONFIG_EXTRA), with hunks placed outside the lines the USB agent's 0001 rewrites.
- patches/omarchy-m5/0002-j716s-thermal-trips-and-cpu-cooling-maps-stage-B.patch (on 0001):
  dt/t6050-j716s-thermal-trips.dtsi, passive 95 C / hot 105 C on cpu-p and cpu-m, battery hot 50 C (notify only).
- build/t6050-j716s.dtb: stage A, on top of SMC 0001, trackpad AFE DT, cpufreq 0001 and USB 0001.
  sha256 7bf15d91b3120b5ec6c2d0fae41554b37a787186fc0d4fc5db082e6aaa7a7bf6
- build/t6050-j716s-thermal-stageB.dtb: stage B (compile check / TEST-PLAN T4).
  sha256 2a9c8bd2feb2b25a4686c194e2b491916bcba96ac11805210987c0c0ade2fd98  (build/SHA256SUMS, build logs alongside)
- userspace/ (README.md has install paths): logind safe default, sleep.conf "no sleep", staged logind/sleep files,
  kbd udev rule, Hyprland binds, m5-temps, optional m5-fan-floor + service (not enabled).
- NOTE-AOP-scope-for-audio-agent.md: written scope split (audio: mic; platform: ALS/LAS) plus shared AOP facts.
- TEST-PLAN.md: staged plan, rollback R1-R3, hang-risk steps last.

Verification: worktree /Volumes/linux-cs/wt-platform (236788cd2 + main-tree diff + SMC 0010-0012 + 0040-0042).
- W=1 LLVM=1 builds of macsmc-reboot.o, macsmc-hwmon.o, pmgr-pwrstate.o, pwm-apple.o, leds-pwm.o: no warnings.
- t6050-j716s.dtb (A and B) and t6050-j714s.dtb with W=1: no warnings from these files. The only warnings are
  unit_address_vs_reg on gpio@67500000/gpio@67700000, which come from the trackpad DT patch.
- Kernel patches pass git apply --check on pristine 236788cd2, and are applied in the worktree. cpufreq 0001/0002,
  trackpad 0001 and USB 0001-0003 still apply on top.
- omarchy patches pass on j716s @ 2c87598. They stack with SMC 0001/0002, trackpad DT, cpufreq 0001 and USB 0001
  in either order with identical results.
- Config merge: only the intended symbols change; HIBERNATION off removes its sub-options.
- checkpatch: only "missing Signed-off-by" and "binding in a separate patch".
- Initcall names: macsmc_reboot_driver_init, apple_pwm_driver_init.
- Remove the worktree: git -C /Volumes/linux-cs/linux worktree remove --force /Volumes/linux-cs/wt-platform

== 1. Keyboard backlight
- Asahi M1-M4: pwm-leds on an apple,s5l-fpwm (drivers/pwm/pwm-apple.c), 40000 ns period, 255 steps,
  default-state "keep". Boards: t8103-j313/j293, t600x-j314-j316 (fpwm0), t8112-j413/j415/j493,
  t603x-j514-j516 (fpwm0), t8122-j504/j613/j615, t8132-j604/j713/j715 (fpwm1). No SMC involvement. [code]
- J716s [ADT]: /arm-io/pwm0 compatible "fpwm,s5l8920x", reg 0x505040000+0x4000 (SIO block), clock-gates 187 = FPWM0
  (ps 0x2809002a8, parent SIO). Child kbd-backlight: device_type "pwm0", reg 0 (channel), default-hz 25000, plus
  nits-to-pwm tables (macOS curve, unused). /arm-io/pwm1 ("pwm,s5l8920x", FPWM1) repeats the same reg and has no
  consumer, so it is not described. ps_fpwm0 handover 0x244 = clock-gated, no auto-PM, so the first genpd power-on
  is an ordinary write. ps_fpwm0 already exists in t6050-pmgr.dtsi. No LKSB/KBLR-style key in the SMC dump. [dump]
- The built-in M5 keyboard has no keyboard-light keys: userspace/hypr gives SUPER+F5/F6 via brightnessctl.
  systemd restores the level across boots.

== 2. Ambient light sensor (report only)
- Asahi: AOP driver drivers/soc/apple/aop.rs (Rust, RTKit + AFK/EPIC); ALS/LAS are IIO drivers
  (drivers/iio/common/aop_sensors/aop_als.rs, aop_las.rs) under an aop node (t6030.dtsi:1057 pattern). They need
  apple/aop-als-cal.bin, which asahi-installer takes from macOS ioreg als CalibrationData (asahi_firmware/als.py).
  aop.rs matches t8103/t8112/t6000/t6020 only, rewrites the AOP bootargs in AOP SRAM and sets ASC CPU_RUN at probe.
  No M4 tree (t8132) has an AOP node.
- J716s [ADT]: /arm-io/aop ("iop,ascwrap-v6", AIC 578-581); iop-aop-nub (rtbuddy-v2, firmware "mac17jaop",
  pre-loaded, no-shutdown, firmware-type "scrt") with children aop-audio, aop-voicetrigger, als, accel, gyro and
  filters. Its "routes" points at /arm-io/aop-exclave-mailbox ("iop,secure-rtbuddy-proxy", service
  com.apple.service.SecureRTBuddyAOP); dart-aop has exclave SIDs and a mapper-exclave-aop. The als node holds only
  device_type and harmony-db-version 3.
- Verdict: blocked, for three reasons:
  (1) CONFIG_RUST is off in the macOS-hosted LLVM build.
  (2) An M4+ AOP is partly exclave-owned (sensor/mic privacy I/O moved into exclaves on M4/A18 [web]). Writing AOP
      SRAM/ASC from the AP could fault or fight the exclave.
  (3) No calibration path has been tested.
  Next step is read-only: does the non-secure RTKit endpoint set on this AOP still announce an "als" EPIC service?
  That needs an AOP-aware probe in the m1n1 proxy, not a kernel driver.
- Scope split with the audio agent is written in NOTE-AOP-scope-for-audio-agent.md.

== 3. Thermal
- Asahi approach: macsmc-hwmon (HWMON_C_REGISTER_TZ) only; no Apple DT has thermal-zones; fans are left to the SMC.
  One Asahi user reported M1 Max fans not ramping under Linux load, then throttling and freezing [web], so "the SMC
  handles it" is not proven.
- Already mapped by the SMC agent: the hwmon-common/laptop/fan-dual keys, the F0md/F1md fix (DT + 0010), and 4
  temperatures (TH0x, TB0T, TCHP, TW0P). dmesg already reports those 4 as "not attached to any thermal zone". [log]
- Added in stage A:
  * #thermal-sensor-cells on &smc_hwmon. Channel order is pinned: TH0x, TB0T, TCHP, TW0P = 0-3, so temp1-4 do not
    move.
  * 8 candidate keys after them: Tp00, Tp0C (P cluster), Tm00, Tm1E (M clusters), Tg08 (GPU), Ts00, TPMP, TCMb.
    All are flt in the J714s dump. Key families: Tp* 25 keys, Tm* 44, Tg* ~40; the M5 has "M" and "P" cores,
    hence Tm/Tp. [dump; the meaning is a guess]
  * Zones nand/battery/charger/wifi/cpu-p/cpu-m/gpu with polling-delay 0 and no trips: values are read on demand,
    there is no background SMC traffic, and nothing acts on them.
  * #cooling-cells on all 18 CPUs. apple-soc-cpufreq sets CPUFREQ_IS_COOLING_DEV, so cooling devices
    cpufreq-cpu0/6/12 appear.
- Stage B (patch 0002, after TEST-PLAN T1/T3): polling 1000/250 ms; passive 95 C -> P cluster or both M clusters;
  hot 105 C (notify only); battery hot 50 C (notify only). No critical trips until power-off is verified: a
  critical trip triggers an orderly power-off, and without a handler that only halts with all cores spinning.
- Fan default: SMC automatic, macsmc_hwmon.fan_control=0. The optional userspace m5-fan-floor (linear floor
  80-95 C; target 0 hands control back on cool-down and on exit) is only for the case where T1/F1 shows no ramp.
- Under idle=nop all cores busy-poll, so idle temperatures are higher than on macOS; cpufreq is the only lever.

== 4. Power button / lid / power-off / reboot
- Why omarchy disabled smc_reboot (t6050-smc.dtsi comment, omarchy-smc.config): its restart handler
  (SYS_OFF_PRIO_HIGH 192) outranks apple_wdt (128), and an SMC 'phra' restart is not shown to land in stage-1 m1n1.
  It also writes boot_stage/shutdown_flag into PMIC scratch, whose T6050 offsets are inferred.
- Design:
  * apple,poweroff-only (0040) leaves restart exactly as it is today.
  * The board DT deletes the nvmem cells, so no PMIC write happens (boot_stage also feeds iBoot's boot-failure
    accounting).
  * Power-off path: the reboot notifier writes MBSE=offw, the prepare step puts the SMC in atomic mode, then
    MBSE=off1. MBSE is hex_ 4 and writable in the dump.
  * Risk: on M1, off1 without shutdown_flag reboots instead of powering off. TEST-PLAN P1 finds out; P5 adds
    shutdown_flag alone if needed.
  * Escape hatch: initcall_blacklist=macsmc_reboot_driver_init
- Power button and lid: macsmc-input already reports KEY_POWER (bHLD; ADT /buttons function-button_hold is SMC key
  bHLD) and SW_LID (MSLD). With a power-off handler in place, the long-hold event now runs kernel_power_off()
  instead of a watchdog restart.
- logind and sleep:
  * 10-m5pro-safe.conf ignores the power key, lid and sleep keys (the SMC agent's warning); sleep.conf refuses all
    sleep.
  * Stage P (after P2): power key and lid lock the session.
  * Stage S (after S6): lid/power -> suspend, SuspendState=freeze.
- Kconfig: set POWER_RESET_MACSMC=y only together with kernel 0040. Without 0040 the flag is ignored and SMC restart
  takes over. HIBERNATION off; PM_DEBUG on for pm_test.

== 5. s2idle readiness map (component: today | needs | M1-M3/public | risk)
- CPU idle: idle=nop + arm64.nowfxt (m1n1 kboot, M4+); cpuidle-apple does not register | nothing for function:
  s2idle falls back to default_idle_call, which returns at once, so cores busy-poll and IRQs still wake; no power
  saving | M1-M3 use WFI + a cpuidle deep state | no functional risk; deep idle is open RE (WFI loses state on M4+)
- CPU hotplug: spin-table with no cpu_die, so secondaries cannot go offline (no online file) | s2idle does not
  offline CPUs; mem (no PSCI) and hibernation would, so HIBERNATION is off | Asahi offers only s2idle [web] |
  NEVER: RVBAR is locked to the stage-1 base, and the m1n1 0015 trampoline covers boot only
- PMGR/genpd: 69 always-on domains; the driver puts active domains under auto-PM; a PMGR write to an auto-gated
  domain hangs the bus (omarchy 0003) | the noirq genpd power-off/on would write ps_ans, ps_fpwm0, i2c*, uart0,
  spi*; 0042 skips PMGR writes in system sleep on T6050 | genpd power-off is fine on M1-M3 | HANG without 0042
- SMC: no PM ops; the RTKit workqueue is not freezable; mailbox IRQs are IRQF_NO_SUSPEND | it stays up and delivers
  power-button/lid events as wakeups (macsmc-input device_init_wakeup); the macOS-style SMC sleep handshake is not
  implemented (only matters for real low power) | same on Asahi | low
- Wake sources: ADT smc-pmu event bits pwrbtn 0, lid 8, sdconn 9, charger 11, wifibt 13, trackpadkeyboard 35,
  acattach 40, USB-C_plug 42, USB2_wake 44, rtc 48 | power button and lid work via macsmc-input; keyboard/trackpad
  cannot wake (dockchannel-hid has no PM) and neither can the RTC (rtc-macsmc has no alarm) | same driver set on
  M1-M3 | no wake = hang until a power hold
- Display: simpledrm on the m1n1 framebuffer; no DCP driver; the framebuffer node has no power-domains | nothing;
  the panel stays lit during s2idle | the DCP driver blanks it on Asahi | none (DCP agent owns blanking)
- NVMe (ANS2): nvme-apple suspend shuts the ANS down over RTKit and resume reboots it | ANS re-boot after shutdown
  is untested on T6050 (ANS2/NVMMU/SARTv4) | works on M1-M3 | HANG (root gone); test with the root read-only
- USB: dwc3 gadget (EEM, the only SSH path); tipd polled (USB agent) | the gadget link drops and re-enumerates;
  the tipd poll work keeps running | fine on M1-M3 | access loss, not a hang
- SPMI/PMIC: gen 4 polled, no PM | nothing | - | low
- Watchdog: apple_wdt suspend/resume stops and restarts it | fine | same | low
- cpufreq: governors stop at suspend | fine | same | low
- Keyboard/trackpad: dockchannel-hid, MTP firmware, no PM ops; ps_nub_dock_channel is always-on | input must
  survive; it cannot wake | M2 driver has no PM either | low-medium
Staged order: S1 freezer -> S2 devices -> S3 platform -> S4 real (power button, then lid) -> S5 health -> S6 loops.
First experiment: echo freezer > /sys/power/pm_test; echo freeze > /sys/power/state
The cpufreq agent's "never test suspend" still stands for anything that touches idle states or hotplug. This plan
touches neither and keeps idle=nop arm64.nowfxt.

== 6. Upstream / community status [web]
- Asahi: the M3 family is nearing or at a downstream release. M4 base and A18 Pro device trees are submitted for the
  7.4 cycle. M4 Pro/Max and M5 are not offered; M5 is "lab" bring-up only.
  https://www.phoronix.com/news/Asahi-Linux-M3-Release-Soon
  https://www.macg.co/mac/2026/10/asahi-linux-prepare-le-noyau-demarrer-sur-les-mac-m4-et-le-macbook-neo-311421
  https://www.macg.co/macos/2026/08/asahi-linux-se-rapproche-dune-sortie-sur-les-mac-m3-et-progresse-deja-sur-les-m4-et-m5-310683
  https://borncity.com/news/linux-auf-m4-kernel-patches-ermoeglichen-nvme-unterstuetzung/
- omarchy-m5 upstream (betizzel): the README still says single-core, with no backlight/thermal/power-off/suspend
  work. https://github.com/betizzel/omarchy-m5
- aurora-silicon/linux: a hardware directory that tracks M5 Pro/Max/Ultra without claiming shared drivers.
  https://github.com/aurora-silicon/linux/discussions/70
- Asahi s2idle stance and sleep drain:
  https://discussion.fedoraproject.org/t/current-state-of-sleep-support-for-m1/86943
  https://discussion.fedoraproject.org/t/high-battery-drainage-during-sleep-on-m2/100026/2
- Fans not ramping under Asahi (single user report): https://vvcxhwvm.pages.dev/AsahiLinux/linux/issues/472
- macsmc hwmon upstream series:
  https://patchew.org/linux/20251007-macsmc-subdevs-v3-0-d7d3bfd7ae02@gmail.com/20251007-macsmc-subdevs-v3-6-d7d3bfd7ae02@gmail.com
- Exclaves own sensor/mic I/O from M4/A18:
  https://eclecticlight.co/2025/02/13/do-m4-chips-have-a-new-security-processor/
  https://9to5mac.com/2024/06/03/m4-ipad-pro-security-feature-apple-hasnt-told-anyone-about/

== Verified / inferred / guessed
- Verified (ADT/code/compile): the kbd-backlight PWM location, gate and frequency; no SMC kbd key; smc-pmu wake
  bits; AOP exclave routing; how macsmc-reboot/-input/-hwmon, genpd and s2idle behave with idle=nop; the build and
  patch application listed above.
- Inferred: the fpwm register layout is the same as M1-M4 (same ADT compatible); off1 behaviour without
  shutdown_flag; NVMe resume on T6050; the SMC keeps running the fans under Linux load.
- Guessed: which Tp/Tm/Tg keys are the cluster and GPU temperatures (TEST-PLAN T1 decides); the trip values.
