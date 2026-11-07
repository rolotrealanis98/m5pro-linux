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
  4380/4380/4608 MHz. This is exactly our cpufreq agent's design (contrib/validated/legacy-7.2/cpufreq), now hardware-validated by
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

## edimoldovan, second report (2026-11-05 23:48 UTC): J714c desktop-ready items
https://github.com/omacom/linux-aurora/issues/293#issuecomment-6672583409 (tree: edimoldovan/linux-aurora; status table
edimoldovan/kernel OMARCHY-LOGIN.md). All tested in a full Omarchy login over the proxy.
- Keyboard backlight: fpwm0 at 0x505040000 + pwm-leds kbd_backlight, Ctrl+F1/F2 work. = our platform patch design.
- SMC: "RTKit on T6050 returned before the SMC's AP power ACK, so macsmc failed with 'Failed to start SMC endpoint';
  now waits up to 200 ms for the ACK; SMC, MTP and ANS all ACK within 2 ms" (0fbd859e287d, 4602eba4b9d2). Uses our
  t6050-smc.dtsi with the full nub-spmi0 window. Context: his tree had skipped the AP-power ACK wait on T6050 entirely; ours (asahi-wip-7.2) always
  waits, and our SMC core works, so this is NOT the cause of our macsmc-power probe hang. What matters: his
  macsmc-battery/ac WORK on J714c (68d2fe0a8e7f, 0bc84cc4a6b2) with our 0011 work-item fix. ACTION: diff his
  macsmc-power.c / macsmc.c / DT against ours before bisecting (cached in ~/Work/agents/community/edimoldovan/).
- Lid locks the session: framebuffer node `apple,internal-panel` -> simpledrm reports an eDP connector (9dee12b1266c);
  Omarchy only locks on internal connectors.
- Sleep (s2idle) WORKS on J714c: lid close locks+suspends, lid open wakes via the SMC interrupt (17b3cc9ca3a6);
  xhci-plat honours `wakeup-source` so the USB 2.0 PHY is not re-initialised on resume and the USB network survives
  (9f8535b38fcb). Our platform plan had s2idle last with a PMGR-sleep hang risk (patch 0042): he did not report
  that hang; compare trees before our test.
- Full panel incl. notch: m1n1 `chosen.asahi,show-notch=1` (3024x1964 on J714c); Omarchy's bar avoids the cutout
  given the eDP connector.
- Battery/charger: macsmc-battery (bq40z651, 3 cells) + macsmc-ac; proxy cable alone counts as a 2.4 W source.
- Sensors (c5b0600d19a4): hwmon-common/fan-dual/laptop with F0md/F1md (= our SMC fix); both fans, storage, battery,
  charger, Wi-Fi temps; under load fans 0 -> 4500/4900 rpm, system power 52 -> 79-93 W. No CPU die temperature key
  found (matches our platform agent's uncertainty about Tp*/Tm*/Tg*).
- Firewall: Omarchy's ufw needs netfilter/nf_tables/conntrack/xtables in the config (00662e9fd517). ACTION: add.
- Boot from disk (prepared, not registered): m1n1 `boot=` keeps a 15 s proxy window in stage 1 before loading
  kernel/DT/initramfs from the ESP (edimoldovan/m1n1 53653157). ACTION: fold a proxy window into our A/B stage-1
  design; it removes the "move boot.bin aside to reach the proxy" caveat.
- Test loop: `initcall_blacklist=__asahi_init` keeps the asahi GPU driver off so Mesa does not stall on renderD128.
- Not yet on his side: GPU, display brightness, CPU die temperature.

## TripleU613 (J714s, 14-inch M5 Pro, still single core on 26.6.2 firmware)
https://github.com/TripleU613/Omarchy-M5-Pro ; comments 2026-11-06 00:26 and 01:31 UTC.
- Keyboard works natively after DART/DAPF diagnostics and a nub-gpio pin-20 data bit; trackpad fails exactly like
  ours did: PM2 firmware-managed reset -> `Failed to attach to AFE (-6)` / `No HINT_L`. Host AFE reset is their next
  test (our trackpad patch). Their MTP firmware is 5340.61.4 (older macOS) vs 6320.86.1 on our 27.3 stub.
- J714s ADT has 15 cores (their DT listed 18). Has not applied the 27.3 beta 1 stub fix yet.
- Diffs of the edimoldovan commits above are saved locally at ~/Work/agents/community/edimoldovan/ (GPL kernel code,
  not imported yet).
