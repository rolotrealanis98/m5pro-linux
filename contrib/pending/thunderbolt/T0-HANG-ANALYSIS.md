# Thunderbolt T0 kernel hang in deferred probe (2026-11-08) — static analysis, bisect set prepared

pid 1 hung in the FIRST `flush_work` of `deferred_probe_initcall` (`drivers/base/dd.c`, return +0xd8), before
`initcalls_done`, so `deferred_probe_timeout=` and fw_devlink relaxation cannot help (they act after the flush). The
worker on `system_dfl_wq` was spinning, sleeping killably or looping on bounded waits (only pid 1 was reported; soft/hard
lockup and WQ_WATCHDOG are off, PREEMPT=y). Known-good I1 used the same m1n1, bootargs and initramfs, so the cause is the
kernel delta (a0f2f30c967b..121f7cde7d92: apple-dart, pcie-apple, the t6050 PHY, reset-apple-cio, thunderbolt/apple.c,
t6050-max.dtsi, j716c.dts), the config delta (USB4, USB4_APPLE_SOC, USB4_CONFIGFS, BLK_DEV_NVME, IGC, R8169 =y;
HOTPLUG_PCI_PCIE, TIGON3 =y) or the DTB delta (10 pmgr power-controller nodes, 2 pin groups, 2 mailboxes, acio@381ac0000
enabled, acio@2a9ac0000 disabled, pcie-tunnel containers).

Per node at T0: acio2 defers before its driver runs (pinctrl-0 -> disabled pinctrl_aop; atc2_cio_auss parent `auss`
disabled; type7 would fail -EINVAL "Missing bootloader RC tuning"); acio children not instantiated; pcie-tunnels skipped;
cio-reset trivial; mailboxes benign; the 10 pmgr nodes probe with bounded polls but power on atc2_common/atc2_cio/
atc1_common/atc1_cio for the first time via PD_FLAG_ATTACH_POWER_ON (CIO domains on with the PHY not in CIO mode, which
apple.c:3523-3531 says must not happen) and `*_cio_auss` defer forever with add/teardown each pass. Ranked candidates:
(1) the new pmgr domains, (2) kernel/config delta independent of the DT, (3) acio2 deferral via fw_devlink/pinctrl +
genpd virtual devices, (4) mailboxes. Unbounded waits in the TB path for T1/T2: apple.c:2209, 2263, 2295
`wait_for_completion(&domain_released)`.

Bisect set (~/Work/agents/tb-j716s/incident/bisect/, built, not booted; T0 kernel unchanged): K0 daily DTB (hang =
kernel/config), D1 pmgr nodes + pin groups only, D2 ATC2 domains only, D3 mailboxes only, bis-none control, norouter
(pmgr + mailboxes on, acio off). Attended capture if it hangs: `initcall_debug ignore_loglevel printk.time=1
log_buf_len=8M`, photograph before ~370 s (first hung-task report at ~242 s), SysRq-t/l for the kworker stack.

Why no reset: stage 1 arms the watchdog (`m1n1.wdt=keep`), apple_wdt sees RESET_EN (WDOG_HW_RUNNING, 30 s),
CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y + CONFIG_WATCHDOG_OPEN_TIMEOUT=0 make the core feed it forever from `watchdogd`
until userspace opens /dev/watchdog0 (RuntimeWatchdogUSec=0 on the daily: nothing opens it). Safety options:
A. `watchdog.open_timeout=N` on the cmdline (no rebuild): after N s without a userspace open the core stops feeding, the
   dog bites within 30 s, stage 1 falls back; needs an opener in the test initramfs (`exec 9<>/dev/watchdog0` + a 10 s
   pet loop) or RuntimeWatchdogSec=60 on the daily; never send the magic close. N=300 safe (ssh at ~80 s).
B. CONFIG_BOOTPARAM_HUNG_TASK_PANIC=1 (+ DEFAULT_HUNG_TASK_TIMEOUT=60): panic at ~2x timeout, restart via apple_wdt
   skipping the macsmc notifier so boot_stage stays set and the A/B fallback triggers; does not catch a spinning worker.
Recommendation: A for every test payload, B for bring-up kernels.

Fix regardless of root cause: in t6050-max.dtsi set acio2, acio2_mbox, ps_atc2_cio_auss, ps_atc1_cio_auss to
`status = "disabled"` (as acio1 is) and enable them with their suppliers in t6050-j716s-usb4.dtsi / j716c.dts; T0 then adds
only live pmgr domains and one mailbox. Order: K0, then D1/D2/D3, then full T0. T1 takes a different path (real
apple_cio_start, NHI completions) but inherits a kernel/pmgr hang if K0 or D1 hangs: do not run T1 before them. Held
until Rolando is home (attended).
