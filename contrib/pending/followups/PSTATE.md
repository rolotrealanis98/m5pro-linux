# P-state table offset on the J716s (finding 1)

Verdict: our DT is already on the right side of the offset. `opp-level` N in `t6050-base.dtsi` is the
hardware p-state N, and its frequency is ADT table entry N-2. That is betizzel's J714s measurement
("p-state N runs at entry N-2"). edimoldovan's J714c table is entry N-1, one step high. No patch for the offset
(`patches/0001-*` intentionally absent). What is not settled on the J716s itself: the P cluster mapping and the
top states (M p16, P p18-p21); one short measurement boot answers both (section 5).

Evidence tags: [ADT] J716s runtime ADT, only the pmgr `voltage-states*` tables and `acc-clusters` read;
[DT] our series at `dd6b39464ca9`; [meas] a hardware measurement by someone else; [log] our own boot logs;
[guess] nobody measured it.

## 1. How the driver reads the p-state

- Our board file gives the three cluster nodes `apple,t6050-cluster-cpufreq` + fallback
  `apple,t8112-cluster-cpufreq` (series 0053, 0057). The kernel has no T6050 entry in
  `drivers/cpufreq/apple-soc-cpufreq.c`, so `soc_t8112_info` applies: `max_pstate` 31, `min_pstate` 0, no
  transition verification.
- `scaling_cur_freq` is `apple_soc_cpufreq_get_rate()`: it reads the status register at +0x50, takes bits 9:5
  (`APPLE_DVFS_STATUS_CUR_PS_T8112`) and returns the frequency of the OPP whose `opp-level` equals that number.
  Writes put `opp-level` into the command register's PS1 field (bits 4:0). So `opp-level` is the raw hardware
  p-state number in both directions; the DT must map level N to the frequency the cluster really runs at in p-state N.
- The register layout itself (status +0x50, current 9:5, target 4:0) is what series 0053 states [meas, cluster 0].

## 2. The tables side by side

All three DTs list the same frequencies (the J716s [ADT] M table equals betizzel's J714s one, entry for entry and
mV for mV; the P table too). They differ only in which `opp-level` each frequency gets. Our DT's level 1 (300 MHz)
is not an ADT entry: Aurora's `t6050-base.dtsi` adds it on the T8142 convention "state 1 is 300 MHz, state 2 is
the table's first entry", noted there as measured on a J775D.

**M clusters 0 and 1 (voltage-states22 = 23)**

| ADT entry | kHz | mV | our DT `opp-level` | betizzel J714s `opp-level` | edimoldovan J714c `opp-level` | measured (J714s) |
|---|---|---|---|---|---|---|
| (none) | 300000 | - | 1 | - | - | not measured |
| 0 | 1344000 | 765 | 2 | 2 | 1 |  |
| 1 | 1644000 | 795 | 3 | 3 | 2 |  |
| 2 | 1992000 | 830 | 4 | 4 | 3 |  |
| 3 | 2304000 | 860 | 5 | 5 | 4 |  |
| 4 | 2652000 | 890 | 6 | 6 | 5 | p6 -> 2649 MHz |
| 5 | 2964000 | 925 | 7 | 7 | 6 | p7 -> 2961 MHz |
| 6 | 3240000 | 955 | 8 | 8 | 7 |  |
| 7 | 3504000 | 980 | 9 | 9 | 8 |  |
| 8 | 3696000 | 1000 | 10 | 10 | 9 |  |
| 9 | 3876000 | 1020 | 11 | 11 | 10 |  |
| 10 | 4044000 | 1040 | 12 | 12 | 11 | p12 -> 4041 MHz |
| 11 | 4176000 | 1055 | 13 | 13 | 12 |  |
| 12 | 4284000 | 1070 | 14 | 14 | 13 |  |
| 13 | 4308000 | 1070 | 15 | 15 | 14 | p15 -> 4303 MHz |
| 14 | 4380000 | 1070 | 16 | - | 15 | p16 refused, settles at 15 |

**P cluster 2 (voltage-states5)**

| ADT entry | kHz | mV | our DT `opp-level` | betizzel J714s `opp-level` | edimoldovan J714c `opp-level` | measured (J714s) |
|---|---|---|---|---|---|---|
| (none) | 300000 | - | 1 | - | - | not measured |
| 0 | 1308000 | 760 | 2 | 2 | 1 |  |
| 1 | 1620000 | 785 | 3 | 3 | 2 |  |
| 2 | 1980000 | 820 | 4 | 4 | 3 |  |
| 3 | 2292000 | 855 | 5 | 5 | 4 |  |
| 4 | 2580000 | 885 | 6 | 6 | 5 |  |
| 5 | 2880000 | 920 | 7 | 7 | 6 |  |
| 6 | 3180000 | 950 | 8 | 8 | 7 |  |
| 7 | 3432000 | 980 | 9 | 9 | 8 |  |
| 8 | 3648000 | 1010 | 10 | 10 | 9 |  |
| 9 | 3828000 | 1030 | 11 | 11 | 10 |  |
| 10 | 3984000 | 1050 | 12 | 12 | 11 |  |
| 11 | 4104000 | 1065 | 13 | 13 | 12 |  |
| 12 | 4188000 | 1075 | 14 | 14 | 13 |  |
| 13 | 4236000 | 1075 | 15 | 15 | 14 |  |
| 14 | 4284000 | 1075 | 16 | 16 | 15 |  |
| 15 | 4308000 | 1075 | 17 | 17 | 16 |  |
| 16 | 4332000 | 1075 | 18 | 18 | 17 |  |
| 17 | 4428000 | 1075 | 19 | 19 | 18 |  |
| 18 | 4512000 | 1120 | 20 | 20 | 19 |  |
| 19 | 4608000 | 1120 | 21 | - | 20 |  |

