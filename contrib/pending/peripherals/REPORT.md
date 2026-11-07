# J716s peripheral sweep (2026-11-07) — Studio-side, nothing booted

Drafts in `patches/linux/0001-0007`, `patches/linux-atc0-host/0001-0002`, `patches/m1n1/0028`, `tools/s2idle-drain.sh`,
pass lines in `TEST-PLAN.md`. Both J716s DTBs build with W=1 (only the pre-existing gpio@67700000 warning); hid-apple.c
and atc-t6050-dp.c compile; m1n1 kboot_aop.c compiles (not linked yet). Working copies: /Volumes/linux-cs/wt-periph
(branches j716s-peripherals, j716s-atc0-host), ~/Work/agents/peripherals-t6050/m1n1.

Two things to know now: F6 (Do Not Disturb) is mapped to KEY_SLEEP by the Magic Keyboard 2021 table and logind
suspends on it (kernel 0007 maps it to KEY_DO_NOT_DISTURB; until then `HandleSuspendKey=ignore` in a logind
drop-in). NVRAM writes, the per-unit ALS calibration and any boot-flash dump must never enter a repo (syscfg is
per-unit).

## Ranked by value per effort

| # | Item | Effort | Needed | Test |
|---|---|---|---|---|
| 1 | F6 suspend | XS | kernel 0007 | T1 attended |
| 2 | Charge limit | none | works today via charge_control_end_threshold (SMC CHLS) | T3 attended |
| 3 | AOP sensors (light, lid angle, accel, gyro) | S | kernel 0001-0003, m1n1 0028, ALS calibration from macOS | T2 loop + attended |
| 4 | s2idle power draw | none | tools/s2idle-drain.sh, one night on battery | T4 |
| 5 | NVRAM read-only | XS | kernel 0004 (superseded by contrib/pending/nvram, which passed NVRAM-RO) | done |
| 6 | SD reader | M | kernel 0005 done; m1n1 training of apcie0 port 1 not written | T6 |
| 7 | MagSafe charge state | XS | kernel 0006 (little beyond the SMC) | T7 |
| 8 | NVRAM writes / reboot to macOS | M, risky | board row + format check (contrib/pending/nvram) | later |
| 9 | ATC0 as a host port | M | linux-atc0-host 0001-0002 + an m1n1 without the ATC0 gadget | T8 |
| - | Hibernate | not feasible now | spin-table CPUs cannot go offline; iBoot restarts every coprocessor on resume; needs an m1n1 PSCI monitor + restore paths | - |

## Facts

- SD reader: Genesys Logic GL9755 on apcie0 port 1 (same controller as the N1), Gen1, PERST# GPIO 81, CLKREQ# GPIO
  77, own DART dart-apcie1 at 0x411000000 IRQ 1532 stream 1, port IRQ 1531, power from SMC pcIO line 0x19; driver
  sdhci-pci-gli (MMC_SDHCI_PCI built in by 0003). m1n1 must train the port: port table, pcIO 0x0019000000000001
  before PERST#, Gen1 on bus 2, n1_port_up() to accept vendor 0x17a0. Draft 0005 adds port + DART disabled.
- AOP: announces als/las/accel/gyro (endpoints 0x29/0x28/0x24/0x25); nothing binds (no DT children, drivers
  modules outside the list). Light sensor VD6286 (Aurora Rust driver, needs per-unit apple/aop-als-cal.bin from
  macOS `ioreg -r -a -n als -l`); accel/gyro calibration in the ADT (m1n1 0028 = port of Aura's
  dt_set_aop_motion_cal); lid angle needs none. Pattern to copy: T6040/T6041. Risk: untested VD6286 path on this
  AOP firmware; a lock-up loses audio for that boot.
- Function row: fnmode=3 gives media keys first; row = brightness down/up, KEY_SCALE, KEY_SEARCH, KEY_MICMUTE, F6
  (KEY_SLEEP bug), media, volume; Globe = KEY_FN; no keyboard-backlight keys; brightness keys need the DCP backlight.
  Touch ID = SMC button 0x06 -> KEY_POWER (wakes from s2idle); no biometrics.
- Charging: macsmc-ac online + input_power_limit (64.8 W; the brick is 65 W PD at 20 V / 3.24 A); no
  voltage/current keys on this firmware. macsmc-power charge_behaviour: auto, auto-discharge only; start/end
  thresholds via CHLS; no inhibit/force-discharge keys (CHTE, CH0C, CH0I absent). MagSafe controller hpm5
  (SN201202x), draft 0006 without a connector (attach state + PD mode only).
- ATC0 host: the PHY driver refuses port 0 by policy (Aurora 0f9fd9812faf) because the gadget tether lives there;
  ATC0 blocks = ATC1 minus 0x8000000, identical tunables. Needs: retire the tether, an m1n1 without the ATC0 gadget,
  branch linux-atc0-host (0001 opt-in apple,boot-link-released, 0002 t6050-j716s-atc0-host.dts); m1n1 0021 fills
  the tunables once the node exists.
- NVRAM: anvram 0xc0000 at 0x700000 (smaller than the M4 boards' 1 MiB); see contrib/pending/nvram.
- Hibernate: not feasible now (above). s2idle: no rtcwake (RTC alarm needs the PMIC interrupt, SPMI polled);
  s2idle-drain.sh reads charge/voltage, the suspended time, wakeup sources and SMC PSTR/PDTR/PHPC.
- /arm-io nodes with no Linux node: driver exists (DT only): i2c0, i2c4 (SD sideband), i2c5 (lid angle, AOP's),
  i2c6/7/8 (retimers, backlight IC, HDMI converter: TB/DCP/extdisp owners), uart0, sio, error-handler, nub-spmi2/3,
  aop-spmi0 (NFC), apcie*-piodma, nub-gpio0, pmp0, SEP/Touch ID, dp2hdmi-gpio0. Nothing in Linux: aes, aop2,
  aon-ptd, eic, secure-repair, debug blocks, aic-timebase, event-log-handler, apple-processor-trace, msg/msghub,
  timesync, fillmore, smctempsensor0, mtp-aop-mux, dynamic-pil, displaymanager, sapt.
