# T6050 (M5 Pro, J716s) cpufreq and cpuidle (agent report, 2026-11-04; nothing run on the M5)

Tags: [ADT] J716s runtime ADT; [measured] earlier hardware probes; [log] ~/Work/m5-logs; [compile]; [inferred]; [guess].

## Bottom line
- No driver logic change needed: the DVFS hardware uses the T8112 layout and stock apple-soc-cpufreq handles it via the
  `apple,t8112-cluster-cpufreq` fallback. The M clusters were already wired in the October DTB.
- The P cluster (cpu12-17) was never managed: no OPP table, no `performance-domains`; it sat at its boot p-state
  (likely 2, ~1.3 GHz) [inferred]. The omarchy-m5 patch adds it from the J716s ADT.
- m1n1 must NOT program initial p-states: the driver reads STATUS and moves the cluster into its table; APSC is enabled
  (b23 clear) on all three clusters [measured 2026-10-20]; a T6050 m1n1 cpufreq entry copied from T6030 would write
  cpm-impl-reg+0x40f8, which hangs the bus on T6050 [measured].
- cpuidle must stay off: WFI/WFIT lose state on M4+; m1n1 appends `idle=nop arm64.nowfxt` [log]; cpuidle-apple does not
  register on t6050 and must not (its deep state writes a locked sysreg). Idle cores busy-poll; cpufreq is the only lever.
- The console PMGR errors are unrelated to cpufreq (section 6).

## Topology (M, M, P)
| Cluster | type | Linux CPUs | MPIDR | DVFS reg | ADT voltage-states | perf-domain |
|---|---|---|---|---|---|---|
| 0 | M / apple,sawtooth | 0-5 | 0x40000-05 | 0x210e20000 | 22 | MCPU0 |
| 1 | M / apple,sawtooth | 6-11 | 0x40100-05 | 0x211e20000 | 23 | MCPU1 |
| 2 | P / apple,everest | 12-17 | 0x10200-05 | 0x212e20000 | 5 | PCPU |
ADT: /cpus m-core-count=12, p-core-count=6, cpu-cluster-count=3; pmgr acc-clusters 0x16/0x117/0x205. Boot core MIDR
0x611f0641 = part 0x064 (T6050_SOTRA_MCORE); P cores should report 0x065 [inferred].

## Deliverables (this folder)
- linux/0001-cpufreq-apple-soc-report-the-nearest-OPP-for-p-state.patch: get() returns the nearest table entry instead
  of 0 for an unlisted p-state (otherwise cpufreq_online fails "->get() failed" and the cluster gets no policy). [compile W=1]
- linux/0002-cpufreq-apple-soc-log-the-DVFS-state-handed-over-and.patch: one dev_info per policy with raw cmd/status,
  warns if APSC_DIS (b23) set. [compile W=1]
- linux/0003-dt-bindings-cpufreq-apple-cluster-cpufreq-Add-T6050.patch: binding entry (not schema-validated).
- omarchy-m5/0001-cpufreq-dt-all-three-T6050-clusters-generated-from-t.patch: gen-cpufreq-dt.py emits the P cluster;
  dt/t6050-cpufreq.dtsi regenerated from the J716s ADT; top states turbo-mode (M p16, P p18-21); two-string compatible.
  [compile: j716s and j714s dtbs, dtc W=1 clean]
- tools/cpuhz(.c) (core clock measurement pinned to a CPU), tools/dvfs-regs(.c) (READ-ONLY dump of cmd +0x20 / status
  +0x50 at 0x21Xe20000), tools/cpufreq-check.sh. Static aarch64 nolibc builds, compile-only.
- Worktree /Volumes/linux-cs/wt-cpufreq (base commit = main tree diff, then the 3 patches; regenerated DT untracked).
Bases: kernel asahi-wip-7.2 @ 236788cd2602 + main-tree diff; omarchy-m5 j716s @ 2c87598. git apply --check passes.

