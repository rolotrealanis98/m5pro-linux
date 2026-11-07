# J714s/J714c findings checked against the J716s

Kernel: `/Volumes/linux-cs/wt-series` `j716s-series` `dd6b39464ca9` (not touched). Scratch worktree for the
cherry-pick and the config check: `/Volumes/linux-cs/wt-j714s-scratch`, output dir
`/Volumes/linux-cs/wt-j714s-scratch-out`. Nothing booted, nothing pushed, no MacBook access.

| # | Finding | Verdict | Patch |
|---|---|---|---|
| 1 | P-state N runs at table entry N-2 (betizzel); edimoldovan uses entry+1 | Our DT is already N-2 for both M and P, so `scaling_cur_freq` is right. edimoldovan's table is one step high. P offset and the top states are still unmeasured on the J716s | none needed |
| 2 | edimoldovan 4f8b07f31d66, re-arm USB 2.0-only ports | Does not apply (`t6050-usb2.c` is not in our tree) and is not needed: our combo PHY reruns the full USB2 start on every attach | none |
| 3 | MTP haptic with magicmouse built in | Config-only, DT already has the `actuator` node. Worth one A/B boot | `patches/0003-*.patch` |

Details: `PSTATE.md`, `USB2-REARM.md`, `HAPTIC.md`.

## 1. P-states

- Our `opp-level` is the raw hardware p-state (the driver writes it to PS1 and matches status bits 9:5 against it).
  Level N has `opp-hz` = J716s ADT entry N-2 for every OPP, M levels 2-16 and P levels 2-21 (script check).
  betizzel measured the same on a J714s M cluster (p6 -> 2649 MHz = entry 4); Aurora's base dtsi says the same
  for the T8142 family. The J716s M and P tables equal betizzel's J714s ones, frequency and voltage.
- edimoldovan's J714c is level = entry + 1. On his kernel, which reads the command register back, every reported
  frequency would be one step above the real one. Worth telling him; nothing to change here.
- Still open on the J716s, answerable in one boot with the tools already built
  (`~/Work/agents/cpufreq/tools/cpuhz`, `dvfs-regs`; commands in `PSTATE.md` section 5): the P cluster offset
  (guess N-2, no measurement anywhere), whether M p16 (4380) is refused here as on the J714s (so the
  "4380000" in the R3-Q summary is the table, not a clock), and P p18-p21. A `turbo-mode` override is described in
  `PSTATE.md` section 6; I did not make it a patch because the question asked for one only if the DT were off.
- Side observation: our level 1 (300 MHz) is Aurora's T8142 convention, not an ADT entry; schedutil's idle floor on the
  J716s is p1, betizzel's tables start at p2. Unmeasured on T6050.

## 2. USB replug

- `git cherry-pick -n 4f8b07f31d66` at `dd6b39464ca9`: modify/delete conflict, the file is edimoldovan's separate
  T6050 USB 2.0 PHY driver from `ae65f0d3a88e`.
- Our path (series 0018, 0020, 0023-0028, m1n1 0020, hpm1/hpm2 nodes 0057/0060): detach puts the mux in SAFE
  and `combo_stop()` powers the USB2 banks off; attach runs `combo_start()`, which repeats the whole
  `apple_t6050_usb2_host[]` sequence (tunables, reset, run, host bits). That is his re-arm, event-driven. His timer would
  write to unclocked PHY registers on an empty port. Your hub and right-port replugs worked on exactly this path.
- The 70 s on the left port: nothing on the PHY path can take that long by code reading (tipd polls at 500 ms);
  keep `journalctl -k -o short-monotonic` on the next replug to compare the Type-C and xhci timestamps.

## 3. Haptic

- `HID_MAGICMOUSE` depends on `HID_APPLE_MTP_HAPTIC || !HID_APPLE_MTP_HAPTIC`; `asahi.config` has haptic `=m`;
  our fragment set `=n`. `=y` plus magicmouse `=y` resolves (checked below) and is what betizzel runs on the J714s.
- DT: J714s and J716s are equivalent (`actuator {}` and `tp-accel {}` under `input@8000`); the J716s ADT has exactly
  those children. No DT patch. `apple,click-strength` (only t8112-j413 sets it) is not set and has no value
  measured for this pad.
- Not booted on the J716s; it adds code to the working trackpad's path, so do it as an A/B with the current payload as
  the fallback. What to check is in `HAPTIC.md` section 4.

## Patch 0003 checks

- `git apply --check` against `wt-series` (`dd6b39464ca9`): clean. Applied in the scratch worktree as one commit.
- `make LLVM=1 ARCH=arm64 O=<scratch out> defconfig asahi.config j716s.config`: the resolved config equals
  `/Volumes/linux-cs/wt-series-out/.config` line for line except `CONFIG_HID_APPLE_MTP_HAPTIC=y` (was not set);
  `CONFIG_HID_MAGICMOUSE=y` stays, `CONFIG_HID_HAPTIC` stays unset (not needed: the stubs cover it).
- `make prepare` and the two objects `drivers/hid/hid-apple-mtp-haptic.o` and `drivers/hid/hid-magicmouse.o` compile
  clean in the scratch output dir (macOS host needs `HOSTCFLAGS=-I.../host-shim` and
  `HOSTCFLAGS_file2alias.o=-D_POSIX_C_SOURCE=200809L`, as betizzel's `build-kernel-aurora.sh`).
- Not done: no link of the full kernel, no boot, no `checkpatch` run.

## Files

- `PSTATE.md`, `USB2-REARM.md`, `HAPTIC.md`, `REPORT.md`
- `patches/0003-arm64-configs-j716s-Build-in-the-MTP-haptic-driver.patch` (author and Signed-off-by Rolando Trevino,
  no other trailers; applies to `dd6b39464ca9`)
- `patches/0001-*` and `patches/0002-*` do not exist on purpose (verdicts above)
- `tools/pstate-tables.py`: the ADT-versus-DT check behind `PSTATE.md` (reads the ADT you point it at; prints only
  the `voltage-states*` tables)
- ADT use: only `/arm-io/pmgr` `acc-clusters` and `voltage-states*`, and the names of the `mtp-transport` children.
  Nothing from it is copied into these files except frequencies and voltages.
