# T6050 (J716s) power and performance bring-up prep (2026-11-07)

Studio only; nothing ran on the MacBook. Kernel branch `power/t6050` (sparse worktree /Volumes/linux-cs/wt-power) =
j716s-series a0f2f30c967b + 13 commits (tip 0fdf38de2884); patches here under `patches/kernel` 0001-0013,
`patches/ane-followup/0006`, `patches/draft/0001`; tools `power-check.sh` (info | idle [secs] | load), `cpuhz.c`,
`dvfs-regs.c`. W=1 clean for apple-soc-cpufreq, pmc, clpc, macsmc-hwmon; all dtbs build; dt_binding_check and
dtbs_check clean; checkpatch clean; KUnit not run. Tags: [ADT] J716s runtime ADT, [measured], [inferred], [policy].

## Bottom line

- cpufreq: adopt #481 (Dj's T6050 profile) plus corrections: read the current state from the status register
  (T8112 layout, measured), verify requests lazily as on T8140 so schedutil keeps fast switching, lowest state 1
  (300 MHz); drop the J716s T8112 override; mark M state 16 (4380 MHz) as boost. Idle floor stays 300 MHz on all
  three clusters; max M 4308 (4380 boost), P 4608 (not yet shown granted). No watt change expected; the gain is
  correctness. #481 as-is (and #404) would regress: fast switching lost, every change wakes a sugov kthread.
- PMC/CLPC: new `apple,t6050-pmc` entry (T8142 layout, 5 agents PMP/CLPC/GFX/AP/PMP1, 4 rails DCS/SOC/DISP/DISP2,
  DCS states 0-7) that only observes by default (`pmc.observe=0|1`); new `apple,t6050-clpc` table (DCS {2,4,6,7},
  fabric {0,1,2,3}, request after 3 busy samples, GPU demand input). The DT says the boot loader enables no voter,
  so DRAM and fabric likely run at their lowest states today (precedents: T8142 DRAM latency 171 -> 70 ns, copy
  40 -> 110 GB/s; T6040 41 -> 240 GB/s). PMC window = pmgr reg[8] 0x286000000; voters 0x286700000, rails
  0x286806000 (T8142 offsets already in Aurora's t6050-die0.dtsi). GPU node needs `apple,clpc = <&clpc>` on the
  GPU branch. ANE follow-up 0006 replaces the T6040-derived table.
- Thermal: keep `macsmc_soc_die` with discovery on (Aurora b7891bd5f621), add the mTPL thermal-pressure key;
  draft thermal-zones (TCMb passive 100 / hot 105 / critical 110 °C with cpufreq cooling on cpu0/6/12; palm rest
  Ts0P passive 45 °C on P) [policy], needs CONFIG_THERMAL_DEFAULT_GOV_STEP_WISE=y, not for the daily. Fans stay
  under SMC control. ADT names no CPU/GPU die sensors (smctempsensor0 LPTm + 3 panel TMP103s); TCMb idle 47.8 °C.
  Reuse later: the M5 GPU thermal governor (g17/thermal.rs) on the GPU branch; T6041 power_allocator zones once
  T6050 has opp-microwatt data; apple-pmp-thermal needs a PMP driver.

## ADT facts

2x6 "M" clusters (apple,sawtooth, voltage-states22/23) + 1x6 "P" cluster (apple,everest, voltage-states5), no E
cluster; policies cpu0-5, cpu6-11, cpu12-17. M: 1344 … 4308, 4380 MHz (states 14-16 share 1070 mV). P: 1308 …
4308 (17), 4332/4428 at 1075 mV, 4512/4608 at 1120 mV. No energy model. The old "2964/2964/1620 MHz idle floor"
note was a 7.2 `idle=nop` read artifact; measure floors with time_in_state deltas.

## Test plan

- T1 (loop-safe): payload = daily + 0001-0013, PMC observing. `power-check.sh info`, `idle 60` on battery,
  `load`. Pass: no `firmware thermal ownership is not declared` / `has no OPP` / `stopping requests`;
  apple-cpufreq drives all three policies, min 300000; max 4308000/4308000/4608000, boost 4380000 on policy0/6;
  no sugov threads; `apple-pmc ... observation only: 5 agents, 4 rails, nothing is written` + 4 rail + 5 agent
  lines (record; none 0xffffffff); CLPC debugfs status exists (update errors grow under load, expected);
  `macsmc_soc_die: hottest of TCMb`; idle mostly 300000, power within ±0.2 W of the daily; load: cpu0/cpu6 4308000
  in hardware, record cpu12.
- T2 desk check: floors one nibble per rail (DCS <= 7, SOC <= 3), enable words bits 0-4 only; else re-derive.
- T3 (attended first time): `pmc.observe=0`; no `did not stick`; rails 0/1 gain 0xa; idle last_vote 0x0; load
  `-> dcs 7 soc 3`, agent1 floor 0x00000037, update errors 0; memcpy bandwidth up; idle power within ±0.2 W.
  Rollback: `pmc.observe=1`.
- T4 boost check; T5 thermal draft (attended, 10-minute all-core load, TCMb peak and fans).

Open: P boost states granted?, bandwidth/power per DCS/fabric state, PMP throttling on our chain; #481 changes the
binding SPDX line (ask on the PR). Build tree /Volumes/linux-cs/wt-power-build + wt-power-out (~1.5 GB, deletable).
