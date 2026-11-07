arm64: dts: apple: Add J716s (MacBook Pro 16-inch, M5 Pro)

The M5 Pro MacBook Pro 16-inch: one T6050 die, like the J716c. Commits 1-12 are #935 (1-9) and #945 (10-12) as carried, rebased onto `integration/aurora` (only the qspi binding needed a conflict fix: `enum: [t6050-qspi, t8152-qspi]` + `const: t8140-qspi`); they drop out once #945 merges. New here:
- t6050-max: list the 18 CPUs in the ADT's order (m1n1 `dt_set_cpus()` stopped at `DT CPU 5 MPIDR mismatch: 0x40100 != 0x40005`);
- t6050: the SMC's second GPIO bank (`apple,smc-low-gpio`, as on T6030/T6031);
- `apple,j716s` in `arm/apple.yaml`;
- `t6050-j716s.dts`: from J716c, plus the J716s N1 platform ID, keyboard backlight PWM, ATC0 gadget, left-front Type-C (SN201202x hpm1 + graph; USB3 with the loader-filled tunables), trackpad AFE reset on SMC gp1c, `apple,internal-panel` for simpledrm, the T8112 cpufreq fallback. Right port, ATC3, SMC sensors off;
- `j716s.config` fragment (as `j813.config`).

**Tested on:** J716s, R3-SERIES and R3-S (2026-11-07), DTB byte-identical to this branch's: NVMe root, keyboard and trackpad, USB3 left-front, network, SMC (battery Full 100 %, 33 cycles, AC online), 18 CPUs, simpledrm eDP. `make dtbs`: 1912 DTBs, no warnings. `W=1`: one, `gpio@67700000` has a unit name and no `reg` (as t6031). `dtbs_check` not run (no dt-schema here). Not booted on J716c or J775D (CPU order, SMC GPIO node).

**Dependencies:** #935, #945 (contained); cpufreq binding (#481 or our `pr/t6050-cpufreq-binding`). Runtime: #936 NVMe, #939 + #946's three PHY commits for USB3, #941 or our SMC match, our rtkit-timeout and dockchannel PRs; #937/#938 for the N1.

**Open questions:**
- How does your m1n1 boot J716c with the old CPU order (match by MPIDR, or a different ADT order)?
- Add `apple,j716c` to `apple.yaml` in the same patch?
- `apple,t6050-fpwm` (keyboard backlight) has no binding yet; add it to `apple,s5l-fpwm.yaml` here or separately?
- `smc_gpio_low` unit name: keep `@67700000` like t6031 or drop it to silence W=1?
- Keep or drop the `[ADT]`/`[OURS]` provenance tags in comments? Trim the config fragment to the boot path?
