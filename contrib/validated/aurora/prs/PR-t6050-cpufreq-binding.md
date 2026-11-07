dt-bindings: cpufreq: apple,cluster-cpufreq: Add T6050

> [Note for Rolando, delete before sending] HOLD - discuss on PR #481 (t6050/cpufreq) first. #481 adds `apple,t6050-cluster-cpufreq` as a single
> `const` and makes `apple,firmware-managed-thermal` required for it. This patch allows it with the
> `apple,t8112-cluster-cpufreq` fallback instead. Both cannot land as they are; the J716s board DT
> uses the fallback form. Ask there first, then send this or drop it.

The T6050 cluster DVFS block has the T8112 layout (J716s: status at +0x50, current p-state in bits 9:5, target in 4:0), and stock apple-soc-cpufreq drives all three clusters through the T8112 fallback. This allows `apple,t6050-cluster-cpufreq` with that fallback, as for T6020/T6030/T6031/T6041/T8122. A T6050 driver entry still takes precedence, since it matches the first string.

**Tested on:** J716s with the fallback in the board DT: `schedutil` on all three clusters since round R3-Q; R3-SERIES and R3-S (2026-11-07) boot with it. Schema not validated here (no dt-schema on the build host).

**Dependencies:** none to apply. Conflicts with #481 (see above). Needed by the J716s board PR for `dtbs_check`.

**Open questions:**
- (a) This binding (fallback allowed) plus #481's driver entry, which then wins over the fallback; or
- (b) #481's single-string binding, and the J716s moves to #481's driver entry once it lands (with `apple,firmware-managed-thermal`, which we have not yet checked on the J716s)?
