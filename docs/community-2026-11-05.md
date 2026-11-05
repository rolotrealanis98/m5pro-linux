# Community feedback, 2026-11-05

Posted: omacom/linux-aurora #293 (comment), aurora-silicon/linux discussion #142 (overview + 4 reports),
betizzel/omarchy-m5 issue #1, Sowyu/m5-azahi issue #6. Nothing to Asahi.

## edimoldovan (J714c, 14-inch M5 Max, T6050) reproduced the SMP fix the same day
https://github.com/omacom/linux-aurora/issues/293#issuecomment-6662971451

- 27.3 beta 1 on the m1n1-hosting volume (in place, Full Security, then `bputil -nkcas` + `kmutil configure-boot`
  from its paired recovery): `firmware-version` = `mBoot-20457.60.65.0.1`, 17/17 secondaries, `18 CPUs`.
- Independent confirmation of the raw-image size cliff: upstream m1n1 7cde7d1a (0x4D0000) fails with "Custom kernel
  failed to boot" on the new firmware; 7cde7d1a + our patches 0001-0014 (0x400000) boots. (For us plain 0x4D0000 had
  booted earlier; treat the cliff as <= 0x4D0000 on the new mBoot.)
- Omacom m1n1 `160b644c` (t6050-aurora, 0x410000) also starts 17/17 and, unlike our build (patch 0005 skips the gen-4
  SPMI USB-PD setup on T6050), powers the left-rear port. ACTION: look at adopting that PD setup for the USB rounds.
- T6050 DT MPIDRs for clusters 1/2 were wrong in the Aurora DT (cluster 2 has Aff2 = 1: 0x10200-0x10205). Ours are
  right (cpufreq REPORT table; m1n1 would refuse otherwise).
- cpufreq: cluster 1 (M) voltage-states23-sram 1344-4380 MHz 15 states at 0x211e20000, cluster 2 (P)
  voltage-states5-sram 1308-4608 MHz 20 states at 0x212e20000, three apple-cpufreq policies on schedutil, boost to
  4380/4380/4608 MHz. This is exactly our cpufreq agent's design (contrib/pending/cpufreq), now hardware-validated by
  a second machine. Our stage-1 test on Sunday can go straight to schedutil.
- Omarchy userspace: needs `CONFIG_SWAP` + `CONFIG_ZRAM` (zstd) or zram-generator waits 90 s; needs
  `CONFIG_SECURITY_LANDLOCK` + `LSM` incl. landlock or pacman 7 fails. Ours: SWAP, LANDLOCK, LSM OK; ZRAM MISSING ->
  ACTION: add CONFIG_ZRAM=y (+ZRAM_BACKEND_ZSTD) to the next kernel.
- Mesa: mesa-aurora 20261031 adds llvmpipe; Hyprland 0.57.1 renders on llvmpipe across 18 cores (graphical.target
  in 7.9 s). Matches contrib/pending/gpu/userspace.
- USB: a USB-C Ethernet adapter (cdc_ncm) works on his left-rear port; left-front works if plugged before boot (his
  kernel/m1n1 combination). Consistent with our USB plan's "plugged at boot" case.
- GPU: asahi probe fails at MMU init (-22), PMP not started, `cs` power domain off. Crash-log buffers for the new
  firmware: edimoldovan/linux-aurora edc3ec0480a4; findings in edimoldovan/kernel 1546f2a, 6dff3df. Input for a
  future GPU round; our no-go stands.
- He boots tethered only; our untethered recipe (patches 0013-0015 + chainload) is the next thing he needs.

## joshuaswarren's agent: read-only PMP window dump request
https://github.com/omacom/linux-aurora/issues/293#issuecomment-6658776963
- Dump `/arm-io/pmp0` (J716c: arm-io-relative 0x84E00000, size 0x88000 -> 0x284E00000; use our ADT's value) over
  the proxy twice: (1) right after the stub hands off to m1n1, no boot steps; (2) after a full tethered boot. Diff =
  evidence for/against mBoot starting the PMP. Reads may fault if the block is gated (ADT gates 27/28): use fault
  handling; a fault is an answer. ACTION: add to Sunday R1 (tethered session), m1n1 proxyclient `memdump`-style
  read with exception handling, publish redacted hexdumps + diff.

## betizzel (omarchy-m5): "no way!! Nice. I need to update my mac then" (issue #1 open, no reply yet)
## Sowyu issue #6: no reply yet
