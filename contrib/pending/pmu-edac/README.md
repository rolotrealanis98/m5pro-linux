# cpu.pmu, soc.edac and the T6050 AES (2026-11-23)

Branch `j716s-pmu-edac` (worktree `/Volumes/m5pro/wt/pmu-edac`, base `j716s-ane2293` `0c6bb36ed14a`), two local commits, not pushed.
Test request: `/Volumes/m5pro/bench/requests/pmu-edac-1.md`.

## cpu.pmu: already in the tree, nothing to add

The ledger row is stale. `drivers/perf/apple_m1_cpu_pmu.c` has `apple,t6050-pmu` (commit a72508e86d42, DjDeveloperr, "Support the
T6050 core PMU": M4 counter layout, 16-bit event fields, T6050's own event numbers from XNU `cpc_arm64_events.c`, counters 2-9,
PMUv3 and generic event maps, `apple,t8142-pmu` reuses it) and `t6050-base.dtsi` has the `pmu` node (one AIC FIQ, both core types
raise it as `AIC_CPU_PMU_P`, comment says "measured on the J714s"). The J716s does not disable it (only `t6050-k116s.dts` does),
`CONFIG_APPLE_M1_CPU_PMU=y` is in asahi.config, and the daily config has `ARM_PMU=y`. The event table is not conservative-generic
but the real one, so I changed nothing. What is missing is only a J716s measurement: the test request asks for `perf stat` per
cluster. Only open question: both clusters (6 super + 12 performance cores) share one `arm_pmu` instance with one FIQ; that is the
J714s-measured design, the test checks cycles/instructions on a core of each type.

## soc.edac: T6050 match added (built, never run)

- `mcc.c` is not an error driver: it is the system level cache allocation driver (T8132/T8140 `apple,*-mcc`), the T6050 node in
  `t6050-ultra.dtsi` is for it. It has no error counters. Nothing to do for EDAC there (and turning cache allocation on is a
  separate, behavior-changing step).
- `apple_soc_edac.c` had no T6050 entry although the DT nodes `error_handler` (105 interrupts) and `event_log_handler` (23) exist
  in `t6050-peripherals.dtsi`, disabled. The J716s ADT (`adt-guest.bin` in the Windows bench runs, parsed with a small parser)
  names every interrupt: amcc 0-7, pmgr 8, afxni 9-44, afins0-15 45-60, afcns0-10 61-71, sep 72-77, cllt 78, piogw 79-80,
  sram-parity 81-85, axi2af 86-104 (DCS lines are not in the DT).
- Added `apple,t6050-error-handler` (claims pmgr 8, sep 72-77, sram 81-85, as the T6041 policy: mask on fire, backoff rearm, no
  register writes) and `apple,t6050-event-log` (all 23 lines). Left unclaimed on purpose: AMCC (other SoCs assert them from boot
  and a status read resets the AP), fabric NIs afxni/afins/afcns, cllt, piogw, axi2af: no acknowledge contract known for T6050
  (the T8140 table came from `niN-metadata`; the T6050 ADT has the NI apertures but nobody has decoded them). Extending to the NIs
  means a status-word table like `t8140_ni[]`, needing the NI metadata from the ADT; not infeasible, not done.
- `t6050-j716s.dts` enables both nodes. Risk: a claimed line that is asserted from boot logs one "hardware error" per line and
  counts a UE in EDAC (no panic: `edac_device_handle_ue` only panics with `panic_on_ue`); the driver then masks it.

## AES (coordinator request): added, built, never run

`apple,t6050-aes` -> `apple_sio_aes_v5`; `&aes` enabled on the J716s (needs `sio_dart` okay: done by `t6050-j714s-sleep.dtsi`).
`CRYPTO_DEV_APPLE_SIO_AES=m`, `APPLE_SIO=m`, `CRYPTO_ENGINE=m` already come from asahi.config (verified in the kbuild config),
so j716s.config is unchanged. `drivers/crypto/apple-aes.ko` was not in `tooling/pr-verify/targets-daily.txt`, so I added that
line (uncommitted in the private repo; the other agents' builds now package one more module).
