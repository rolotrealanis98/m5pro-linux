# PMP on the 16-inch M5 Pro (J716s, T6050): ADT facts vs edimoldovan's J714c

Source: J716s (Mac17,8) runtime ADT, read offline with m1n1's `proxyclient/m1n1/adt.py`
(`adt-pmp-extract.py` in this folder prints everything below). Only hardware-description
properties are quoted. The capture is from before our stub was recreated on 27.3 beta 1
(`/chosen/firmware-version` = `mBoot-20457.41.2`). The machine runs `mBoot-20457.60.65.0.1` now.
Register layout should not depend on firmware, but the flags could change, and we have not re-read
the ADT on the new stub.

J714c values come from edimoldovan's #293 comments of 2026-11-03 and 2026-11-06.
Absolute address = arm-io-relative + `0x2_0000_0000` (`/arm-io` `ranges[0]`).

## Side by side

| Block / property | J714c (edimoldovan) | J716s (ours) | |
|---|---|---|---|
| PMP ASC, `/arm-io/pmp0` reg[0] | `0x284e00000` | `0x284e00000`, size `0x88000` | match |
| PMP mailbox | `0x284e08000` | `0x284e08000` (ASC + `0x8000`, ascwrap mailbox block; no separate node) | match |
| PMP IRQs (AIC) | 396-399 | `pmp0` `interrupts = [397, 396, 399, 398]` | match |
| pmp0 reg[1] | (J716c: `0x284850000`) | `0x284850000`, size `0x4000` | match |
| PMP firmware memory, pmp0 reg[2] | `0x284500000`, 1 MiB | `0x284500000`, size `0x100000` (nub `region-base`/`region-size` agree) | match |
| PTD update, pmp0 reg[3] | `0x284250000` | `0x284250000`, size `0x4000`; `ptd-update-reg-index = 3` | match |
| PTD report aperture | `0x284240000`, size `0x14000` | base `0x284240000` is pmgr reg[7] and ane0 reg[3] (size `0x40000`) and an mcc reg (size `0x4000`). No `0x14000`-sized entry in our ADT | base matches; size not found |
| `iop-pmp0-nub` `ptd-range` | 29 entries (table of 11-03) | the same 29 ids, offsets and names (PMP-STATUS `0x1`, SOC-DEV-PS-REQ `0x1e0`, SOC-DEV-PS-ACK `0x1e8`, PMP-TO-GFX `0x2b5`, GFX-TO-SMC `0x27a`, ...) | match |
| PMP DART, `/arm-io/dart-pmp0` reg[0] | `0x2841a0000` | `0x2841a0000`, size `0xc000`, `dart,t8110` | match |
| DART IRQ | 371 | `interrupts = [371]` | match |
| DAPF aperture, dart-pmp0 reg[1] | `0x2841b0000` | `0x2841b0000`, size `0x4000`; `dapf-instance-0` has 31 entries | match |
| DART node name | `dart-pmp0` (m1n1 lists `dart-pmp`) | `dart-pmp0`; no `/arm-io/dart-pmp` node | match (same m1n1 gap) |
| PMGR PS, PMP (ADT gate 27) | `0x280600128` | `0x280600128` (`PMP`, critical, parent `PMS`) | match |
| PMGR PS, PMS_SRAM (ADT gate 28) | not posted | `0x280600130` (`PMS_SRAM`, critical, parent `PMS`) | n/a |
| GPU PS registers (gpx, afr, cs, gfx at `0x2300e80000/100/108/110`; aic_gfx, pms_gfx_c1ppt, soc_dpe_gfx, b2b_ctrl_gfx, fppt_gfx at `0x2380600108/110/118/128/198`) | as in the 11-03 table | the same addresses | match |
| CS (id2 361, group 3, offset `0x108`) | `notify_pmp = true`, id1 16, parents 360 (AFR) and 359 | `notify_pmp = false`, id1 0, parent AFR (360) only | **differ** |
| GFX (id2 362, group 3, offset `0x110`) | not posted | `notify_pmp = true`, id1 16, parents AFR (360) and GPX (359) | see below |
| Firmware at the test | `mBoot-20457.60.65.0.1` | same on the machine now (ADT capture: 41.2) | match |
| PMP ASC `CPU_CONTROL` (+`0x44`) | `0x00000000` at handover, after opening the DAPF from the proxy | pending: Linux readback after a reboot into an m1n1 with the dart-pmp0 DAPF entry. This is the after-boot point, not the handover | pending |

**On CS vs GFX.** On J716s, the attributes quoted for the J714c CS entry (id1 16,
`notify_pmp`, parents 360 and 359) are exactly those of the next entry, GFX (id2 362, offset
`0x110`). CS itself is not flagged. joshuaswarren reads J716c the same way. So either the J714c table
really differs, or the J714c values belong to GFX. One look at the J714c id2 362 entry settles it.

## Other J716s PMP facts

- `/arm-io/pmp0`: `compatible = iop,ascwrap-v6`, `clock-gates = power-gates = [27, 28]`,
  `sram-index = 1`, `iop-version = 1`, `role = PMP0`, `segment-names = __TEXT;__DATA;__ETEXT`,
  `iommu-parent` = `mapper-pmp0` under `dart-pmp0`.
- `iop-pmp0-nub`: `compatible = iop-nub,rtbuddy-v2`, `firmware-name = t6050pmp`, `pre-loaded = 1`,
  `no-shutdown = 1`, `user-power-managed = 1`, `ptd-driver-version = 1`, `pm-ptd-ranges` =
  ids 1-8, 40, 9-14.
- `/arm-io/dart-pmp0`: `dart-id = 12`, `sid-count = 16`, `sid` = 0, 1, 2, 5, 6, 7, 8, 9,
  `page-size = 0x4000`. `clock-gates` and `power-gates` are present but empty. Unlike `dart-aop`,
  it has no `allow-dram-apf-slices-0`. With `clock-gates` empty, m1n1's `dapf_init()` neither powers the
  node up nor down around the DAPF writes.
- No `/arm-io/pmp1` on J716s. `pmgr` has `pmp = 2` and no `function-pmp_control` (as on J714c).
- `notify_pmp` and `id1` (for joshuaswarren's point 2): the devices flagged `notify_pmp` have
  either `id1 = 0` (DISPEXT0-3_SYS, DISP_SYS, SCODEC_STREAMING, MSR0/1_ASE_CORE, ANE_SYS, TRACE_FAB_GFX) or a value
  from 13 to 37. The only ones at 15 or below are the CPU-cluster managers MCPM0, MCPM1 and PCPM
  (13, 14, 15, PS offsets `0x90/0x98/0xa0`). The rest: GFX 16, ANE_SYS_V_PMP 17, ISP_SYS 18,
  DISP_FE 19, DISPEXT0-3_FE 20-23, VENC0/1 24/25, AVD 26, MSR0/1 27/28, JPG 29, SCODEC 30,
  PRORES 31, ATC0-3_COMMON 32-35, AUSS 36, ANS 37. If `id1` is the device id that the PMP power
  command takes, a `device_id > 15` check would let through only the three CPU-cluster managers.

## How the J716s numbers were read

```
~/Work/m1n1/.venv/bin/python -I adt-pmp-extract.py adt-runtime-j716s.bin
```

It uses `load_adt()` and `pmgr_dev_get_addr()` from m1n1's `adt.py`. On T6050, `ps-regs` is absent,
so a device's PS address is `pmgr reg[ps_groups[group].reg]` + `offset`.