## DVFS registers vs driver
Driver base = DT reg 0x21Xe20000 (m1n1's CLUSTER_PSTATE +0x20020 == driver APPLE_DVFS_CMD +0x20).
cmd (+0x20, 64-bit): b31 BUSY, b25 SET, b23 M2_APSC_DIS (0 on all clusters [measured]), b22/b8 set at handover
(preserved by RMW), b15:12 DESIRED2 unused, b4:0 DESIRED1 (handover 0x400106 / 0x400102 = p6 / p2).
status (+0x50): b9:5 current p-state, b4:0 target (T8112 layout, measured on cluster 0). t8112 info max_pstate 31 covers
P's p21. Never touch cpm-impl-reg+0x20020 or +0x40f8 (bus hangs).

## P-states (kHz from voltage-states<k>-sram) [ADT]
M (vs22 = vs23), hardware p-state N = entry N-2 [measured on J714s]: p2 1344, p3 1644, p4 1992, p5 2304, p6 2652, p7 2964,
p8 3240, p9 3504, p10 3696, p11 3876, p12 4044, p13 4176, p14 4284, p15 4308, p16 4380 (turbo; refused, settles at 15).
P (vs5), offset 2 [guess]: p2 1308, p3 1620, p4 1980, p5 2292, p6 2580, p7 2880, p8 3180, p9 3432, p10 3648, p11 3828,
p12 3984, p13 4104, p14 4188, p15 4236, p16 4284, p17 4308, p18 4332, p19 4428, p20 4512, p21 4608 (18-21 turbo [guess]).
Boost off by default (`/sys/devices/system/cpu/cpufreq/boost`). No opp-microwatt / capacity-dmips-mhz: no EAS.

## Console PMGR errors: unrelated
`b2bd_*` "Failed to reach power state 0xf" are die-to-die fabric-bridge domains in pmgr4 @ 0x2380600000 (GPU-side die),
off at handover. The -110 errors (280600000 @280/290/2e8/2f0) are atc0/1/2_cio and atc2_pcie (USB4/TB PHY domains)
whose pinctrl suppliers never sync. CPU DVFS controllers have no power-domains in the DT. TEST-PLAN 2.3 confirms.

## cpuidle risk
m1n1 >= 3a69c73f appends `idle=nop arm64.nowfxt` when sysregs are locked (features_m4 covers T6050). `idle=nop` makes
cpu_do_idle a no-op; `arm64.nowfxt` (omarchy patch 0009) stops __delay using WFIT/WFET. Consequences: no idle power
saving (idle cluster drops to p2 under schedutil), boost may never be granted [guess], no Linux thermal zones (watch
macsmc-hwmon temps). Never remove those two args, never add idle=wfi, never test suspend, spin-table CPUs can't offline.
First cpufreq boot: add `cpufreq.default_governor=userspace`.
Escape hatches: previous DTB; scaling_max_freq; `cpufreq.off=1`; `initcall_blacklist=apple_soc_cpufreq_module_init`;
`maxcpus=12`; `maxcpus=1`.

## Verified / inferred / guessed
Compile: patches 0001/0002 W=1 clean; cpuidle-apple.o unchanged; both dtbs clean (3 performance-controllers,
performance-domains on all 18 CPUs); tools link static; git apply --check OK.
ADT: cluster types/counts, DVFS windows, voltage tables, J716s M tables == J714s.
Measured earlier: M offset 2, p16 refused, T8112 STATUS layout, safe cmd/status reads, APSC clear (27.2 stub).
Inferred: P same register semantics; m1n1 no role; PMGR errors unrelated; P cluster sat at boot p-state.
Guessed: P offset 2; turbo threshold 4308; P transitions within 400 us; which cluster booted at p6; APSC still clear on 27.3.
ADT regen: `M1N1_PROXYCLIENT=~/Work/m1n1/proxyclient scripts/gen-cpufreq-dt.py <adt> > dt/t6050-cpufreq.dtsi`
(ADT at ~/Work/studio-artifacts/adt-runtime-j716s.bin, private).
