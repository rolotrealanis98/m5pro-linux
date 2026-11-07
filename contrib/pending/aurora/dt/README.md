# Aurora kernel device tree for the J716s (decompiled, post-processed)

`t6050-j716s-aurora-decompiled.dts` is the device tree that boots the Aurora Silicon kernel on the
J716s (payload R3-T, 2026-11-07). It is the decompiled PR #945 J716c DT plus the J716s changes made
during round R3 (`contrib/pending/integration/RESULTS.md`): CPU nodes in ADT order, driver fallback
compatibles (smc t8103, cluster-cpufreq t8112, cio-reset t8142), the ANS/SART nodes as PR #936 wants
them, the `apple,smc-low-gpio` child and `apple,afe-reset-gpios` on `input@8000`, the left-front
Type-C chain (`usb-pd@a`, connector graph, combo PHY), and NO `apple,tunable-*` lists on the PHY:
stage-2 m1n1 patch 0021 (`contrib/pending/integration/patches/m1n1/`) fills those from the ADT at
boot (verified: 14 properties present in the live DT on R3-T). The `.dtb` next to it is the compiled
form (dtc from the Aurora tree). Proper source form (`t6050-j716s.dts` against the Aurora dtsi files)
is still to be written; see `contrib/pending/aurora/J716S-DELTA.dts.md` for the sourced draft.