Checked by script against the ADT (`tools/pstate-tables.py`: with entry = level - 2, 15 of 16 M OPPs and 20 of 21 P OPPs
match, the exceptions being the 300 MHz level 1; with entry = level - 1, none): for every OPP in our `mcluster_opp` (levels 2-16) and `pcluster_opp`
(levels 2-21), `opp-hz` equals ADT entry `level - 2`, with no exception. edimoldovan's `mcluster0_opp`,
`mcluster1_opp` and `pcluster0_opp` equal ADT entry `level - 1` for every level.

## 3. What supports N-2

- [meas] betizzel, J714s M cluster 0, `cpuhz` pinned to a core after writing the command register: p6 -> 2649 MHz
  (entry 4, 2652), p7 -> 2961 (entry 5), p12 -> 4041 (entry 10), p15 -> 4303 (entry 13). Under N-1 the same
  requests would have given 2964, 3240, 4176 and 4380. The comment block of his `gen-cpufreq-dt.py` has the numbers.
- [DT] Aurora's `t6050-base.dtsi` comment says the same for the T8142 family (a J775D, every state's clock from a
  dependent-add chain) and uses the same levels as ours.
- [log] `r2b-live/dmesg.txt` (older kernel with the DVFS handover log line): cluster 0 handed over as cmd 0x400106,
  status 0xc6 (current 6, target 6); clusters 1 and 2 as cmd 0x400102, status 0x42 (p2). With N-2, p2 is the table's
  lowest entry (1344 / 1308 MHz) for idle clusters and p6 is 2652 MHz. Circumstantial, not a measurement.
- Not on the J716s: [ADT] and [meas] agree on the table, the hardware is the same SoC (T6050) as the J714s, but
  nobody has run `cpuhz` on the J716s. `RESULTS.md` lists "OPP offset (`cpuhz`/`dvfs-regs`)" as SKIP in R1-A and
  as not run in R2. The P cluster has no measurement on any machine (betizzel's own generator says "NOT
  measured yet" and `contrib/validated/legacy-7.2/cpufreq/REPORT.md` says "Guessed: P offset 2").

## 4. edimoldovan's J714c table

Level = entry + 1 (`t6050-base.dtsi`, commits `360a9c7b4b2c`, `e0a190841586`: "15 P-states 1.344 to 4.38 GHz",
"20 states" for P). His commit message says he uses the T8142 command-readback model, i.e. `scaling_cur_freq` echoes
what was requested, not the status register. If N-2 is right, on his machine:

- every reported frequency is one table step above what the cluster runs at (his "4380" is hardware p15 = 4308 MHz,
  his "4608" is p20 = 4512 MHz);
- he never requests hardware p16 (M) or p21 (P), so he never meets the refused top state either.

His "one busy core takes it to 4380 / 4608" test shows the request, not the clock. This is worth telling him
(a `cpuhz` run on his J714c settles it), but nothing here needs to change on our side.

## 5. What is still open on the J716s, and the one test

1. Is the M top state p16 (4380 MHz) refused here too? [meas] on J714s: yes, requested 16, the cluster settles at 15.
   Our DT lists it as an ordinary OPP (no `turbo-mode`), so schedutil asks for it at full load. With the T8112
   fallback nothing verifies the transition; `scaling_cur_freq` then reads 4308000 (status says 15) while
   `policy->cur` and `time_in_state` say 4380000. Harmless but misleading: the "4380000" in the R3-Q summary
   is `cpuinfo_max_freq` from the table, not a measured clock.
2. P states p18-p21 (4332-4608 MHz): [guess] that they are turbo-like and may be refused; unmeasured.
3. P offset: [guess] N-2.
4. p1 (300 MHz): not in the ADT, Aurora's convention; unmeasured on T6050 hardware by us. Under schedutil the idle
   floor of our J716s is therefore p1, not the ADT's lowest entry (betizzel's table starts at p2).

Test, one boot, no kernel change, tools already built (`~/Work/agents/cpufreq/tools/{cpuhz,dvfs-regs,cpufreq-check.sh}`,
static aarch64). As root on the J716s:

```
echo userspace > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor     # likewise policy6, policy12
# M cluster 0: expect cpuhz within 1 % of the request, dvfs-regs cur = req = 2, 6, 12, 15, 16(!)
for f in 1344000 2652000 4044000 4308000 4380000; do echo $f > policy0/scaling_setspeed; ./cpuhz 1; ./dvfs-regs; done
# P cluster 2 (the open one): expect 1308 / 2580 / 3984 / 4308 MHz at req p2 / p6 / p12 / p17
for f in 1308000 2580000 3984000 4308000 4332000 4428000 4512000 4608000; do echo $f > policy12/scaling_setspeed; ./cpuhz 13; ./dvfs-regs; done
```

Reading the result: `cpuhz` one table step above the request (for example 1620 at 1308000) means the P offset is 1
and cluster 2 needs its own levels (+1) in the DT; cur p-state below the request at the top means refused.
Do not touch `cpm-impl-reg+0x20020` or `+0x40f8` (bus hangs, from the earlier report).

## 6. If the test shows the top states are refused: the board-level override

Only then, and only for what is measured. M p16 as an example (J716s board file, after the cluster-cpufreq
overrides; `turbo-mode` keeps the state out of `cpuinfo_max_freq` until `.../cpufreq/boost` is set):

```
&mcluster_opp {
	opp16 {
		turbo-mode;
	};
};
```

`dtc` merges this into the existing `opp16` node, so no label is needed in `t6050-base.dtsi`. The P equivalents
are `opp18` to `opp21` in `&pcluster_opp`. I did not prepare this as a patch: the offset question asked for a patch
only if the DT were off, it is not, and the turbo flags need a measurement first.
