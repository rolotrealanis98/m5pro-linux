# SMC on M5 Pro (T6050, J716s): report (2026-11-04, agent output, compile-checked only)

Kernel base: asahi-wip-7.2 @ 236788cd2602 + omarchy-m5 patches/linux/0001-0009. DT base: omarchy-m5 j716s @ 2c87598.

## Bottom line
- Already wired: SMC mailbox + RTKit core, RTC, lid/power-button input, hwmon and GPIO are `=y` and in the DT.
  The first SSH diagnostics (arch-diag-20261104-174838) show macsmc RTKit protocol 12 initialising, macsmc-rtc
  registered as rtc0, the "Apple SMC power/lid events" input device, macsmc-gpio "First GPIO key: gP01";
  /sys/class/power_supply and /sys/class/thermal empty (macsmc-power was =m and no modules load).
- A successful SMC probe prints only `macsmc 28c600000.smc: RTKit: Initializing (protocol version N)`.
- Two real bugs, fixed:
  1. Both fans dropped from hwmon: T6050 SMC has F0md/F1md, not F0Md/F1Md; macsmc-hwmon treats a missing optional key as
     fatal for the whole fan. Fixed with a board DT override and a driver patch (0010).
  2. SPMI resource too small for gen 4: FIFO registers at 0x200-0x220 outside the 0x100 reg (worked only because 16K
     ioremap pages cover them). The RTC depends on this via the PMIC nvmem. reg is now 0x4000 (ADT size).
- The macsmc-power panic of 2026-10-02 was never read. One crash-capable race fixed (0011: work items initialised before
  the notifier registers); nothing proves it was the panic. macsmc-power is now `=y`, gated by
  `initcall_blacklist=macsmc_power_driver_init` until TEST-PLAN T6 passes.
- WARNING: on the full Omarchy rootfs systemd-logind acts on the new power key (power off -> only halts, no SMC poweroff
  handler) and lid (suspend). Test in the initramfs or set logind to ignore them.

## Deliverables (this folder)
| File | Applies to | What |
|---|---|---|
| patches/omarchy-m5/0001-dt-t6050-smc-spmi-window-and-fan-mode-keys.patch | omarchy-m5 | t6050-smc.dtsi SPMI reg 0x100 -> 0x4000; j716s/j714s `&smc_hwmon` fan `apple,fan-mode = "F0md"/"F1md"` |
| patches/omarchy-m5/0002-configs-omarchy-smc-build-in-macsmc-power.patch | omarchy-m5 | CONFIG_MACSMC_POWER=y, gate documented |
| patches/linux/0010-hwmon-macsmc-keep-fans-with-missing-optional-keys.patch | kernel | missing min/max/target/mode key warns and drops only that attribute |
| patches/linux/0011-power-supply-macsmc-power-init-work-before-notifier.patch | kernel | work items initialised before blocking_notifier_chain_register |
| patches/linux/0012-mfd-macsmc-initialise-spinlock.patch | kernel | spin_lock_init(&smc->lock) |
| build/t6050-j716s.dtb | - | patched DTB, sha256 2ef777a0...6860 |

Compile verification: worktree /Volumes/linux-cs/wt-smc; both T6050 DTBs and macsmc.o, macsmc-hwmon.o, macsmc-power.o,
rtc-macsmc.o, macsmc-input.o, gpio-macsmc.o, spmi-apple-controller.o, apple-spmi-nvmem.o build with W=1, no warnings;
patches pass `git apply --check`. initcall names (LTO_NONE, KALLSYMS=y): apple_smc_driver_init, macsmc_power_driver_init,
macsmc_hwmon_driver_init, macsmc_rtc_driver_init, macsmc_input_driver_init, macsmc_gpio_driver_init,
apple_spmi_driver_init, apple_spmi_nvmem_driver_init. Remove the worktree with
`git -C /Volumes/linux-cs/linux worktree remove --force /Volumes/linux-cs/wt-smc`.

## Per feature (evidence: J714s m1n1 SMC key dump docs/research/smc-keys-j714s.json, 3485 keys; not re-dumped on J716s)
- SMC core: smc_mbox (asc-mailbox-v4, AIC 899-902), smc sram 0x28de00000+0x140000; driver drivers/mfd/macsmc.c.
- Battery/charger (macsmc-power, MFD cell): keys B0AV/AC/AP/FC/DC/RM/CT/AT, BUIC, BSFC, CHCE, CHCC, CHNC, CH0R, CHSC, CHIS,
  ACPW, ACSt, BITV, BVVN, BAAC, BBAD, BMDN/BMSN/BMDT, BNCB, CHLS, CHTE present; CH0C/CH0I/CH0K/CH0B, CHWA, AC-n, AC-i absent
  (handled). BCF0 is 4 bytes -> pre-27 path, B0RM byte-swapped (20503 -> 5968 mAh vs B0FC 6242, consistent).
- Lid/button (macsmc-input): MSLD, bHLD, NTAP present; event IDs 0x7203/0x7201 inferred from M1-M3. Holding the button ~4 s
  triggers forced shutdown -> kernel_restart via wdt.
- Fans (macsmc-hwmon): F0Ac/F1Ac, F0Mn/F1Mn, F0Mx/F1Mx (7826), F0Tg/F1Tg writable, F0md/F1md (ui8); control needs
  `macsmc_hwmon.fan_control=1` (taints). F0md = manual flag is inferred from one community source.
- Thermal: Asahi hwmon includes map TH0x, TB0T, TCHP, TW0P, PSTR/PDTR/PMVR/PHPC, VD0R, SBAV, ID0R; ~285 T* keys unmapped.
- RTC (rtc-macsmc): CLKM + PMIC offset over SPMI gen 4, nvmem cell rtc_offset 0x2100/6 on abbey USID 0xe.
- Unchanged: smc_reboot disabled, POWER_RESET_MACSMC=m (poweroff halts, restart via wdt); no smc_gpio_low node.

## M3/M4 trees
M3 (t6030/t6031/t8122) are the template; no M4 tree has an SMC node (t8132 here, AsahiLinux apple-soc/dt-7.5). T6050
differs: SPMI gen 4 only (0x200+, polled), abbey PMIC USID 0xe (socd 0x1800), sram 0x140000, F*md keys, reboot disabled,
no gpio-low.

## Verified / inferred / needs ADT
- Inferred: Linux RTKit handshake on this firmware (now seen working in the diag), lid/button event IDs on M5, F0md
  semantics, the panic cause, SPMI gen 4 polled transfers, J716s capacity ~8.4-8.8 Ah.
- Needs J716s ADT (no serials): /arm-io/smc reg+interrupts, iop-smc-nub region-base/size, nub-spmi0 reg/gen/interrupts,
  spmi-abbey reg (USID), info-clock_offset / info-rtc_scrpad / info-leg_scrpad. The ADT dump exists privately at
  ~/Work/studio-artifacts/adt-runtime-j716s.bin.
- Needs J716s SMC key dump (smc-proxy-probe.py): F0md/F1md, F1* fan keys, TCHP/TW0P/SBAV/TH0x, BCF0 size, B0RM order.

Source for the fan key casing: thermo-control-mcp (glama.ai/mcp/servers/june4432/thermo-control-mcp).
