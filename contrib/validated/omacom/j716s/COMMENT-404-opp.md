A question about the OPP tables in `t6050-base.dtsi`, before the J716s builds on them.

The tables map `opp-level` N to ADT voltage-states entry N-1: level 1 is the first entry (1344 MHz on
the M clusters, 1308 MHz on the P cluster). apple-soc-cpufreq writes `opp-level` straight into the
cluster's p-state field and reads the current p-state back the same way, so the level has to be the
hardware p-state number.

betizzel measured the 14-inch M5 Pro (J714s), whose voltage-states22/23 and voltage-states5 tables are
the same as the J716s's entry for entry: p-state N runs at ADT entry N-2.

| p-state written | measured | entry N-2 | entry N-1 (this PR) |
|---|---|---|---|
| 6 | 2649 MHz | 2652 MHz | 2964 MHz |
| 7 | 2961 MHz | 2964 MHz | 3240 MHz |
| 12 | 4041 MHz | 4044 MHz | 4176 MHz |
| 15 | 4303 MHz | 4308 MHz | 4380 MHz |
| 16 | refused, settles at 15 | 4380 MHz | (none) |

With entry N-1, every level would run one step lower than its `opp-hz`, and `scaling_cur_freq` would
read one step high. The T8142 convention (level 1 = 300 MHz, level 2 = the table's first entry)
would fit the measurement: M clusters at levels 2-16 (1344-4380 MHz), the P cluster at levels 2-21
(1308-4608 MHz). The top state of each cluster (M level 16, P level 21) is not confirmed on any
board yet.

We have not measured the J714c, so this may not hold there. Could you check one level on it, for
example by setting `scaling_setspeed` to 2652000 on policy0 and timing a fixed loop on that cluster
against cycle counts? If the J714c matches the J714s, the tables would need shifting by one
level. We have not changed them in the J716s PR.
