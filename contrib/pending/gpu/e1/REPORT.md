# GPU E1 (2026-11-07), built on the Studio, not booted

(Saved by the coordinator from the agent's hand-back.)
| item | where | sha256 |
|---|---|---|
| m1n1 patch | `0026-kboot-T6050-GPU-handoff-opt-in.patch` (clone `m1n1/`, branch gpu-e1, 965b7d86 on f7555558) | 5e11a252d798f920... |
| m1n1 for E1 | `build/m1n1-plain-gpu.bin` (v2.0.0-73-g965b7d86) | a23a3e96ec1a4e05091add9df09f8dab270bc02d62be88aa6bdcb2cfe0ce497b |
| m1n1 base recipe check | `build/m1n1-plain-base.bin` = the daily's 28b26ebc | |
| kernel | `kbuild/Image.gz`, 7.3.0-gc0838b776f2b (`j716s-series-gpu`, worktree wt-gpu-e1) | 744216550510f5c03b18587bba06cc643586089f12ab72f51d041c3e6bca77e3 |
| DTB | `kbuild/t6050-j716s-gpu.dtb` | 0d19b701128583d54beab2c4c4c0579f3fd1d8a4bb18259c2db1c821177ff36f |
| E1a control payload (no variable) | `payloads/e1a-ctl-20261107-296e21f7.bin` | 296e21f7... |
| E1b payload (`chosen.m5pro,gpu=1`) | `payloads/e1b-gpu-20261107-b26e203c.bin` | b26e203c... |
Also: `RUN-E1.md`, `e1-readback.sh`, `mk-e1.py`, `build-m1n1.sh`, `build-kernel.sh`, `SHA256SUMS`, `kernel-patches/`, `test/run-test.sh`, `kbuild/diffconfig-vs-series.txt`.

## m1n1 0026 (numbering collides with the N1 series' 0026; renumber when stacked)
With `chosen.m5pro,gpu=1`, `dt_set_gpu_t6050()` (`src/kboot_gpu.c`) fills from the live ADT: four UAT regions from sgx;
`fw-text` = gfx-asc `__TEXT` start to gfx1-asc `__TEXT` end; `fw-data` = gfx-asc `__DATA` start to gfx1-asc
`__DATA_SHARED_RO` end; each mailbox `reg` from the ADT coprocessor with the same role (GFX, GFX1), iop-vbar cut to 8 bytes.
Checks first: both spans contiguous and DATA bases match sgx; six regions 16 KiB aligned; the GPU sgx window matches; the
mailbox interrupts belong to that coprocessor; gpx/afr/cs/gfx power-state addresses match. Then sets regions, mailboxes,
GPU and PMGR nodes okay. Any failed check: `STOP`, everything stays disabled, boot continues, no register written.
Without the variable: DT unchanged. 0024 not needed (gfx-asc/gfx1-asc have no `__OS_LOG`; regions outside Linux RAM and
no-map). Merges onto n1-handoff cleanly (shared helpers copied from the N1 series).

## Kernel `j716s-series-gpu`
8dd2f604 merge #1012 at b1615e3fca90 (contains #1056's M5 Max bare metal; #1070 not needed) into c2e1be601fb4
(`macsmc-hwmon.c` auto-merged); b007205e board file: GPU nodes on their own 1:1 `soc@2300000000` bus with
`nonposted-mmio`, all disabled, `gpu` alias (DTB = daily 594f2a9f plus additions); c0838b77 `j716s-gpu.config`: RUST=y,
DRM_ASAHI=y, APPLE_PMP off, G15/G16/G18/M5 backends off, MTD_PHRAM=y. No t6050-pro board table: #1012's own
`M5NoBareMetalTables` maps sgx, prints the ID registers and core masks, and refuses with "M5 Pro bare-metal GPU tables
not yet available". Built in the Fedora 43 container.

## Host test
Real `dt_set_gpu_t6050()` + m1n1's pmgr.c + libfdt against the private ADT and the DTB (ASan/UBSan): no variable or `=2`
-> unchanged; `=1` -> ten nodes okay with the ANALYSIS values (fw-text 0x100_00ff_0000 + 0xa4000, fw-data
0x100_0251_8000 + 0x184000, UAT at 0x10b_fff2_0000.., GFX power state 0x23_00e8_0110); three corrupted DTBs -> STOP.

## RUN-E1 (pass / stop / safety)
Precheck on the daily; E1a (control, unattended via the loop); E1b. Deploy via `mk-daily.py --deploy-plan` from the daily
`dcec81ed` so prev stays the daily; readback `e1-readback.sh`. Pass: m1n1 six regions (0xa4000 / 0x184000) ending
`nodes okay`; kernel six `reserved mem` lines, "always-on domain afr/gfx ... turning it on", `aurora 2300000000.gpu: GPU
ID registers: 0xb031100 ...`, core masks, the refusal; no SError/oops/panic/RCU stall/DART fault; network up;
`VERDICT: PASS E1`. Stop: m1n1 STOP (safe), wrong variant/revision, ID all 0, any fault/stall. Safety: prev has no
selftest flag; hang before root -> 150 s stage-1 watchdog -> prev; network failure after root -> 90 s self-revert; no DMA
at E1 (coprocessors stopped, no mailbox driver binds, driver refuses before UAT/firmware/InitData).

## Uncertain
GPU probe appears about 10 s late (mailbox nodes okay with no driver -> deferred-probe timeout; fallback: keep mailboxes
disabled at E1). Turning GFX/AFR on from Linux is the one hardware risk (GFX has notify_pmp while the PMP is stopped; E0
read fine). The ID may differ (clean refusal either way). No ADT capture from the 60.65 stub (m1n1 checks the live ADT;
a moved image gives STOP). GFX/AFR stay on for the E1b boot (power not measured). Disk: /Volumes/linux-cs 5.3 GB free
(wt-gpu-e1-out 3.8 GB can go). Next: E1a, E1b; then E2 (J716S board table with text_sha256 = 0 to print the live digest).
