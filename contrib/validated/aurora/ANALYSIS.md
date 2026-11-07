# Aurora Silicon vs. our J716s stack (M5 Pro, T6050)

Read-only analysis, 2026-11-06. Nothing was cloned, built, pushed or written to any device.

## Sources and revisions

| Name used below | Ref | Commit | Notes |
|---|---|---|---|
| **INT** | `aurora-silicon/linux` `integration/aurora` | `33bec4016c46` (2026-11-06) | Default branch, Linux 7.3.0. Has **no** T6050 device tree. |
| **PLAT** | `j716c/t6050-platform` | `0b209c466e06` (2026-11-05) | The full J716c stack: PRs #935 #937 #938 #939 #941 #945 plus NVMe, cpufreq, dptx, dockchannel, rtkit-crashlog. 54 commits ahead of INT, 375 behind. Every `j716c/*` branch shares merge base `d9faa8c9b369` (2026-11-04). |
| **GPU** | `funkzy/t6050-gpu-on-integration` (PR #1012) | `d078ca18fa45` | M5 GPU + firmware-27 DCP |
| **AURA** | `aurora-silicon/aura` `main` | 2026-11-06 | Their bootloader/EL2 monitor (m1n1-derived) |
| **OURS-DT** | `/Volumes/linux-cs/wt-integration/arch/arm64/boot/dts/apple/` | `e1d2d7313` | omarchy asahi-wip-7.2.2 + patches 0001-0034 |
| **ADT** | `~/Work/studio-artifacts/adt-runtime-j716s.bin` | n/a | Read with m1n1 `proxyclient/m1n1/adt.py`. Hardware-description properties only. Serials, MACs, calibration and IDs were omitted. |

Paths are relative to `arch/arm64/boot/dts/apple/` unless they start with `drivers/`, `arch/` or `Documentation/`. Line numbers refer to the commit listed for each tree.

Side note: `/Volumes/linux-cs/wt-aurora` (branch `aurora-j716s`, INT tip) is in use by another session. Its `build-phase1.log` stops in `asm-offsets` with `KERNEL_HWCAP_EVTSTRM` undeclared, which is the BSD-sed failure of `gen-kernel-hwcaps.sh`, and its `.config` has `CONFIG_RUST` unset. I left it alone. See section 7.

---

## 1. Device tree

### 1.1 What their T6050 files contain that our J716s DT lacks

Their split: `t6050-base.dtsi` (CPU macro, OPP tables, timer, die-0 bus), `t6050-dieX.dtsi` (per die), `t6050-die0.dtsi` (die-0-only blocks), `t6050-max.dtsi` (one die: 18 CPUs + MTP), `t6050-j716c.dts` (board). All are in PLAT only.

| Area | Theirs (PLAT) | Ours (OURS-DT) |
|---|---|---|
| **cpuidle states** | None in DT, by design. The CPU macro is spin-table with no `cpu-idle-states` (`t6050-base.dtsi:44-58`). `cpuidle-apple` registers itself from the machine compatible (section 3). | None. m1n1 passes `idle=nop` |
| **tipd / cd321x / SN201202x** | **None.** `nub_spmi_a0` (`t6050-die0.dtsi:346-351`) and `nub_spmi_a2` (`:632-637`) are empty buses, and J716c disables both (`t6050-j716c.dts:111-118`). No I2C cd321x exists on T6050. | None (our 0013 patch adds polled SN201202x; DT only in the usbhost variant) |
| **PCIe / apcie0** | `pcie0: pcie@1cb0000000`, `apple,t6050-pcie`, MSI AIC 1888 x64, `apple,msi-vector-base = <64>` (`t6050-die0.dtsi:996-1013`). `dart_apcie0/2/3` disabled (`:174-200`). The board adds port 0 with `apple,link-trained-by-bootloader` and PERST on AP GPIO 80 (`t6050-j716c.dts:53-109`). | None |
| **N1 (Wi-Fi/BT)** | `control@0,0` `pci106b,1900` with `firmware-name`, `apple,centauri-platform-id`, `apple,centauri-protocol = <27>`; `wifi@0,1` `pci106b,1902`; `bluetooth@0,2` `pci106b,1903` (`t6050-j716c.dts:88-107`). Port 0 is `status = "disabled"` until the loader trains it. | None (reference-only `contrib/pending/wireless/dt/t6050-n1.dtsi`) |
| **DCP / dptx** | Only **external** `dcpext0` (+ `dart_dcpext0`, `dart_dispext0`, mailbox, PMC bw-scratch), all disabled until "Aura's handoff" (`t6050-dieX.dtsi:101-184`). DP route through ATC2 (`t6050-die0.dtsi:966-985`). There is **no internal `dcp`/`disp0` node**: the panel stays on simplefb. | None (simplefb + our 0029/0030) |
| **USB-C** | ATC1: combo PHY + mailbox + `usb_drd1` (`apple,t6050-dwc3`) + DARTs + pwrstates (`t6050-dieX.dtsi:43-99, 186-282`). ATC2 disabled, tied to DP (`t6050-die0.dtsi:289-407`). ATC3 enabled, with the USB4 router `usb4_3_acio`/NHI disabled (`:409-626`). J716c disables ATC1 and ATC3 (`t6050-j716c.dts:120-158`), so no Type-C is live on J716c in this tree. ATC0 (the debug port) is not described. | Generic `snps,dwc3` gadgets on drd0/1/2 (`t6050-storage-net.dtsi:50-165`); the usbhost DTB adds a USB2-only PHY |
| **AOP** | `aop` (`apple,t6050-aop`, `apple,t8152-aop`), `aop_mbox`, `aop_dart`, `admac_base_ns`, `aop_audio`, all disabled until `chosen.aurora,t6050-aop=1` (`t6050-die0.dtsi:639-775`). | None |
| **PMP** | None. Comments say "no Linux PMP driver runs; the SMC drives the fans" (`t6050-base.dtsi:93-96`). | None |
| **PMC / CLPC** | `pmc: apple,t6050-pmc` with static voters CLPC 1 and AP 3, `clpc` child (`t6050-die0.dtsi:262-275`). The GPU probe waits for it (#1012). | None |
| **SPMI** | `nub_spmi0` `apple,t6050-spmi`, `apple,t8142-spmi`, PMU `pmic@e` nvmem cells pm_setting/rtc_offset/boot_stage/boot_error_count/panic_count/shutdown_flag (`t6050-die0.dtsi:207-253`); a0, a2 empty. | `nub_spmi0` with the same cells plus `fault_shadow`, `socd`, `boot_error_stage` (`t6050-smc.dtsi:42-116`) |
| **Thermal** | No `thermal-zones`. `smc_hwmon` has `apple,discover-temperatures` and `apple,soc-die-keys = "TCMb"` (`t6050-die0.dtsi:98-103`). cpufreq declares `apple,firmware-managed-thermal` (`t6050-dieX.dtsi:17-36`). | hwmon-common/fan-dual/laptop with F0md/F1md overrides (`t6050-j716s.dts:135-153`) |
| **SMC** | `apple,t6050-smc` (no t8103 fallback), `smc_reboot` with restart **and** power-off plus `pm_setting`, `smc_pcio` (`apple,smc-pcio-gpio`), `smc_rtc` (`t6050-die0.dtsi:90-133`) | `smc_gpio` + `smc_gpio_low`, `smc_reboot` `apple,poweroff-only` (0017), rtc |
| **NVMe** | `apple,t6050-nvme-ans2` only. reg is split: nvme 0x45dcc0000+0x10000, ans, nvmmu 0x41dcc0000. `apple,t6050-sart` with no power domain or reset (`t6050-die0.dtsi:139-171`). | `t8132` fallback, 0x60000 nvme window, `ps_ans` domain + reset |
| **Misc they have** | QSPI boot NOR (disabled, nvram-only writes), `pinctrl_aop` matched as t8132 with `apple,irq-group-base = <4>` (AIC 572-574), `cio_reconfig0`, `dockchannel` UART on channel 1 at 0x288e3c000 with `apple,sw-drain` | `pinctrl_aop` at AIC 568, `dockchannel_uart` 0x288e28000 |
| **Misc we have, they don't** | n/a | Full generated PMGR (`t6050-pmgr.dtsi`, 2499 lines), cpu-map + L2 nodes, `serial0` s5l UART, `fpwm0` keyboard backlight, `pinctrl_nub`, i2c0/3/4, spi2/4, `opp-microvolt`/`clock-latency-ns`/`turbo-mode`, the ATC0 gadget used for the tether |

Encoding differences that matter if DT pieces move between trees:
- AIC: theirs has 4 cells with a die cell (`#interrupt-cells = <4>`, `t6050-die0.dtsi:14-21`), ours has 3.
- MTP DART: theirs uses one stream (`iommus = <&mtp_dart 0>`, `t6050-max.dtsi:100`). Ours lists SIDs 0-4 to model the ADT `remap`.
- `dockchannel-hid`: theirs is plain `apple,dockchannel-hid` (FIFO transport). Ours uses the `apple,t8132-dockchannel-hid` fallback to get the ring transport. In INT, the ring is only for `apple,t6041-dockchannel-hid` (`drivers/hid/dockchannel-hid/dockchannel-hid.c:1574`).

### 1.2 What a `t6050-j716s.dts` needs that differs from J716c

All J716s values below come from the runtime ADT unless marked otherwise.

| Item | J716c (theirs) | J716s | Source |
|---|---|---|---|
| Board compatible / model | `apple,j716c`, "M5 Max" | `apple,j716s`, "Apple MacBook Pro (16-inch, M5 Pro, 2026)" | ADT `/product` product-name, sub-product-type `Mac17,8` |
| Board ID | 0x0e (`t6050-j716c.dts:88`) | **0x0c** | ADT `/chosen` `board-id = 12` |
| N1 platform ID | `0x000e6050` | **`0x000c6050`** | Board ID in bits 30..16, chip in 15..0, per `Documentation/devicetree/bindings/net/wireless/apple,centauri.yaml` (PLAT) |
| N1 FTAB name | `apple/centauri/j716c-ftab.bin` | `apple/centauri/j716s-ftab.bin` (naming by analogy). The file is personalised per unit. | binding text "Personalized FTAB including the required per-device calibration" |
| CPUs | 18 (6+6+6) | 18. The ADT lists cpu0-17, so `t6050-max.dtsi` applies unchanged. | ADT `/cpus` |
| SoC name / GPU | M5 Max, GPU ID variant 4 "C" | M5 Pro, GPU ID variant 3 "S" (`drivers/gpu/drm/asahi/hw/t6050.rs:22-33` in GPU) | ADT `/product` product-soc-name |
| Trackpad firmware | `apple/tpmtfw-j716c.bin` | `apple/tpmtfw-j716s.bin` | OURS-DT `t6050-j716s.dts:79` |
| Trackpad AFE reset | `<&smc_pcio 2 GPIO_ACTIVE_HIGH>` with `apple,output-commands = <0x001a000000000000 0x000f000000800000 0x011c000000010000>` (`t6050-j716c.dts:205,221-223`) | **Identical.** The J716s ADT has dp2hdmi_pwr_en pcIO (lo 0, hi 0x1a0000), hdmi_pwr_en (0x800000, 0xf0000) and multi-touch afe-reset (0x10000, 0x11c0000), which are exactly those three templates. | ADT `/arm-io/dp2hdmi-gpio0`, `/arm-io/dockchannel-mtp/mtp-transport/multi-touch` |
| Type-C mapping | Comment: "ATC1, ATC3 and nub-spmi-a0/-a2" | **ATC0** = left-back (hpm0, a0 SID 0xc, our tether). **ATC1** = left-front (hpm1, a0 SID 0xa). **ATC2** = right (hpm2 on **nub-spmi-a1** 0x28a1a8000, SID 0xc). MagSafe = hpm5 (a0 SID 0x8, port-type 17). **No usb-drd3**, so ATC3 must be disabled. No nub-spmi-a2. | ADT `/arm-io/nub-spmi-a0/hpm{0,1,5}`, `/arm-io/nub-spmi-a1/hpm2`, `usb-drd0..2` port-number/acio-parent |
| PCIe port 0 | regs config/rc/port0/phy0/intr2axi0, IRQ 1523, PERST GPIO 80 | Identical: reg[0] 0x1cb0000000, reg[1] 0x414000000, reg[16] 0x410028000, reg[18] 0x417010000, reg[19] 0x410024000, IRQ 1523, `function-perst = GPIO 80`. Port 1 has the SD reader on J716s too. | ADT `/arm-io/apcie0`, `pci-bridge0` |
| Speakers | not described (i2c1/i2c2 disabled) | 6x `sn012776` (TAS2764-family): i2c1 0x38/0x39/0x3a, i2c3 0x3b/0x3c/0x3d; `amp_gain` 15. Jack codec `cs42l84` at i2c2 0x4b. Speaker reset GPIO 107, IRQ GPIO 106, speaker-id GPIOs 136/137. Codec reset GPIO 139, IRQ 134. **i2c3 is not in their dtsi.** | ADT `/arm-io/i2c{1,2,3}/*` |
| Mics | n/a | 3 built-in (`/product builtin-mics = 3`), behind the AOP/exclave path | ADT, our `contrib/pending/audio/REPORT.md` |
| Keyboard backlight | not described | `fpwm0` at 0x505040000, `ps_fpwm0` pmgr1+0x2a8 | ADT `/arm-io/pwm0`, OURS-DT `t6050-pmgr.dtsi:952-959` |
| Panel | not described (simplefb) | 3456x2234; `tcon-path = arm-io/spi4/dp855`; internal `dcp` 0x48ae00000, `disp0` 0x488000000, `disp0,t605x` | ADT `/product`, `/arm-io/dcp`, `/arm-io/disp0` |
| AOP SRAM window | `reg <0x2 0x90c00000 0x0 0x1e0000>` (`t6050-die0.dtsi:754`) | ADT reg[2] is 0x290c00000 + **0x2f0000**. Check this before enabling the AOP. | ADT `/arm-io/aop` |
| Antenna SKU / RF | not in DT | ADT `/product wifi-chipset = 'proxima'`, `RF-exposure-separation-distance = 5`. Nothing per-model reaches the DT: the FTAB carries calibration. | ADT |

### 1.3 OPP tables and cpufreq vs ours

- **Frequencies are identical.** Theirs: M clusters have 16 levels, 300 MHz to 4 380 000 kHz (`t6050-base.dtsi:98-166`). P cluster has 21 levels, 300 MHz to 4 608 000 kHz (`:168-256`). Ours, generated from the J716s ADT (`t6050-cpufreq.dtsi`), has the same values from level 2 up.
- **Why we see 14/16 steps with max 4 308 000 and extra 4 332 000..4 608 000 in `time_in_state`:** our generator marks M `opp16` (4 380 000) and P `opp18-21` (4 332 000, 4 428 000, 4 512 000, 4 608 000) `turbo-mode` (`t6050-cpufreq.dtsi:97-103, 301-328`). Boost OPPs stay in the frequency table, so stats list them. They are excluded from `cpuinfo_max_freq` while boost is off. Our tables also omit level 1 (300 MHz). Theirs has no `turbo-mode` and includes level 1, so their max is 4 380 000 / 4 608 000 with no boost knob.
- **Driver contract differs.** PLAT `drivers/cpufreq/apple-soc-cpufreq.c:345-353` adds `soc_t6050_info` (verify_transition, max_pstate 31, 2 ms timeout). At `:1373-1380` it **refuses to probe (-ENODEV)** unless the cluster node has `apple,firmware-managed-thermal`. Compatible is `apple,t6050-cluster-cpufreq` only (`:388-389`). Our DT would therefore fail cpufreq on their kernel unless it gains that property.
- Their comment: iBoot leaves M cluster 0 in state 6 (2652 MHz) and the others in state 2 (`t6050-base.dtsi:89-91`). This is useful context for the handover-state logging in our 0008.

---

## 2. Drivers: our patches vs. their tree

| Ours | In Aurora? | Where / commit |
|---|---|---|
| **0016** RTKit wait 1 s to 10 s | **Absent.** Both waits are still 1 s: INT `drivers/soc/apple/rtkit.c:1499` (sync-syslog poll) and `:1527-1537`; PLAT `:1560`, `:1588-1598`. | Their T6050 NVMe avoids the long handshake differently. PLAT `drivers/nvme/host/apple.c:1710-1725`: "post-M4 firmware handoff: restarting stopped ANS without reset" sets RUN and calls `apple_rtkit_boot()`. A live ANS is adopted at `:1683-1692`; hw data is at `:2750-2766` (commit `f081d07a4ee1` "nvme: apple: Add the T6050 ANS on bare metal"). **If m1n1 hands ANS over as today, the 1 s wait can still fire. Carry 0016.** |
| **0017** macsmc-reboot `apple,poweroff-only` + boot_stage writes | **Different.** boot_stage is written at probe (`BOOT_STAGE_KERNEL_STARTED`, INT `drivers/power/reset/macsmc-reboot.c:240-243`) and before shutdown/reboot (`:153-156`), so the part iBoot needs is there. There is **no poweroff-only mode**: restart is always registered through SMC `phra` (`:261-270`). PLAT adds `ac_power_mode` (`899375116a53` / `ae0ce646f6b4`, #941) and registers the reboot/RTC cells only when the DT has them (`64f198a02f63`, PLAT `drivers/mfd/macsmc.c:77-84, 577-595`). `asahi.config` has `CONFIG_POWER_RESET_MACSMC=m`, the exact trap 0017 fixed (it must be `=y` on a module-less root). | Carry the poweroff-only half of 0017 until an SMC restart is shown to land back in stage-1 m1n1. Force `=y`. |
| **Trackpad AFE reset, power method 2** (0001/0002) | **Present, different shape.** `6a411d0d1495` "HID: dockchannel: Support MTP power method 2" (Ryan Murray, 2026-09-25) and `3661ab4c3fad` "support firmware-managed M5 trackpad power" (Acelogic). INT `dockchannel-hid.c:240-301` (per-interface `apple,power-method`, `apple,firmware-managed-reset`), `:540-565` (assert + 50 ms on OFF, release on ON, between the two nine-byte halves), `:1620-1645` (the line is requested at probe, so `-EPROBE_DEFER` works). Differences: `apple,afe-reset-gpios` sits on the **parent** `input@8000` node, not on `multi-touch`. J716c drives it through **SMC pcIO line 2** (`gpio-macsmc` `apple,smc-pcio-gpio`, PLAT `drivers/gpio/gpio-macsmc.c:348-432`), not `gp1c` on `smc_gpio_low`. Their T6050 transport is FIFO; ring is t6041-only (`:1574`). | Use their DT shape (section `J716S-DELTA.dts.md`). Our 0001 is not needed on their tree. |
| **0018** reject over-size SMC replies | **Present.** INT `drivers/mfd/macsmc.c:181` (`ret > rsize` gives -EIO; only `ret` bytes are copied). | `dc6632348348` "mfd: macsmc: Reject short fixed-width replies" (Ryan Murray, `Assisted-by: LLM`) |
| **0019** bound atomic SMC write | **Present, 5 s.** INT `macsmc.c:51` `SMC_ATOMIC_TIMEOUT_MS 5000`, poll at `:310`, `:339` | `c243a5f85af1` (bound, Jonathan Goyvaerts) + `67c3100c8234` (raised to 5 s, Sean Dolbec) + `03dc72971506` (free buffer on late reply) |
| **0020** hold lock across key-info copy | **Present.** INT `macsmc.c:248-262` | `3471b7e19b2f` "Hold the mutex while decoding key metadata" |
| **0021** bounds-check key index | **Present.** INT `macsmc.c:236`. Output preserved on failure. | `c7da395b5ab5`, `6c1da859b2b1` |
| **0022** short `#KEY` reply = -EIO | **Present.** INT `macsmc.c:541-544` | `dc6632348348` |
| **0023** second GPIO bank only when described | **Present.** INT `macsmc.c:573` | `d0ab7ca48ddc` |
| **0005** init the spinlock | **Present.** INT `macsmc.c:496` | `5c804ba1138d` |
| **0024** B0RM byte order apart from BCF0 | **Present.** INT `drivers/power/supply/macsmc-power.c:1088` (`b0rm_native`) | `2bfb6b31cb0f` |
| **0025** serialise charge settings; reply size is not an error; CHTE length | **Present.** INT `macsmc-power.c:371, 783, 988` | `ede99b3c1990` (Chris Kearney) |
| **0026** CHLS limit no longer forces discharge | **Present (superset).** INT `macsmc-power.c:405` plus an opt-in `auto-discharge` behaviour with UAPI | `a5b22878b31b`, `ede99b3c1990`, `b8e84d08eef5` (preserve firmware charge settings at probe) |
| **0027** optional props only when keys exist; ENODATA for 0xffff | **Present.** INT `macsmc-power.c:1047-1052`, `:575`, `:583` | `a27dee2c067a`, `9fe96ec82bd4` |
| **0028** `macsmc_power.trace` | Absent (debug aid) | n/a |
| **0004** INIT_WORK before notifier | **Absent; the bug is live.** INT `macsmc-power.c:1190-1193` registers the SMC notifier and *then* re-runs `INIT_WORK(critical_work)` / `INIT_DELAYED_WORK(dbg_log_work)` (PLAT `:1217-1220`). | Carry 0004. |
| **0003** hwmon keeps fans with missing optional keys | **Absent.** INT `drivers/hwmon/macsmc-hwmon.c:965-1000` still returns an error on any missing min/max/target/mode key. `hwmon-fan-dual.dtsi` uses `F1Md`. | Keep our `F0md`/`F1md` override (J716c simply disables `smc_hwmon`) |
| 0029 simpledrm eDP connector, 0031 xhci wakeup-source | Absent | n/a |
| 0034 leave T6050 domains alone in sleep | Different mechanism: `apple,sleep-retained` / `system_sleep` handling in `drivers/pmdomain/apple/pmgr-pwrstate.c` (INT) | n/a |

Their T6050 SMC profile changes behaviour for our DT. On `apple,t6050-smc` (PLAT `macsmc.c:58-64`) the fixed cells are input/power/hwmon only. `macsmc-gpio` binds only `apple,smc-pcio-gpio` and `macsmc-low-gpio` binds only when described (`:71-74`). Our `apple,smc-gpio` (`gP` keys) node would get no device.

---

## 3. cpuidle (#826, merged as `4444dc7d776b`, commit `4253ee01142c`)

- **What it adds:** T6050 in `cpuidle-apple`. INT `drivers/cpuidle/cpuidle-apple.c:139-141`: on `apple,t6050` (and t8140/t6041/t8132) the "CPU PD" state is replaced by a copy of the WFI state, so there are **two WFI states**. The reason, per the code: "CPU PD writes CYC_OVRD, which is an undefined instruction on T8140, the M4 SoCs and T6050, where it is also not available to a guest". Index 1 is kept because the s2idle selector skips index 0. Without it, `tick_freeze()` and timekeeping suspend never run. The driver binds with **no DT node**: `apple_cpuidle_init()` registers a platform device when the machine is `apple,t6050` (`:161-205`, `:194`). Normal idle is unchanged (`cpu_do_idle()`).
- **PSCI vs WFI:** WFI only. No PSCI, no `idle-states` (T6050 is spin-table, `t6050-base.dtsi:49`). This is different from J813 (T8142), which has a `t8142-j813-psci-idle.dtsi` in INT.
- **What it says about M5 Pro:** "Not tested: M5 Pro." Tested on J716c (M5 Max) only: 483 s of s2idle, all 18 CPUs entered the state once.
- **The `idle=nop arm64.nowfxt` question:**
  - INT keeps architectural state across WFI on M4 and later itself. `arch/arm64/kernel/idle.c:52-72` (`apple_wfi_quirk_init`, MIDR part >= M4 `0x52`, which covers T6050 parts `0x64`/`0x65`, `arch/arm64/include/asm/cputype.h:165-166, 300-304`) routes `cpu_do_idle()` through `apple_cpu_wfi()` with an FP/SIMD flush (`:94-119`). `arch/arm64/kernel/pi/idreg-override.c:461-466` forces `id_aa64isar2.wfxt=0` on M4+, so `arm64.nowfxt` is redundant. Commits: `c407e1097ba7`, `f1da0a655fa4`, `3f0822d73dbe`, `34649b455f4a`.
  - But `idle=nop` still wins on T6050. Only T8142 overrides it (`idle.c:67-71`). With `idle=nop`, `cpu_do_idle()` does nothing, so both cpuidle WFI states spin. AURA's comment (`src/kboot.c:749-755`) says "idle=nop would keep every idle CPU spinning". AURA still appends `idle=nop arm64.nowfxt` for T6050 (`:756-783`, only T8140/T8132/T6040/T6041 excluded, T8152 gets only `nowfxt`).
  - Our 7.2.2 tree has neither the WFI-preserving path (`arch/arm64/kernel/idle.c` is plain `wfi()`) nor T6050 in cpuidle-apple.
- **What m1n1 must do:**
  1. Stop appending `idle=nop` on T6050 when booting a kernel that has the M4+ WFI quirk. Our m1n1 `src/kboot.c:321-327` appends it for every chip with locked sysregs. Keeping `arm64.nowfxt` is harmless.
  2. Nothing else: no PSCI, no DT idle-states, no node. Keep spin-table release addresses as today.
  3. The kernel needs `CONFIG_ARM_APPLE_CPUIDLE=y` (`asahi.config:17`).
  - Note: PLAT has the WFI quirk but **not** #826 (it predates the merge), so cherry-pick `4253ee01142c` (one file, +8/-6) onto PLAT.

---

## 4. USB-PD (tipd) on T6050

- **Bus:** SPMI, not I2C. The PD controllers are TI SN201202x on the "HPM" SPMI buses (ADT `usbc,sn201202x,spmi`). Driver: INT `drivers/usb/typec/tipd/spmi.c` (`apple,sn201202x`, `:264-266`), `CONFIG_TYPEC_SN201202X=m` in `asahi.config`. The I2C `cd321x` front end (`tipd/i2c.c`) is M1/M2-era and unused here.
- **Interrupts optional, polled mode:** `spmi.c:515-517`: `polled = !interrupts && !interrupts-extended`. In polled mode the tipd core polls events every 500 ms (`tipd/core.c:1897-1905`, `:3005-3020`). This is the same idea as our 0013 (select polled, 500 ms core poll). T6050's `nub-spmi-a*` are gen-4 polled buses ("They are polled (no interrupts), so the bus needs none either", `t6050-die0.dtsi:342-345`).
- **Node shape** (from the only M5 board that describes it, J813, INT `t8142-j813-usb.dtsi:64-93, 208-239`):
  ```dts
  &nub_spmi_a0 {
      hpm1: usb-pd@a {
          compatible = "apple,sn201202x";
          reg = <0xa SPMI_USID>;
          connector {
              compatible = "usb-c-connector";
              label = "USB-C Left-front"; power-role = "dual"; data-role = "host";
              ports { port@0 { endpoint { remote-endpoint = <&dwc3_hs>; }; };   /* HS -> dwc3 role switch */
                      port@1 { endpoint { remote-endpoint = <&atcphy_typec>; }; }; };  /* SS -> combo PHY mux/orientation */
          };
      };
  };
  ```
- **On T6050 today:** no board describes an HPM. a0/a2 are empty and J716c disables them. For J716s: hpm0 (a0, SID 0xc, left-back = ATC0, our tether), hpm1 (a0, SID 0xa, left-front = ATC1), hpm2 (**a1**, 0x28a1a8000, SID 0xc, right = ATC2), hpm5 (a0, SID 0x8, MagSafe, port-type 17, not a Type-C connector). Their die0 has no `nub-spmi-a1`, so a J716s DT must add it.
- **Would runtime VBUS / replug work with their kernel?**
  - VBUS: the SN201202x firmware negotiates and sources VBUS on its own. Linux only reads status and does role/mux switching. So VBUS works as long as the controller is not held in reset. Our usb REPORT already notes VBUS is PD-firmware-driven.
  - Replug: needs (a) the SN201202x node so tipd sees attach/detach, (b) a T6050 combo PHY that does mode/orientation switching (#939 `drivers/phy/apple/atc-t6050-dp.c`, PLAT), and (c) `apple,t6050-dwc3` glue taking the role switch (`drivers/usb/dwc3/dwc3-apple.c`, `115d8e1f83da`). All three exist in PLAT for **ATC1** (left-front), which is fully described in `t6050-dieX.dtsi`. ATC2 (right) needs the display route sorted. **ATC0 is refused** by their PHY ("Accept every Type-C port but the debug port (0)", `cc6e3b970fb4`). ATC0 is our tether port on J716s, so it stays an m1n1-initialised gadget.
  - Status: plausible on left-front after we write hpm1 + nub_spmi_a0. Not demonstrated on any public T6050 DT. #939 says "USB3 on every port" on J716c, but with a DT not in `j716c/dt`.

---

## 5. N1 Wi-Fi/BT (#938, #998, #1013)

- **Firmware requested:** exactly one file, the DT `firmware-name` of function 0. There are no hard-coded names. PLAT `drivers/net/wireless/apple/centauri/centauri_pci.c:123` `request_firmware_direct(&fw, c->firmware_name, ...)`. The image must have `rkosftab` at offset 0x20 (`:132-136`). Secondary images come out of its `2ftb`/ftab entries (`centauri_ipc.c:59-96, 288`). Wi-Fi (`centauri_wifi.c`) and BT (`btcentauri.c`) request no firmware of their own. J716c name: `apple/centauri/j716c-ftab.bin` (`t6050-j716c.dts:92`). J813 uses its own name in `t8142-j813-n1.dtsi`.
- **DT properties** (binding `Documentation/devicetree/bindings/net/wireless/apple,centauri.yaml`, required): `firmware-name` ("Personalized FTAB including the required per-device calibration"), `apple,centauri-platform-id`, `apple,centauri-protocol = <27>` (any other value is rejected, `centauri_pci.c:349-356`). BT: `local-bd-address`, falling back to `local-mac-address` (`562736dae347`). Wi-Fi: `local-mac-address`.
- **Platform-ID formula:** `(board_id << 16) | 0x6050`. The binding says chip ID in bits 15..0 and board ID in bits 30..16. It is written to BAR0+0x807c before the ROM boot (`centauri_pci.c:155`). **J716s: ADT `/chosen board-id = 12`, so `0x000c6050`.**
- **What the bootloader must provide** (binding description + `t6050-j716c.dts:46-52` + #937):
  1. Train apcie0 **port 0** after the SMC releases the N1 reset (ADT `pci-bridge0 function-reset` = pKW4 `gP13`). Keep power, clocks, PHY and PERST, and leave the endpoint in its stopped ROM state with DMA/MSI quiesced. Then flip `port00` and `dart_apcie0` to okay and renumber `bus-range`.
  2. Fill `firmware-name` and `apple,centauri-platform-id`.
  3. Fill the MACs through the `wifi0`/`bluetooth0` aliases (AURA `src/kboot.c:2105-2120, 2199, 2363` does this; m1n1 has the same alias mechanism).
  4. Put the personalised FTAB file on the root (`/lib/firmware/apple/centauri/`). The kernel only post-ROM-cycles the port (`centauri_port_cycle`, `centauri_pci.c:190+`) using the host's root-port reset (#937 `9c0482557fc5`).
- **Does their public bootloader do it?** **No.**
  - AURA `src/pcie.c` stops at `apcie,t8140`, with no `apcie,t6050` case (`:387-421`).
  - AURA has no T6050 file other than the SMP start offset (`src/smp.c:749`) and `soc.h`. There is no centauri/FTAB handoff (the only N1 code is `src/j813_n1.c`).
  - `aurora-silicon/m1n1` main stops at `apcie,t6040`, and no T6050/j716* branch exists in either repo. The J716c DT comments call the loader "Aura", which has checks for DCP/AOP that are not public. The "boot producer" that trains port 0 and supplies the FTAB is unpublished, and no public source for the FTAB file was found.
  - Our m1n1 `src/pcie.c` also stops at `apcie,t6040`.
- **Hardware status:** #938: "Wi-Fi associates and carries the machine's SSH connection" on J716c (6 GHz, WPA3-SAE). #998/#1013 qualified J813/J873 (T8142/T8152) with a native-PCIe variant plus real MSIs. Those are other SoCs, but they share `btcentauri` and the cfg80211 code.

---

## 6. Display (#1012, firmware-27 DCP/DART/DP for T6050)

- **Rust:** **not needed for display.** `drivers/gpu/drm/apple` (DCP) is C. `drivers/gpu/drm/apple/Kconfig` (GPU branch) has no Rust dependency. The **GPU** (`drivers/gpu/drm/asahi`) is Rust.
- **M5 Pro gating:**
  - **GPU: gated off.** `drivers/gpu/drm/asahi/hw/t6050.rs:22-33` (M5 Pro, variant 3) and `:66-82` (M5 Max, variant 4) both use `FirmwareProfile::M5NoBareMetalTables`. `driver.rs:407-410` then fails probe with "M5 Pro/Max bare-metal GPU tables not yet available". Only J775D (M5 Ultra, `M5PublishedRoots`) runs.
  - **Display: not board-gated, but firmware-gated.** `drivers/gpu/drm/apple/dcp.c:4881-4885`: for `apple,t6050-dcp`/`-dcpext` (`:6991-7010`, `adopt_live_session = true`, 41-bit DMA), `apple,firmware-compat` must be exactly `"27.0.0"`, otherwise `DCP_FIRMWARE_UNKNOWN`. The PR says "firmware 27.2 (DCP probe refuses it; no panic)". Our J716s runs the 26C5035r (27.3 beta 1) stub, which is not covered. The binding (`Documentation/devicetree/bindings/display/apple,dcp.yaml:442-456`) requires `apple,clock-ids`, `memory-region`, `memory-region-names` and `apple,firmware-compat = <27 0 0>`.
- **What it needs from m1n1 and the ADT:**
  1. A live DCP session: iBoot leaves the coprocessor running with both DARTs **locked** (PROTECT), on four-level tables. The kernel adopts it (`apple-dart` "T6050's locked display roots and four-level firmware subtrees"; DT comment `t6050-dieX.dtsi:101-109`).
  2. The loader sets `apple,firmware-version`/`apple,firmware-compat` from the stub firmware ("27.0 or 27.2, whose IOMFB method IDs differ", `t6050-dieX.dtsi:175-178`). It also adds the DCP `memory-region` reservations (VRAM / firmware heaps with their IOVAs) and only then enables the nodes ("Aura enables them only when its checks of that state pass and it has reserved vram"). Our m1n1 `dt_set_display()` prints "unknown compatible" for T6050 and sets none of this (our `contrib/pending/dcp/REPORT.md:43-46`).
  3. ADT facts: `dcpext0` 0x2b2e00000, IRQs 1123..1130; `dart-dcpext0` SID 23, IRQ 1070, vm-base 1 TiB; `dispext0` PMC bw-scratch. These are all present in the J716s ADT with the same values as their dieX. The internal `dcp` 0x48ae00000 / `disp0` 0x488000000 (`disp0,t605x`) needs an `apple,t6050-dcp` node that **no Aurora DT has yet**. The driver data exists (`num_dptx_ports = 0`).
  4. The DP route through ATC2 needs the T6050 combo PHY (`PHY_APPLE_T6050_DP`) + `apple,t6050-display-crossbar`. On J716s ATC2 is the right-hand port.
- **Bottom line for J716s:** the external display path is described; the internal panel isn't. Both are blocked on (a) the DCP firmware ABI (27.0 only, we run 27.3b1) and (b) a loader that publishes the firmware identity, reservations and locked-DART state. The GPU is blocked in code for M5 Pro.

---

## 7. Build feasibility (plan only, not run)

### What their tree expects
- Config: `make ARCH=arm64 LLVM=1 defconfig asahi.config` + `olddefconfig` (`arch/arm64/configs/asahi.config`, INT. #1012 documents the same recipe). `asahi.config` sets `CONFIG_RUST=y` and builds most Apple drivers as **modules** (`NVME_APPLE=m`, `POWER_RESET_MACSMC=m`, `MACSMC_POWER=m`, `GPIO_MACSMC=m`, `HID_DOCKCHANNEL=m`, `APPLE_DOCKCHANNEL=m`, `APPLE_SART=m`, `TYPEC_SN201202X=m`, `ARM_APPLE_SOC_CPUFREQ=m`, `DRM_APPLE=m`, `PHY_APPLE_ATC=m`). Our payload root has no modules, so a fragment must force the boot-critical ones to `=y`.
- Rust: `scripts/min-tool-version.sh` needs rustc >= 1.85.0, bindgen >= 0.71.1, LLVM >= 17.0.1. Their CI (`.github/workflows/host-tests.yml:22-25`) pins rustc 1.96.0, clang 18, gcc 13. You also need `rust-src` and libclang.
- On this Studio (macOS host): Homebrew rustc 1.99.1 and rustup 1.98.1 exist, but there is **no `rust-src`** component and **no `bindgen`**. Clang 23.1.4 and ld.lld are present. The macOS host also needs GNU sed/coreutils first in PATH (the `wt-aurora` attempt failed on exactly that). A Rust-for-Linux build with a Darwin host is untested here. **Recommendation: build in the Fedora 43 container** (`container` CLI 1.6.1 and image `fedora:43` are already present). `/Volumes/linux-cs` is case-sensitive APFS (80 GiB, 38 GiB free).
- Rust can also be turned off (`scripts/config -d RUST`). That only drops `DRM_ASAHI` (gated off on M5 Pro anyway) and the Rust RTKit/fw-loader abstractions. Nothing on the J716s boot path needs Rust. This is a fallback if the toolchain fights.

### Which source to build
INT has no T6050 DT. Build **PLAT (`j716c/t6050-platform`, the J716c-tested stack) as is**, plus:
- `4253ee01142c` (cpuidle T6050, #826)
- our carry patches: 0016 (RTKit 10 s), 0004 (INIT_WORK order), the poweroff-only half of 0017
- the new `t6050-j716s.dts` + Makefile line (see `J716S-DELTA.dts.md`)

Rebasing onto INT tip (375 commits newer, touching macsmc/rtkit/dwc3) is a second step.

### Commands (for approval; run nothing until approved)
```sh
# 0. New worktree (do not reuse /Volumes/linux-cs/wt-aurora: another session owns it)
cd /Volumes/linux-cs/linux
git fetch https://github.com/aurora-silicon/linux.git \
    j716c/t6050-platform:aurora/j716c-t6050-platform \
    integration/aurora:aurora/integration
git worktree add -b j716s-aurora /Volumes/linux-cs/wt-aurora-j716s aurora/j716c-t6050-platform
cd /Volumes/linux-cs/wt-aurora-j716s
git cherry-pick 4253ee01142c                      # cpuidle: apple: Add T6050 (#826)
git am ~/Documents/GitHub/m5pro-linux/contrib/validated/integration/patches/linux/0016-*.patch
git am -3 ~/Documents/GitHub/m5pro-linux/contrib/validated/integration/patches/linux/0004-*.patch
# 0017: port only the macsmc-reboot.c + binding hunks (the t6050-smc.dtsi hunk has no target here)
# add arch/arm64/boot/dts/apple/t6050-j716s.dts (from J716S-DELTA.dts.md) and
#   dtb-$(CONFIG_ARCH_APPLE) += t6050-j716s.dtb   to arch/arm64/boot/dts/apple/Makefile

# 1. Fragment: arch/arm64/configs/j716s-builtin.config
cat > arch/arm64/configs/j716s-builtin.config <<'CFG'
CONFIG_NVME_APPLE=y
CONFIG_APPLE_SART=y
CONFIG_APPLE_RTKIT_HELPER=y
CONFIG_APPLE_DOCKCHANNEL=y
CONFIG_HID_DOCKCHANNEL=y
CONFIG_GPIO_MACSMC=y
CONFIG_POWER_RESET_MACSMC=y
CONFIG_MACSMC_POWER=y
CONFIG_INPUT_MACSMC_INPUT=y
CONFIG_SENSORS_MACSMC_HWMON=y
CONFIG_PINCTRL_APPLE_GPIO=y
CONFIG_ARM_APPLE_SOC_CPUFREQ=y
CONFIG_ARM_APPLE_CPUIDLE=y
CONFIG_PWM_APPLE=y
CONFIG_LEDS_PWM=y
CONFIG_USB_DWC3=y
CONFIG_USB_GADGET=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_EEM=y
CONFIG_DRM_SIMPLEDRM=y
CONFIG_LOCALVERSION="-aurora-j716s"
CFG
# (alternatively also merge our omarchy fragments: omarchy-bringup/storage-net/smc/usb-host/desktop.config,
#  checking each symbol still exists in 7.3)

# 2. Container build (native arm64, no cross)
container system start
container run --rm -it --cpus 16 --memory 32g \
  -v /Volumes/linux-cs:/src -w /src/wt-aurora-j716s fedora:43 bash -lc '
    dnf -y install make gcc flex bison bc perl openssl-devel elfutils-libelf-devel \
        dwarves python3 clang llvm lld rust rust-src bindgen-cli cpio xz zstd git rsync &&
    make ARCH=arm64 LLVM=1 O=/build rustavailable &&
    make ARCH=arm64 LLVM=1 O=/build defconfig asahi.config j716s-builtin.config &&
    make ARCH=arm64 LLVM=1 O=/build olddefconfig &&
    for s in NVME_APPLE POWER_RESET_MACSMC HID_DOCKCHANNEL GPIO_MACSMC APPLE_SART; do
        grep -qx "CONFIG_$s=y" /build/.config || { echo "missing =y: $s"; exit 1; }; done &&
    make ARCH=arm64 LLVM=1 O=/build -j16 Image.gz dtbs &&
    mkdir -p /src/out-aurora-j716s &&
    cp /build/arch/arm64/boot/Image.gz /build/.config \
       /build/arch/arm64/boot/dts/apple/t6050-j716s.dtb /src/out-aurora-j716s/'

# 3. Payload, same format as omarchy-m5 scripts/mkpayload.sh:
#    m1n1 stage-2 | chosen.bootargs=... | Image.gz | t6050-j716s.dtb | initramfs.cpio.gz
cd ~/Work/omarchy-m5
scripts/mkpayload.sh --board j716s \
  --kernel /Volumes/linux-cs/out-aurora-j716s/Image.gz \
  --out build/m1n1-payload-aurora-j716s.bin   # point the DTB step at out-aurora-j716s/t6050-j716s.dtb
```
Notes:
- `O=/build` keeps objects inside the container VM's disk (virtiofs is slow for many small files). If the VM disk is too small, use `O=/src/build-aurora-j716s` instead (about 8-10 GB with Rust).
- Fedora 43's `rust` must pass `make rustavailable` (>= 1.85). If it fails, `rustup` 1.96.0 + `cargo install bindgen-cli --version 0.71.1` inside the container matches their CI.
- macOS-host alternative: the omarchy recipe (`~/Work/omarchy-m5/scripts/build-kernel.sh:36-46`: gnubin coreutils/sed first, Homebrew LLVM, `HOSTCFLAGS=-I.../host-shim`). Add `rustup component add rust-src --toolchain 1.98.1` and `cargo install bindgen-cli`, or `-d RUST`.

### Time estimate (24-core Studio, 128 GB)
| Step | Estimate |
|---|---|
| Fetch + worktree + cherry-picks/patch ports (0017 needs a hand port) | 20-40 min |
| Container toolchain install (dnf) | 5-10 min |
| First `Image.gz dtbs` with Rust (no modules target) | 12-20 min in the container (more like 25 min if objects sit on virtiofs) |
| Payload assembly | 2 min |
| Writing and dtc-checking `t6050-j716s.dts` (`make dtbs` + `dtbs_check` for that file) | 30-60 min |
| **Total to a bootable payload** | **about 1.5-2.5 h** |

### Boot-risk checklist for that payload (before any R-test)
- `pcie0` stays as in J716c (host enabled, port00 disabled). m1n1 does not train port 0, so the N1 stays off.
- m1n1 still appends `idle=nop`. It is functionally fine (CPUs spin, as today), or patch m1n1 per section 3 as a separate approval.
- The `serial0` alias points at their dockchannel UART (channel 1, sw-drain). Our tether/console is the ATC0 gadget, which the DELTA DT adds back. Keep `earlycon=efifb console=tty0`.
- Restart goes through SMC `phra` unless the 0017 poweroff-only hunk is ported. A watchdog fallback exists.
- cpufreq probes only because of `apple,firmware-managed-thermal` (inherited from dieX). That accepts firmware thermal ownership as on J716c.

### Proposed commit text (Aurora policy: `Documentation/process/coding-assistants.rst`, INT)
```
arm64: dts: apple: Add J716s (MacBook Pro 16-inch, M5 Pro)

J716s is the M5 Pro 16-inch MacBook Pro: one T6050 die with all 18 CPUs,
so it builds on t6050-max.dtsi like J716c. It differs from J716c in its
board ID (0x0c, so N1 platform ID 0x000c6050), its trackpad firmware, and
its Type-C wiring: the right-hand port is ATC2 behind nub-spmi-a1, and
there is no usb-drd3, so ATC3 stays off. The trackpad AFE reset and the
other SMC pcIO lines are the same as J716c's.

Values come from the J716s runtime ADT; see the comments.

Assisted-by: LLM dtc
Signed-off-by: <human submitter adds this>
```
(AI agents must not add `Signed-off-by`. The PR body can carry their usual "Created with Claude Opus 5.5 in Claude Code." line.)
