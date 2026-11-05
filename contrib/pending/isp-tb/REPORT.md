Camera (ISP) and Thunderbolt/USB4 on the M5 Pro J716s (T6050): design report
(2026-11-04, agent output; REPORT.md was refused by the tool, so this is REPORT.txt; the same text is in the
agent's final message). Design/research only: nothing was run on the M5. ADT: adt-runtime-j716s.bin; only
hardware-description properties quoted (tools/adtprops.py withholds uuid, thunderbolt-drom, calibration, serials).

VERDICT
- Camera: not feasible yet; no code beyond a disabled DT description (patch 0001).
  The T6050 ADT marks the ISP exclave-assigned: exclave services com.apple.service.ISPEngine and
  ISPEngine_EDK, plus isp-exclave-proxy and isp-exclave-s-proxy nodes. The PMGR table lists ISP_CPU, ISP_FE,
  DPRX, ISP_SECURE, ISP_BE and ISP_CLR as no_ps, so the AP has no power-state register for them. The block is
  aurora-silicon's T6040 (M4 Pro/Max) ISP: same MMIO, DART addresses and stream remap. aurora streams from it on
  T6040 with iBoot-resident firmware, but on T6040 the sub-domains had (or were guessed to have) AP registers.
  The privacy-indicator brightness is exclave-owned (EXBrightPILCore). The next step is research (I2/I3), not
  bring-up.
- Thunderbolt: feasible, but only by adopting aurora-silicon/linux branch j716c/thunderbolt (2026-11-04;
  J716c = 16-inch M5 Max, same T6050 IO map). The branch has:
  - the T6050 combo PHY with CIO mode;
  - the CIO-reconfig reset;
  - T6050 routers and NHI in thunderbolt/apple.c;
  - DART init from DT;
  - the PCIe-C tunnel;
  - a J716c right-port DT whose every address and IRQ matches our ADT.

  Plan: import it, build a separate DTB that describes the RIGHT port (ATC2) only, and never describe ATC0. No
  enumeration-only patch is shipped: the minimum is that import (PD-driven, with SError and SoC-watchdog failure
  modes), so it is not low-risk.
- Tether hazard: the MagSafe-side port is left-back = port 1 = hpm0/atc-phy0/acio0/usb-drd0/apciec0, and it
  carries the CDC-EEM tether through the TB cable and dock. If its PHY entered CIO mode or its router ran, the
  dock/Studio would see a USB4/TB host router instead of a USB device. The USB2 gadget path would drop (it becomes
  XDomain host-to-host), and SSH and the tether would be lost. Every TB DTB must have no hpm0, atcphy0, acio0 or
  apciec0 node and no usb4-0-* alias.

PART A: CAMERA / ISP
ADT (verified):
- /arm-io/isp0:
  - compatible isp,isp-generic-ex + isp,s5l8960x;
  - reg 0x580000000+0x3ff0000, 0x280900000+0x3f4, 0x280920000+0x4000;
  - IRQ 513 514 515 516 526;
  - power/clock gates ISP_SYS_V (620, virtual) + ISPSENS0 (134);
  - exclave-assigned, ISPEngine / ISPEngine_EDK;
  - pre-loaded=1, not running (iBoot loaded the firmware: __TEXT 0xc1c000 B at phys 0x100_0109_4000, __DATA
    0x13d0000 B at 0x100_0269_c000);
  - sensor-type 118, cam-connections-scheme 16;
  - hooks to ANE, PMP clock/bandwidth and MCC.
- /arm-io/dart-isp0:
  - t8110 with instances 0x5828c0000/0x5828e0000/0x582900000 (+0xc000), IRQ 531;
  - sid 0 (firmware) and 12 (MPM);
  - exclave-sid 4,5,8,9 (epipe0/1, piodma0/1);
  - remap 1,6,7,10,11; DAPF; manual-availability.
- isp-exclave-s-proxy: reg 0x5c1800000+0x480000, 0x5c28ac000, 0x5c2780000.
- PMGR: ISP_SYS (pmgr0 +0x3a0) and ISPSENS0 (pmgr1 +0x100) are AP-visible; the six sub-domains are no_ps.
  Measured handover state: isp_sys 0x300 (off).
- /exbrightpil: exclave EXBrightPILCore(_EDK). /arm-io/dynamic-pil: PIL calibration.
- /product/camera: capabilities only; no sensor node.

Privacy indicator:
- Brightness is set by an exclave. The MacBook Pro has a hardware LED in the notch (Daring Fireball, 2026-03-16).
- Unknown: whether it is hard-wired to sensor power on M5, and whether Linux leaves it lit (TEST-PLAN I0).
- aurora's T8140 (MacBook Neo) driver kicks an ISP capture watchdog that the firmware ties to the camera-in-use
  indicator ("a privacy interlock") unconditionally. Rule: no camera driver here may defeat an indicator
  interlock.

Comparison:
- In tree: T6020 apple,t6020-isp at 0x384000000 (7 ps_isp_* domains); T6030 at 0x2c8000000 (8 domains).
- apple-isp hw tables stop at t6031, and its firmware enum stops at 14.7.
- CONFIG_VIDEO_APPLE_ISP=m, but no modules are installed, so it is inert.
- m1n1 isp.c on T6050:
  - It prints "isp: Unsupported SoC" (boot logs) after pmgr_adt_power_enable(isp0), without powering off.
    Harmless per the measured state.
  - It needs a T6050 case before ISP work.
  - kboot reserves ISP firmware only with an "isp" alias, and none exists.
- aurora apple,t6041-isp (316136216030, 2026-10-22):
  - H17 firmware interface, resident firmware with no reset;
  - firmware MMIO from the ADT DAPF ranges;
  - 32 MiB firmware memory with a host-backed tail;
  - IMX958 sensor, setfile isp_2224_01XX.dat;
  - 1080p NV12 on 26.6.x firmware, with intermittent stalls.
  - On T6040 only CPU/FE had ADT power-state addresses ("With only CPU and FE on, the firmware takes an SError
    while it loads its tunables").

Plan:
- I0: notch LED and genpd ISP state under today's Linux.
- I1: patch 0001, disabled DT only.
- I2: m1n1 proxy, owner approval. Can the AP power ISP_FE/CPU? Candidate page 0x280920000. Read the ISP ASC
  version at coproc+0x1800000. A fault means exclave ownership is real.
- I3: m1n1 hypervisor trace (m5-hv) of a macOS camera start. Does it use the mailbox directly or the ISPEngine
  exclave?
- I4 (only if the AP owns it): port aurora's T6040 profile as apple,t6050-isp. Constraints:
  - ABI check against the 27.3b1 firmware;
  - an m1n1 T6050 heap case;
  - never configure DART streams 4/5/8/9;
  - pd_ignore_unused;
  - domains stay on while firmware is resident;
  - on a crash, stop the coprocessor rather than toggling PMGR (platform report: PMGR writes to auto-gated
    domains hang the bus).

PART B: THUNDERBOLT / USB4
Port map (ADT, verified):
- port 1, left-back, MagSafe side, TETHER:
  - PD: hpm0 nub-spmi-a0 SID 0xc, IRQ 11/17/19.
  - atc-phy0 (atc-phy,t6050 + atc-phy,t6040, 44 windows): USB2 0x2a2a90000, 0x2a2800000, core 0x2a3000000.
  - PHY firmware CPU acio-phy-cpu0: 0x2a3148000, IRQ 841-844, rtbuddy, pre-loaded + running.
  - router acio0 (acio,v2, vid-did 0x201205ac, spec 0x40): NHI 0x2a1f00000+1M, rc 0x2a1ac0000, IRQ 1579-1602 +
    1608; router CPU mailbox 0x2a1108000, IRQ 837-840.
  - dart-acio0: 0x2a1a80000, IRQ 1606, 28 SIDs, no exclave SIDs.
  - apciec0: ECAM 0x1c50000000, IRQ 1405, 1408-1412; dart-apciec0 0x2a4000000, IRQ 1406, SIDs 253-255.
  - power gates ATC0_CIO / _CIO_PCIE / _CIO_USB / _CIO_AUSS, ATC0_PCIE + AUSB0_AONPCIE_V; clock CIO0_RECONFIG_V.
  - dpin0: 0x2a1e50000, IRQ 1603.
- port 2, left-front:
  - hpm1 a0 SID 0xa, IRQ 37/43/45;
  - PHY 0x2aaa90000/0x2ab000000, PHY CPU 0x2ab148000 IRQ 851-854;
  - acio1 0x2a9f00000 IRQ 1611-1634 + 1640, mailbox 0x2a9108000 IRQ 847-850;
  - DART 0x2a9a80000 IRQ 1638;
  - apciec1 0x1c60000000 IRQ 1437, 1440-1444; DART 0x2ac000000 IRQ 1438.
- port 3, right:
  - hpm2 on nub-spmi-a1 SID 0xc, IRQ 11/17/19;
  - PHY 0x382a90000/0x383000000, PHY CPU 0x383148000 IRQ 861-864;
  - acio2 0x381f00000 IRQ 1643-1666 + 1672, mailbox 0x381108000 IRQ 857-860;
  - DART 0x381a80000 IRQ 1670;
  - apciec2 0x1c70000000 IRQ 1469, 1472-1476; DART 0x384000000 IRQ 1470;
  - dpin0 0x381e50000 IRQ 1667.
- atc3: the HDMI path (port-type 6, Parade DP855 on spi4); PHY + PHY CPU 0x38b148000, no router.

Other ADT facts:
- Retimers uatcrt0..2 (atcrt) sit on AP i2c6 at 0x18/0x19/0x1a.
- MagSafe controller: hpm5, port-type 0x11, a0 SID 0x8.
- Handover PMGR state: all ATCn_CIO* and ATCn_PCIE 0x300 (off), COMMON/PHYMXWRAP on. The routers are cold at
  Linux start.
- New compared with M1-M3:
  - a firmware CPU per PHY;
  - CIO4PLL, AUS40CMN, UC_REGS_CIO and LN*_RX_TOP_CIO tunables (TB5 class);
  - UHBR20 DP tables.
- tunable_USB2PHY_HOST = offset 0x8, mask/value 0x7000. This confirms the USB report's host bits.
- Correction for the USB report: its table guesses hpm2 at SID 0x8. The ADT puts it on nub-spmi-a1 at 0xc, and
  0x8 on a0 is hpm5 (MagSafe). gen-usb-dt.py reads the ADT, so its output is fine; only the table text is wrong.

Comparison and public status:
- In tree (asahi-wip-7.2): thunderbolt/apple.c (apple,t8103-usb4-acio/-nhi) and phy/apple/atc.c (t8103/t8122)
  cover M1-M3. The T6030 DT has usb4 nodes and a typec graph. pcie-apple has no tunnel support. Nothing matches
  T6050.
- Upstream: Sven Peter's 19-patch series (2026-08-30) for M1/M2/M3 covers XDomain and USB3 tunnels only: no
  PCIe or DP, no suspend, no M4.
- Asahi 7.2 report (2026-08-26): "USB 3.0 and Thunderbolt support to all M3 series devices"; M4/M5 only have
  NVMe and PCIe enumeration.
- aurora j716c/thunderbolt (read-only clone in ref/aurora-linux):
  - 81bd9173: combo PHY.
  - 0abf120f: CIO mode.
  - 770b6b71: CIO reconfig at 0x280620000+0x60; an early wrapper access SErrors.
  - ff3f967f: routers. LSTX handover, DP tunnels off.
  - a0d19383: DART init.
  - ffb98ff6: PHY firmware data restore. Without it, every second connection fails until reboot.
  - 01e3b802: USB3 tunnel.
  - f777354e/2ac11995: PCIe-C.
  - 0e5cdd96/edfb6147: J716c right-port DT.
- The commit texts describe observed hardware behaviour (inferred: tested on J716c).
- aurora's J716c DTS embeds its board's tunables and host DROM. Do not copy our DROM (router UUID) into tracked
  files; m1n1's dt_copy_usb4_drom derives it once T6050 is supported.

Safe enablement:
- PCIe tunnelling: later, ATC2 only.
- DP alt mode/tunnels: no (needs DCP).
- USB4_NET to a free Studio TB port is the best future second access path. It is not a prerequisite.
- First enumeration patch (design only):
  1. Import aurora 81bd9173..2ac11995 onto 236788cd2.
  2. Use the USB agent's polled SN201202x for hpm2 (nub-spmi-a1, 0xc).
  3. Add dt/t6050-j716s-tb.dts, a separate DTB that includes j716s. It describes only atcphy2, dwc3_2 DRD, hpm2,
     cio_reconfig0, acio2 + DART + NHI, apciec2 + DART and AOP pin 81 LSTX, with tunables from our ADT (never
     the DROM).
  4. Use the omarchy-tb-stage.config fragment.
  - Expected: nothing powers at boot. Risk: ordering violations give an async SError or a SoC watchdog reset.
- Ports: ATC0 tether (untouched), ATC1 USB agent host, ATC2 TB. The right-port gadget disappears with the TB
  DTB; 10.55.0.2 stays.

DELIVERABLES (~/Work/agents/isp-tb/)
- patches/omarchy-m5/0001-dt-t6050-describe-the-camera-ISP-disabled.patch: ISP + 3 DARTs in dt/t6050.dtsi, all
  disabled, no alias. git apply --check is clean on omarchy-m5 j716s 2c87598.
- patches/config/omarchy-tb-stage.config: stage-gated (TYPEC, USB4, USB4_APPLE_SOC, RESET_APPLE_CIO,
  APPLE_TUNABLE, PHY_APPLE_ATC, PCIE_APPLE, USB4_NET =y; ISP off). It merges to =y and is inert on the current
  tree.
- build/: t6050-j716s.dtb e51ed544...7216, t6050-j714s.dtb c13a3669...4280, baseline/ j716s d4364f78...9d9a,
  SHA256SUMS.
- tools/: identifier-filtering ADT readers. ref/aurora-linux: blob-less clone. kmake.sh: wt-isptb build wrapper.
- TEST-PLAN.md.

Compile checks (wt-isptb = 236788cd2 + omarchy dt/ overlay):
- W=1 j716s/j714s DTBs: no warnings.
- Decompiled diff vs baseline = 4 disabled nodes + phandle renumbering; "okay" count still 8.
- With the TB fragment: thunderbolt/apple.o and reset-apple-cio.o build W=1 clean.

Conflicts: 0001 touches only dt/t6050.dtsi. The only other pending t6050.dtsi patch is DCP omarchy 0001 (an
include at the end of the file). Both apply in either order (tested). A future TB DTB edits build-kernel.sh and
the Makefile lists, as usb/dcp/audio/platform/integration do; rebase it on top of them.

VERIFIED / INFERRED / UNKNOWN
- Verified:
  - ISP: exclave-assigned with ISPEngine; exclave SIDs 4/5/8/9; sub-domains no_ps; MMIO/DART equal to T6040.
  - m1n1 "Unsupported SoC" and no ISP/USB4 aliases.
  - Port map, PD SIDs, locations; tether = port 1.
  - ATC2 router/PHY/PCIe-C equal to aurora's J716c.
  - CIO off at handover; PHY firmware CPUs exist.
  - The builds.
- Inferred:
  - ISP mailbox windows/IRQ (T6040 layout).
  - EXBrightPILCore drives the indicator.
  - aurora TB tested on hardware.
  - J716s ATC2 behaves like J716c.
  - A TB-mode ATC0 would break the tether.
  - J716s sensor = IMX958.
- Unknown:
  - whether the AP can power the ISP sub-blocks;
  - the 27.3b1 ISP firmware ABI;
  - whether the LED is hard-wired;
  - whether the uatcrt retimers need AP programming for TB5;
  - LSTX and CIO-reconfig offsets on J716s;
  - hpm2 behaviour on USB4 entry;
  - suspend with routers.

URLS
- https://asahilinux.org/2026/08/progress-report-7-2/ (2026-08-26)
- https://asahilinux.org/2026/09/m2-episode-1/ (2026-09-06)
- https://lwn.net/Articles/1059339/ (2026-02-18)
- https://hwbusters.com/news/thunderbolt-on-apple-silicon-hits-the-linux-kernel-and-every-port-hides-a-cortex-m3/ (2026-08-31)
- https://phoronix.com/news/Linux-USB4-Apple-Silicon (403 to the fetcher; title only)
- https://lkml.iu.edu/hypermail/linux/kernel/2512.1/05858.html (Type-C PHY v3, Dec 2025)
- https://lists.infradead.org/pipermail/linux-arm-kernel/2025-September/1062406.html (TIPD changes, Sep 2025)
- https://lkml.iu.edu/2605.2/10855.html (non-PCIe NHI prepwork v5, 2026-05-21)
- https://github.com/aurora-silicon/linux (j716c/thunderbolt, j716c/t6050-combo-phy, aurora/bits/240-isp, read 2026-11-04)
- https://daringfireball.net/2026/03/apple_enclaves_neo_camera_indicator (2026-03-16)
- https://9to5mac.com/2024/06/03/m4-ipad-pro-security-feature-apple-hasnt-told-anyone-about/ (2024-06-03)
- https://www.caldigit.com/2026/03/03/ (M5 Pro/Max MBP: three TB5 ports)
