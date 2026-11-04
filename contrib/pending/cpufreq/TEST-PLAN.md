# T6050 cpufreq / cpuidle test plan (J716s)

Prep: kernel = main tree + linux/0001-0003; DTB from omarchy-m5 + omarchy-m5/0001 (`scripts/build-kernel.sh dtbs`);
keep old Image.gz and old t6050-j716s.dtb for rollback; copy tools/cpuhz, tools/dvfs-regs, tools/cpufreq-check.sh to
/root/cf/ on the M5. Run as root; `./cpufreq-check.sh > /root/cf/stageN.txt` per stage; cpuhz ~1 s per run.

## Stage 0: baseline (current kernel/DTB)
0.1 `cat /proc/cmdline` ends with ` idle=nop arm64.nowfxt`. 0.2 `ls /sys/devices/system/cpu/cpufreq` = boost policy0
policy6 (no policy12). 0.3 `dmesg | grep "failed to add OPP table"` = 6 lines for cpu12..17. 0.4 `./dvfs-regs`: 3 lines,
apsc_dis(b23) 0, cluster 2 cur p = boot p-state (expected 2); record all.

## Stage 1: new kernel + DTB, extra bootarg `cpufreq.default_governor=userspace`
1.1 cmdline contains it and ends with idle=nop arm64.nowfxt. 1.2 nproc 18; `grep "CPU part" /proc/cpuinfo | sort | uniq -c`
= 12x 0x064 and 6x 0x065 (inferred; record). 1.3 `dmesg | grep -E "DVFS for CPUs|APSC|OPP table|->get\(\) failed|not in the
OPP table|unlisted"`: exactly three `cpu cpuN: DVFS for CPUs a-b: cmd .. status ..` lines; per line cmd&0x800000==0,
cmd&0x80000000==0, cmd&0x1f = boot p-state (6 or 2), (status>>5)&0x1f == cmd&0x1f. Must NOT appear: "APSC is disabled",
"failed to add OPP table", "->get() failed", "Running at unlisted initial frequency". "p-state N is not in the OPP table"
once per cluster is acceptable (record N).
1.4 policies 0/6/12: scaling_driver apple-cpufreq; affected_cpus 0-5 / 6-11 / 12-17; governor userspace;
cpuinfo_min_freq 1344000/1344000/1308000; cpuinfo_max_freq 4308000 all; transition_latency 8000;
scaling_available_frequencies M: 1344000 1644000 1992000 2304000 2652000 2964000 3240000 3504000 3696000 3876000 4044000
4176000 4284000 4308000; P: 1308000 1620000 1980000 2292000 2580000 2880000 3180000 3432000 3648000 3828000 3984000 4104000
4188000 4236000 4284000 4308000; scaling_boost_frequencies M 4380000, P 4332000 4428000 4512000 4608000; boost 0;
scaling_cur_freq == cpuinfo_cur_freq = boot p-state frequency.
1.5 cpuidle: current_driver none; cpu0/cpuidle absent; dmesg `SYS_ID_AA64ISAR2_EL1[3:0]: forced to 0`; no "WFx with timeout".
1.6 `./dvfs-regs`: req p = cur p = boot p-state, busy 0, apsc_dis 0.
1.7 M0 steps: for f in 1344000 2652000 4044000 4308000: `echo $f > policy0/scaling_setspeed`; cpuinfo_cur_freq == f;
dvfs-regs cluster 0 req/cur = 2/2, 6/6, 12/12, 15/15; `./cpuhz 1` ~1340/2649/4041/4303 MHz (+-2%).
1.8 M1: same with policy6, cluster 1, `./cpuhz 7`.
1.9 P mapping (main open question): f in 1308000 2580000 3984000 4308000 on policy12, cluster 2, `./cpuhz 13`; expected
req/cur 2, 6, 12, 17. cpuhz ~1308/2580/3984/4308 => offset 2 confirmed; ~1620/2880/4104/4332 => offset 1 (regenerate with
offset 1 for cluster 2); cur p != req p idle => refused (record); else record everything.
1.10 Boost: `echo 1 > .../cpufreq/boost` (max 4380000 M, 4608000 P); M `echo 4380000` => expect req p16 cur p15, cur_freq
4308000; P try 4332000 4428000 4512000 4608000, record cur p and cpuhz 13 (may all be refused under idle=nop); boost back to 0.
1.11 schedutil on all three; idle 10 s => 1344000/1344000/1308000; `./cpuhz 13 &` => policy12 at 4308000, others low;
stats/total_trans increases; dmesg clean.
1.12 All-core load: `for c in $(seq 0 17); do ./cpuhz $c & done; wait` x3: 18 lines, M ~4308, P <= 4308 (lower = multi-core
limit, record); no hang; watch macsmc temps; stop if fans peg or > 100 C.

## Stage 2: soak with default schedutil (bootarg removed)
2.1 after 5 min idle all clusters at lowest. 2.2 15 min normal use, no "not in the OPP table" storms, no hangs.
2.3 one boot with `cpufreq.off=1`: cpufreq dir empty; the b2bd_* and -110 lines unchanged (independent of cpufreq).

## Rollback / decisions
Hang at "DVFS for CPUs 12-17" or first policy12 write: forced power-off; old DTB or new DTB + maxcpus=12; report Stage 0
dvfs-regs. "APSC is disabled": cluster ignores requests; old DTB / cpufreq.off=1; report cmd (macOS clears b23 in
configCPUComplexPowerState; never via +0x440f8). cur p never follows req p: report dvfs-regs + cpuhz; cap with
scaling_max_freq. Hang under all-core load: next boot cpufreq.default_governor=powersave or cpufreq.off=1. Worse:
cpufreq.off=1, then maxcpus=12, then maxcpus=1. Never: remove idle=nop arm64.nowfxt; write cpuN/online; test suspend;
write DVFS registers.
