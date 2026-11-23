# Scaler, SIO, AUSS, AES: feasibility (2026-11-23)

Sources: the J716s macOS 27.3 ADT/IORegistry (properties only), the kernel tree `/Volumes/m5pro/linux` branch
`j716s-ane2293` (read through `git show`), and public lore threads for apple-sio. No binaries were examined.

## Headline: the ledger rows are stale

Both rows say "no Linux driver anywhere". The kernel tree already carries drivers and T6050 bindings/nodes for most of this
(mostly by Ryan Murray / aurora-silicon, 2026-11-11/12):

| Block | In the tree | T6050 state |
|---|---|---|
| AES | `drivers/crypto/apple-aes.c` (skcipher ECB/CBC/CTR, software keys only), binding `crypto/apple,aes.yaml` lists `apple,t6050-aes` | DT node `aes: crypto@50500c000` exists (disabled, `iommus = <&sio_dart 1>`, `ps_aes`). **Driver match table has no `apple,t6050-aes`** (only t6000, t8112, t6041, t8140). The node's `apple,aes` fallback is not matched either. |
| SIO | `drivers/dma/apple-sio.c` (2351 lines, protocol 10 for T6050), `CONFIG_APPLE_SIO=m` in `contrib/validated/integration/r1/config-r1` | Runs on the sleep board (needed so deep sleep can stop it); node replaced in `t6050-j714s-sleep.dtsi`. No consumer. |
| Scaler | `drivers/media/platform/apple/scaler/` V4L2 mem2mem, MSR hardware-version 10..22 only (direct MMIO) | T6050 is hardware-version 24 (ADT `hardware-version = 0x18`): firmware/descriptor family. Binding `media/apple,scaler-v23.yaml` + nodes `scaler0/1` + `scaler0/1_dart` exist, **disabled, no driver**. |
| AUSS | binding `usb/apple,usb-auss.yaml` ("no driver uses it yet") and `phy-coproc` node for `auss-cpu0` | Nodes exist, disabled, no driver. |

CRYPTO_DEV_APPLE_SIO_AES and VIDEO_APPLE_SCALER are not in the daily config (`config-r1`).

## AES (`aes@500C000`, `aes,s8000`, `aes-version 5`)

- Register-level engine, no firmware: command FIFO, key/IV slots, DMA between two addresses behind the SIO DART (SID 1;
  ADT `address-width` 0x2a = 42 bits, same as the T6041/T8140 "rev 5" data in the driver). Three reg banks
  (engine, shared control, aux). `sioaesdisable*` offsets in the ADT are the key-disable / GID/UID fuse banks; the driver
  never maps them. One IRQ, power domain `AES`.
- macOS uses it with hardware UID/GID key selectors (keystore); Linux cannot and should not (no software access to those).
- Minimal step: add `{ .compatible = "apple,t6050-aes", .data = &apple_sio_aes_v5 }` to `apple_sio_aes_of_match`, enable the
  node on the J716s (needs `sio_dart` okay, already done on the sleep board; `ps_aes` present), build
  `CONFIG_CRYPTO_DEV_APPLE_SIO_AES=m` + `CRYPTO_ENGINE`. The driver self-registers and the crypto manager self-tests run
  it. Effort: S (hours), plus one boot.
- Value: nearly none for speed. ARMv8 CE does AES faster than a bounce-buffered DMA engine. It counts as "hardware used".
  Risks: rev 5 untested on T6050 (readiness/DMA address word), SIO DART SID 1 mapping vs the sleep path's DART save/restore.
- Verdict: feasible now, S. The only block where the driver already exists.

## SIO (`sio@5E00000`, `iop,ascwrap-v6`, protocol 10)

- RTKit-style coprocessor with firmware preloaded by iBoot (`segment-ranges`, `pre-loaded`), behind `dart-sio`. The ADT
  `dmashim` lists exactly two client groups: SPI (the `spi0..4` block at 0x505100000) and UART (`uart0`, 0x505200000).
  DP-audio on T6050 uses the five `admac-disp*/dispext*` ADMACs, not SIO (the J714s DT has `dmas = <&admac_dispext0 0>`).
