T6050: boot the J716s: start all CPUs, accept the ANS split BAR, allow nine I2C controllers

aurora-wip has never booted a T6050 (MacBook Pro 16-inch M5 Pro, J716s). A cold boot of b6b4592 with a kernel, DTB and initramfs appended stopped before Linux: kboot disabled the secondary CPUs ("is not alive"), `nvme_init()` refused the ANS register layout ("invalid split BAR geometry"), and `kboot_prepare_dt()` failed on "ADT: too many /arm-io/i2c devices", so m1n1 fell back to the proxy ("No valid payload found"). These four commits address those three failures.

1. kboot: allow up to 16 /arm-io/i2c devices. The J716s ADT has i2c0 to i2c8; `dt_disable_missing_devs()` takes at most eight, and that was the only error that failed FDT preparation.
2. smp: t6050: release a core with its own CPU_START bit. T6050 has three clusters of six cores, so `BIT(4 * cluster + core)` names another core from cluster 1 on. CPU_START +0x0/+0x4 read 0x3fffe at rest (one bit per secondary, by ADT cpu-id), and XNU sets `BIT(cpu-id)`. This uses the cpu-id as T8142 already does. The +0x8 core-start write is unchanged.
3. smp: t6050: forward cores locked to a stage 1 base the image left. iBoot locks every secondary's RVBAR to the stage 1 base. A stage 2 with a kernel appended (about 38 MiB) does not fit below the secondary-only CTRR window (about 12 MiB of room on a J716s), so a stage 1 that places it above the window runs it at another address, and `smp_prepare_rvbar()` refuses every core. On T6050 this rewrites slot 0 of the retired stage 1's vector table, once, with the absolute forwarding stub start.S already writes for a moved M3 image. It does this only if that table has our four slot tags, lies in RAM below this image and outside the CTRR window, and we are at EL2. kboot reserves the page. The T8140 relay shares the write and read-back helper and behaves as before.
4. nvme: t6050: accept the T6040 split BAR layout. The J716s ANS has a 0x10000 "nvme" region and a 0x60010 NVMMU, with the linear queue registers in the NVMMU block. That is the layout of Linux's `apple,t6050-nvme-ans2` profile (`lsq_in_nvmmu`). Unlike T6040, `LINEAR_SQ_CTRL.EN` is still set, because it has not been shown that the T6050 firmware sets it after a cold ANS boot.

The remaining messages from that boot do not fail FDT preparation and need no change: "Failed to find AIC affinities node" and "/cpus/cpu-map node not found" (the DT has neither), "/arm-io/wlan not found", the missing atcphy/usb4 aliases, "unknown compatible, skip display reserved-memory setup", "ADT: GPU: unsupported chip!", "sep alias not found", "pmp not found" and "nvram partition not found". Each one already skips and returns 0.

Testing:
- Built with clang/lld 21.1.8 and rustc 1.99.1 (Fedora 43 container). The base and each commit build with 15 warnings, the same as the base, none new. The changed lines are clang-format clean.
- With #65 on top, the tree builds with no new warnings.
- [boot result on the J716s: to be filled in after the attended boot]

The stage 2 that boots this J716s on 18 CPUs every day has equivalents of commits 3 and 4: the same forwarding stub at the locked RVBAR (since 2026-11-04), and ANS started with its linear queue registers reached at +0x24908 of the 0x10000 region. It writes the CPU_START bits as aurora-wip does today, which starts the cores but sets the wrong +0x4 bit from cluster 1 on. That stage 2 is based on an older upstream m1n1 whose `dt_disable_missing_devs()` has no bound check: on the J716s it writes a ninth address past its eight-entry buffer, which happens not to break anything. aurora-wip's check catches that write and fails instead.

Questions:
- T6051 (M5 Max) probably needs the same changes. I only have T6050 data, so everything here is gated on T6050. Should T6051 be added now?
- Aurora's stage 1 copies stage 2 to its own base (run_base on T8140). Would you rather the T6050 stage 1 do the same, as T8140 does, instead of stage 2 forwarding from the retired vectors?
- #65 (the N1 hand-off) applies cleanly on top of this series and is meant to be merged after it.
