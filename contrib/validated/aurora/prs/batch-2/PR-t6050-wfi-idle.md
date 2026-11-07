arm64: idle: T6050 idles in WFI even with idle=nop

m1n1 appends ` idle=nop arm64.nowfxt` to the command line on M4 and later chips with locked Apple system registers, after the user's arguments, so it cannot be overridden from the command line. Aurora's m1n1 and aura already skip the append for T8140, T8132, T6040 and T6041, but not for T6050, and the m1n1 builds people use on the M5 Pro (including ours) still append it. With `idle=nop` both cpuidle WFI states call a `cpu_do_idle()` that does nothing, so the J716s (MacBook Pro 16-inch, M5 Pro) never actually idled: every idle CPU spun.

This kernel already preserves the state WFI loses on these cores (`apple_wfi_quirk_init()`, WFxT forced off in idreg-override), and 5c9cbb25dba8 overrides `idle=nop` for T8142 for the same reason. This extends that override to the T6050 MIDRs (parts 0x064 and 0x065) and adds `apple_keep_idle_nop` (documented in kernel-parameters.txt) to keep `idle=nop` for A/B comparisons or as a fallback that needs no rebuild.

**Tested on:** J716s, `integration/aurora` + the T6050 PRs + this patch (kernel `7.3.0-gf080637018df`), m1n1 still appending `idle=nop arm64.nowfxt`, bootargs `kvm-arm.wfi_trap_policy=trap`:
- dmesg: `Apple: preserving registers across WFI`, `Apple: idling in WFI, ignoring idle=nop`; cpuidle driver `apple_idle`; CPU 0 spent 209 s of its first 211 s in the WFI state.
- Idle on the charger (SMC total system power): 16.4 W with the spinning idle -> 9.8 W with this patch (heatpipe 5.7 W -> 1.9 W).
- 56 min idle soak in one boot: no RCU stall (`panic_on_rcu_stall=1`), Oops or SError; a floating-point consistency run passes on all 18 CPUs; CPU 0 had 409k WFI entries.
- s2idle on the same boot: `pm_test` freezer, devices and platform, then a real `echo mem > /sys/power/state` with power-button wake (346 s suspended, `suspend_stats` success 4 / fail 0, USB, Ethernet and battery back).
- It has been the daily kernel since. On the 14-inch M5 Pro (J714s) betizzel measured 15.3 W -> 5.6 W with the same register-saving WFI.
- `arch/arm64/kernel/idle.o` builds with `W=1` (LLVM, arm64) on `integration/aurora` 4114f761f469; checkpatch `--strict` clean.

**Dependencies:** none; applies on `integration/aurora` 4114f761f469.

**Open questions:**
- Would you rather fix this in the loader, by adding T6050 to the `chip_id != ...` list in m1n1/aura `kboot.c` that already skips `idle=nop arm64.nowfxt` for T8140/T8132/T6040/T6041 (T6050 still needs `arm64.nowfxt` unless the kernel forces it, which it does)? The kernel override would then only matter for older loaders, as it does for T8142. Happy to send that one-liner instead or as well.