- So the only possible consumers are SPI and the debug UART. spi4 is the panel TCON (owned by the DCP firmware, not for
  Linux). spi2 carries `mesa` (Touch ID sensor, tiny transfers). `spi-apple` PIO is enough; an SIO-DMA SPI path would need a
  new `dmas` binding in spi-apple (none exists) for no throughput gain.
- Verdict: nothing worth consuming. Keep it as is (needed for sleep). The row's "S if a consumer appears" should read
  "no consumer exists on T6050". Not planned.

## Scaler (`scaler0@85000000`, `scaler1@A1000000`, `scaler,t8101`, hardware-version 24)

- Two instances, 10 reg apertures and 20 IRQs each, DART per instance (SID 0 pixels, SID 1 "PIODMA" register stream), power
  domains `MSR` + `MSR_ASE_CORE`, `direct-dart-power`, firmware segments (`__TEXT;__DATA`, `pre-loaded`) with a
  mailbox/scratch/dashboard interface, `perf-workloads`, `function-set_perf_state_floor`. That is a firmware-fronted engine:
  driver must hand over to firmware, speak its descriptor protocol and vote performance states. The older direct-register
  driver cannot be reused beyond format tables and the V4L2 mem2mem shell.
- A V4L2 mem2mem driver (copy `apple-scaler-drv.c` structure) is the right shape. The hard part is the unknown v23
  protocol: needs a capture of macOS (m1n1 hypervisor trace) or the aurora folks' notes. Effort: XL (weeks), as the ledger says.
- Who needs it: the ISP/camera path (macOS uses it for CSC/scale after the ISP) and video tools. GPU/ffmpeg do the same in
  software. Camera already works without it.
- Verdict: feasible in principle, low value, protocol unknown. First step is a read-only look (below), then an hv trace.

## AUSS (`auss-cpu0@95D08000`, `usb-auss0@953F0000`, `dart-auss0`)

- "USB audio subsystem": an xHCI controller (`AppleT6050USBXHCIAUSS` appears in the IOKit class list) with its own
  coprocessor `auss-cpu0` (`iop,mxwrap`, role AUSS0, RTKit nub `rtbuddy-v2`, firmware preloaded by iBoot, four IRQs), its own
  DART, a pile of fabric tunables (`tunable_DATA_FABRIC`, `AUSSAXI2AF`, `INTR2AXI`, `USB3A`, `XHCI_CAPABILITY`). Its purpose
  is USB audio class offload so headsets keep playing while the AP sleeps. The ATC routers already take `ps_auss`
  power-domain votes in our DT.
- Minimal Linux driver: bring up `auss-cpu0` (mailbox + RTKit boot), apply the tunables, then drive the xHCI with `xhci-plat`
  behind `auss0_dart`. Audio offload semantics beyond that are firmware protocol, unknown. Without the offload protocol it
  would just be a second, unused xHCI with no ports routed to it.
- Effort: L-XL, high risk (touching the shared `AUSS` power domain that the working USB-C ports depend on).
- Verdict: not worth it; leave not planned. Value only for sleep-time USB audio, a feature Linux has no use for yet.

## First concrete step

1. Now, no build, read-only: `/Volumes/m5pro/bench/requests/scaler-sio-aes-1.md` (checks the running kernel's view of these
   nodes, sio state, `/proc/crypto`, power-domain state without touching any register).
2. Next, needs a kernel build (not done here, builds belong to others): add the `apple,t6050-aes` match + enable the node +
   config `CRYPTO_DEV_APPLE_SIO_AES=m`; the probe itself reads the READINESS register and logs it (that is the ID/readiness
   read), debugfs `stats`, and the crypto self-tests exercise it. Check against `kcapi`/`tcrypt` afterwards.
3. Scaler: after a 27.3 hv trace of the scaler firmware handoff, enable `scaler0` with a probe-only driver reading the first
   mailbox/status word, mirroring the commit "add a probe-only driver for the scaler/CSC engine" (37888b11fb7a) used for v10..22.

Raw register peeks (devmem) are not recommended on T6050: a read of an unpowered block (`AES`, `MSR*`, `AUSS` power-gated)
can SError and hang the machine; go through the driver's pm_runtime path instead.

Sources: lore.kernel.org/asahi "Apple SIO driver" (Povišer, 2023) describes SIO as the SPI/UART/DP-audio pretend DMA
controller. No public docs on AUSS or the M2 scaler were found.
