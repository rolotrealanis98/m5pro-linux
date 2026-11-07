# J716s cpufreq route: Aurora #481 or our 0053 fallback (2026-11-07)

## What #481 requires
PR #481 (`t6050/cpufreq`, Dj, one commit `490ccd572f2f` on the shared T6050 base #472, which is already in
`integration/aurora`; applies cleanly onto `pr/j716s-board-v2`):

- Binding: `apple,t6050-cluster-cpufreq` as a single `const` (no fallback allowed), a new boolean
  `apple,firmware-managed-thermal`, and an `if contains t6050 then required: apple,firmware-managed-thermal`.
- Driver: `soc_t6050_info` = `verify_transition`, `needs_firmware_thermal_control`, 2 ms transition timeout,
  `max_pstate 31`, command-register PS1 readback (`APPLE_DVFS_CMD_PS1`), no `min_pstate`. Probe returns `-ENODEV`
  with "firmware thermal ownership is not declared" when the property is missing.
- #946's description lists #481 inside its base (`j716c/t6050-platform`), so Aurora's own J716c stack already assumes it.

## Can the J716s satisfy it as is?
Yes, in the DT. The cluster nodes come from carried `t6050-dieX.dtsi` and already have the single compatible and
`apple,firmware-managed-thermal`. Our board file was the only thing in the way: it overrode the three compatibles to
`"apple,t6050-cluster-cpufreq", "apple,t8112-cluster-cpufreq"`.

Open points (not blockers for the DT):
- The property is an ownership claim: "the boot producer has retained active firmware thermal control and qualified it
  for every OPP". On the J716s no Linux PMP driver runs and the SMC drives the fans, as on the J716c. The qualification
  `t6050-base.dtsi` describes (all-core load at the top states, watching TCMb, the fans and the measured clock) has
  not been done on the J716s; we only know a loaded cluster reaches 4308000 kHz with the T8112 route.
- The T6050 profile has never run on the J716s. Our boots (R1-R3) used the T8112 entry: status register readback
  (+0x50, bits 9:5), no transition verification. #481 reads back the command register and fails a transition after
  2 ms. The OPP levels in `t6050-base.dtsi` start at 1, so the missing `min_pstate` does not matter.

## What changes in our board DT if we adopt #481
Only the removal of the override (commit `4e93573160c6` on `pr/j716s-board-v2`, 18 lines). The decompiled DTB then
differs from v1 in exactly the three `compatible` lines (`apple,t6050-cluster-cpufreq` alone). `make dtbs` passes.

Without #481 in the kernel, no cpufreq driver binds: the J716s still boots, but the clusters stay at the p-states
iBoot left (M cluster 0 at state 6, 2652 MHz; the other two at state 2) with no scaling. It should not affect boot
itself; that is reasoning, not a test.

## Recommendation: adopt #481 and drop 0053
- The carried dtsi, #481 and #946's base already agree on the single compatible plus ownership property. A board file
  that overrides it, plus a binding (0053) that allows a fallback Aurora's maintainer chose not to allow, is the part
  reviewers will push back on. 0053 also does not make the board DT check clean, since it does not add
  `apple,firmware-managed-thermal`.
- The cost is one dependency (#481) and one test on the J716s before claiming it works there.
- Close `pr/t6050-cpufreq-binding` (0053, never sent) and stop carrying it in the series.
- Before sending the board PR: boot the J716s on `integration/aurora` + #481 + the v2 DTB. Check: three policies
  appear, no "firmware thermal ownership" or transition timeout errors, `scaling_cur_freq` follows a single-core load
  on each cluster, and an all-core load at the top states with TCMb and the fans watched (that is the qualification
  the property claims). If that fails, the fallback commit can come back: revert `4e93573160c6` and revive 0053.
- Optional: squash `4e93573160c6` into the board commit once #481 is accepted, and drop the T8112 sentence from that
  commit's message.
