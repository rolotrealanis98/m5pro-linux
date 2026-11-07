# betizzel (J714s) s2idle / UART-resume / WFI work, ported to the J716s

2026-11-07. Nothing booted, pushed or posted. Branch `j716s-betizzel` in `/Volumes/linux-cs/wt-betizzel`, on `j716s-series`
`aec60666a572`. Patches in `patches/`. (Report saved by the coordinator from the agent's hand-back; the agent was not allowed
to write it.)

## Headline
The J716s does not need most of betizzel's patches: Aurora 33bec4016c46 already carries his WFI register save
(c407e1097ba7, 6c03bd926fc5, 3f0822d73dbe, 34649b455f4a), the T6050 cpuidle driver (4253ee01142c, e82e308db725, a391e5394aad)
and a different fix for the samsung UART resume SError (68d35377bed1; no s5l-uart node exists in our T6050 DTs anyway).
**What blocks WFI idle on our machine is our own m1n1:** `kboot.c:351` appends ` idle=nop arm64.nowfxt` to the command line
(m1n1 3a69c73f "kboot: disable wfi/wfit if wfi loses state"; betizzel's older m1n1 v1.6.1-28 predates it). With `idle=nop`
both cpuidle WFI states call a `cpu_do_idle()` that does nothing, so the J716s has never idled in WFI. The "94 M WFI entries"
in `docs/status-2026-11-06.md` count entries of a spinning state.

## His stack
- Default kernel: AsahiLinux `asahi-wip-7.2` + `patches/linux/0001-0013` (all three features verified there).
- Aurora kernel: PR #1012 head `5b0f106acdd7` = our 33bec4016c46 + 132 GPU/DCP commits; WFI idle runs, lid sleep not qualified.
- linux 0011 samsung UART resume (63047c4); 0012 WFI register save (a5df9e4); 0013 cpuidle T6050; 0009 arm64.nowfxt override
  (asahi-7.2 only); m1n1 0007 reserve coprocessor `__OS_LOG` buffers (a5df9e4); config CPU_IDLE, ARM_APPLE_CPUIDLE, SUSPEND,
  PM_DEBUG, PM_SLEEP_DEBUG, EXPERT, PSTORE, DPM_WATCHDOG; bootargs: no `idle=nop`, keep `arm64.nowfxt`,
  add `kvm-arm.wfi_trap_policy=trap`; s2idle needs no other kernel patch (the SMC wakes it on lid open).

## Status on the J716s
| Item | Verdict |
|---|---|
| 0012 WFI register save | already in tree |
| 0013 cpuidle T6050 | already in tree (`CONFIG_ARM_APPLE_CPUIDLE=y`) |
| 0009 nowfxt | covered: `idreg-override.c:465` forces wfxt=0 on M4+ |
| drop `idle=nop` | **adapted: new kernel patch** (m1n1 appends it last; we never pass it ourselves) |
| 0011 UART SError | covered by Aurora 68d35377bed1; conflicts; skipped |
| SMC lid wake | in tree (mailbox IRQF_NO_SUSPEND, macsmc-input hard wakeup) |
| config | SUSPEND, CPU_IDLE, ARM_APPLE_CPUIDLE, PSTORE already y; **PM_DEBUG added** |
| `kvm-arm.wfi_trap_policy=trap` | bootarg, applies as is |
| m1n1 0007 `__OS_LOG` | applies clean on f7555558, `kboot.o` compiles; J716s ADT has the same 8 segments (0x140a28 bytes) |
| 7057150 macsmc-power | our 0048 has the INIT_WORK half; his removal-order and debug-param locking are not in our tree |
Not ported: EXPERT (moves defaults), DPM_WATCHDOG (no pstore backend; its panic would hang with the SoC watchdog stopped).

## Produced
- `ef12ff74fa28` arm64: idle: T6050 idles in WFI even with idle=nop (mirrors Aurora 5c9cbb25dba8 for T8142, extended to MIDR
  parts 0x064/0x065; opt-out early param `apple_keep_idle_nop`, documented). `patches/linux/0001`.
- `f080637018df` arm64: configs: j716s: Enable PM_DEBUG for s2idle testing. `patches/linux/0002`.
- `patches/m1n1/0001-kboot-reserve-coprocessor-__OS_LOG-buffers...`: betizzel's m1n1 0007 unchanged, his author line, a carry
  note, Link, our Signed-off-by. Not applied to any m1n1 tree. His repo has no LICENSE (removed in 45ecc1f): get his sign-off
  before sending it anywhere.
Checks: config differs from the booted one by exactly `+PM_DEBUG=y +PM_SLEEP_DEBUG=y`; `idle.o` compiles clean (LLVM=1,
`HOSTCFLAGS=-I$HOME/Work/omarchy-m5/scripts/host-shim`); checkpatch clean. No full build, no boot. No assistant trailers.

## Exact changes
- Kernel: build `j716s-betizzel` (SERIES.md recipe) into a new O= dir; add the two patches as 0059/0060 once they pass.
- Test payload bootargs: `--extra "kvm-arm.wfi_trap_policy=trap sysctl.kernel.panic_on_rcu_stall=1"`.
- Daily after promotion: add `kvm-arm.wfi_trap_policy=trap` to BASE.
- m1n1: leave the `idle=nop` append (older payloads such as prev R2-B still need it; the patched kernel ignores it).
- Rollback without rebuild: `--extra apple_keep_idle_nop`.

## Unattended-boot risk
Safety nets: A/B stage-1 (150 s SoC watchdog, then `apple_wdt` 30 s pinged by the kernel; a watchdog reset boots prev) and
m5-selftest (network check at 90 s). A hard hang or panic is recovered by the stage-1; a partial hang where the kernel still
pings the watchdog but userspace is dead is not. After a watchdog fallback `boot.bin` is still the test payload.
| Change | When | If wrong | Loop-safe |
|---|---|---|---|
| 0001 WFI idle | from `rest_init()` | (a) corrupted regs: panic -> watchdog -> prev; (b) a core never wakes / resets into the RVBAR trampoline: RCU stall at 21 s, only reverts with `panic_on_rcu_stall=1`; (c) rare userspace FP corruption: needs a soak | yes with panic_on_rcu_stall |
| 0002 PM_DEBUG | only if `pm_test` is written | sysfs only | yes |
| wfi_trap_policy | only with a KVM guest | none | yes |
| s2idle | only if something suspends (no-suspend drop-ins prevent it) | a hang inside the suspend window has no watchdog (`apple_wdt` stops it in suspend) | **no**; `pm_test=freezer` is safe |
| m1n1 `__OS_LOG` | every boot | a `bail` in `kboot_prepare_dt` stops m1n1 | via the stage-1 only |

## Test order
1. T1 WFI idle (loop-safe): `mk-daily.py --label wfi-t1 --battery --extra "kvm-arm.wfi_trap_policy=trap sysctl.kernel.panic_on_rcu_stall=1"`,
   selftest on, prev = daily. Pass: network OK; dmesg "Apple: preserving registers across WFI" and "Apple: idling in WFI,
   ignoring idle=nop"; `/proc/cmdline` still ends in `idle=nop arm64.nowfxt`; nproc 18; no RCU stall/Oops/SError.
2. T1 soak: 1 h idle, repeat checks; per-CPU register/FP check on 18 CPUs (his `tools/wfi-check.c` has no license: write our
   own); SMC idle power vs the daily (J714s: 5.6 W vs 15.3 W); one clean reboot.
3. T2 optional: same + `apple_keep_idle_nop` (expect no "idling in WFI" line).
4. Promote: `--daily`, add wfi_trap_policy to BASE.
5. T3 loop-safe: `pm_test=freezer`, `echo freeze > /sys/power/state`, `pm_test=none`.
6. T4 attended: `pm_test=devices` twice in one boot, then `platform`, then a real lid sleep with the drop-ins removed;
   check `suspend_stats` and BOOTTIME-MONOTONIC growth.
7. T5 m1n1 `__OS_LOG` (loop-safe via the stage-1): pass = `dmesg | grep oslog@` lists 8 regions and the network is up.
