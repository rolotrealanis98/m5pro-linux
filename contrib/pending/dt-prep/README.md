# dt-prep: right port, SMC sensors, s2idle plan (J716s, j716s-series)

Base: `j716s-series` `b9cea5ab1b7d` (the filter-branch rewrite of `4f630b11270d`, identical tree).
Worktree `/Volumes/linux-cs/wt-dtprep` (branches `dtprep-work` = right-port, `dtprep-hwmon`, `dtprep-sleep`,
`dtprep-stack` = all four applied with `git am`), build dir `/Volumes/linux-cs/wt-dtprep-out` (DTB only).
Author Rolando Trevino, `Assisted-by: LLM` + `Co-Authored-By`, no `Signed-off-by` (add yours).
Each patch applies alone on the base (`git apply --check`) and all four apply in the order below.

| Patch | sha256 | Needs |
|---|---|---|
| `patches/right-port/0001-arm64-dts-apple-j716s-Enable-the-right-Type-C-port-A.patch` | `5b60df163a2fb5d995a913ad4dee9d1d2a0b92d687bfe2a428e214a0d647bbda` | DTB |
| `patches/hwmon/0001-arm64-dts-apple-j716s-Enable-the-SMC-sensors.patch` | `02841c6b3f494aa82e2c8ab31fd0a1bd132dcd324162902c237daea2500ac19d` | DTB |
| `patches/hwmon/0002-hwmon-macsmc-Let-discovered-temperatures-join-the-So.patch` (Aurora `b7891bd5f621`, unchanged, optional) | `db35e542030a009629f71f20380220eef2b813b8df622a17478c201f038b60dd` | kernel (not built here) |
| `patches/s2idle-plan/0001-arm64-configs-j716s-Add-the-sleep-test-interfaces.patch` | `cfb63afbb6f6a4c0818da17157343a87931eac733de75d27e7b0fd7673fa4d78` | kernel (config) |

| DTB (`build/`) | sha256 | Semantic diff against base |
|---|---|---|
| `base.dtb` (series tip, = SERIES.md) | `8c4df67ac743a08b633f7e5233004180e5b18d9f82c56b9261ec76eb77458e6e` | |
| `right-port.dtb` | `ec35fe8bb276048a5838a48bf0ef4e70c8354b1bbb411d873ebb746f095bdfed` | `right-port.vs-base.txt` |
| `hwmon.dtb` | `ab62af9bd48ffd0835e68ee0a2f78a695d1498e3a4c1e0d65ece9373065e25c6` | `hwmon.vs-base.txt` |
| `stack-right-port+hwmon.dtb` | `594f2a9f0e0d09ceca4b3fd3e9bd5360f3116d0c3f351cccf3ea0ac82a142bbc` | `stack.vs-base.txt` |

`*.decompiled.dts` next to each. Diffs by the series' `tools/compare-dt.sh` (phandles resolved): exactly the
intended nodes and properties, nothing else. Built with the tree's dtc, `W=1`: one warning, from the base
(`t6050-die0.dtsi:102` `smc_gpio_low: gpio@67700000` has a unit address and no `reg`; patch 0055).

Docs: `hwmon/CHECK.md`, `s2idle/SLEEP-PLAN.md`, `s2idle/s2idle-step.sh` (sha256
`05a5bbb132b84ff86fdc5ba60a5ab104847fe816921e99d578508306643fd35f`; `bash -n` and shellcheck clean, not run
on the Mac).

## Right port: what is checked and what is not

Checked against `~/Work/studio-artifacts/adt-runtime-j716s.bin`:
- `nub-spmi-a1` reg[0] 0x8a1a8000 (-> 0x28a1a8000), gen 4, compatible `aapl,spmi` like a0; one child `hpm2`
  (`usbc,sn201202x,spmi`, reg 0x0c, port-number 3, "right", acio-parent acio2). The node already existed in
  the J716s DTS, disabled; same compatible pair as a0 (`apple,t6050-spmi`, `apple,t8142-spmi`).
- pmgr `NUB_SPMI_A1` is critical (like A0/A2), so no power-domains; polled (ADT IRQ 763 not used, the gen-4
  driver refuses interrupts, as for a0).
- atc-phy2 core 0x183000000, acio-phy-cpu2 0x183148000 IRQs 861-864, usb-drd2 IRQ 1483, dart-usb2 1487,
  pmgr ATC2_COMMON 0x238 / USB_AON 0x178 / USB 0x180 / PHYMXWRAP 0x188 with parents 61+266, ATC2_COMMON's
  parent FAB5_SOC critical: all equal to what `t6050-die0.dtsi` already describes (disabled).
- `atc-t6050-dp.c` accepts port-index 1-5 with `apple,guest-port-reserved` + `mode-switch` (die0 has both).
- m1n1 0021 finds a combo PHY by its "core" window = ADT atc-phyN reg[2] via `fdt_node_offset_by_compatible`
  (no status check) for N = 0..7 and skips a port without usb-drdN: ATC2 (0x383000000) is matched. 0020's
  park runs in `usb_phy_bringup()` for every usb-drdN (0..7). 0018 puts every hpmN in S0, hpm2 on a1 named.

Not verified (only a boot tells):
1. The SPMI transaction on a1: same controller generation as a0, but no Linux driver has talked to a1 yet.
   If `apple-spmi 28a1a8000.spmi` fails or hpm2 times out, only the right port is lost.
2. VBUS on the right port in host mode depends on m1n1 0018 being in the installed stage-2 (hpm2 to S0).
3. ATC2's PHY firmware state at handoff: ATC2 is also the dcpext0 DisplayPort route. With nothing on the
   DP side (dcpext0, `atc2_xbar` stay disabled) it should look like ATC1; an external display path was never
   brought up, so no interaction is expected, but it is untested.

## Order through the loop

1. `hwmon.dtb`: DT only, probe failure is harmless (no hwmon); read `hwmon/CHECK.md` steps 1-4.
2. `right-port.dtb`: one boot, then plug a USB3 stick and a hub into the right port (`lsusb -t`, 5000M),
   flip the plug, role-swap with a phone.
3. `stack-right-port+hwmon.dtb` as the new daily DTB.
4. Kernel rebuild with `s2idle-plan/0001` (+ `hwmon/0002` if the die zone is wanted; then drop the
   `/delete-property/ apple,soc-die-keys` line in a follow-up DT).
5. `s2idle/SLEEP-PLAN.md`: S0 (WD2 calibration) once, S1-S3 on the base DTB, S2-S3 on the stack DTB, S4.
