# USB4/Thunderbolt on `j716s-next2` (2026-11-15): both routers described, built, not booted

Branch `thunderbolt` (worktree `/Volumes/m5pro/wt/tb`) = `j716s-next2` + 3 commits:

1. `907155e828a6` cherry-pick of upstream #2018 `64d473f5321d` (T6050 ATC usb-aon domains always-on). On boards
   without the display crossbar (the J716s) a port's usb-aon went off while the port was idle, and on the J714s the
   PHY's next CIO start then failed with -110. The first plug of a USB4 device after boot is exactly that case here.
2. `6b65cb580b25` left-front router: `#include "t6050-j714s-left-usb4.dtsi"` in `t6050-j716s.dts`, the ATC1 PHY CIO
   RX_TOP override, and `T6050_J716S` added to the `t6050-peripherals.dtsi` guard that drops the inventory
   `apciec1_dart` (dtc: duplicate label otherwise; upstream did the same for the J714s in `fbfb50c36408`).
3. `49c9b5ba0e78` `j716s.config`: `USB4=m`, `USB4_APPLE_SOC=m` (as asahi.config), `USB4_NET=m` (new).

## What the J716s needs, from the ADT and the code

- **ADT vs tree** (`/Volumes/m5pro/bench/thunderbolt/ioreg-vs-dts.py` against
  `m5pro-linux-re/captures/studio-artifacts/macos-27.3/m5-ioreg-dt.txt`, which carries the ADT's raw properties):
  - ATC2 (right): router rc/pcie-adapter/router-ap-fw, NHI, router DART, tunnel DART, apciec debug/rc/fabric/port and
    the PHY CIO RX_TOP tunables are identical to `t6050-max-atc2-router.dtsi`; the host DROM is identical (UID 2).
  - ATC1 (left-front): addresses, interrupts (router 1611..1640, mailbox 847..850, DARTs 1638/1438, apciec 1437),
    LSTX pin 79 and every router/NHI/DART/tunnel tunable equal `t6050-j714s-left-usb4.dtsi`; DROM identical (UID 1).
    **One difference:** atc-phy1 `tunable_LN0/LN1_RX_TOP_CIO_DFLT` = `<0x35c 0xe00 0x0>` on the J716s, `0x200` on the
    J714s. The older `logs/adt-vs-j716c-tunables.txt` said IDENTICAL for these; `findings/tb/tb-j716s/adt/cmp716c.txt`
    and the ioreg agree on the difference.
  - ATC0 (left-back, tether) has a router too (acio0, LSTX pin 77); not described, by policy.
- **Loader:** nothing from the loader is required for the routers. Every router, NHI, DART and tunnel tunable and the
  host DROMs are in the tree with valid UID CRCs (0xc8 for UID 1, 0xfd for UID 2). Aura's `dt_set_acio_tunables()`
  only acts through `usb4-N-*` / `usb4_N_*` aliases, which no T6050 laptop tree has (it prints "Unable to find
  alias" and carries on); its `t6050_setup_atc()` fills the per-port PHY USB tunables, which the old loader gives
  too (USB3 works on both ports). So the aura stage 2 is not needed for USB4; the test uses the loader that booted
  `j716s-next2`.
- **Driver/config:** `apple,t6050-usb4-acio` / `-nhi` are in `drivers/thunderbolt/apple.c` (`thunderbolt_apple`),
  PCIe tunnels through `apple,t6050-pciec` in `pcie-apple.c` (cold init by the kernel), XDomain with ACIO v2 is
  handled upstream (Aurora's #1244/#1319/#1338 thunderbolt-net fixes). `HOTPLUG_PCI_PCIE` is left off (only
  hot-plug bridges behind a tunnel, i.e. daisy chains, need pciehp).

## Not done / open

- DisplayPort over the tunnels: needs `dcpext0`/`dcpext1` routes to the ports (upstream did the J714s's right port in
  `4c6a7b451f34`) and the DP-tunnel commits after `07ade53fd116`; `display.external` first.
- The retimers (uatcrt0..2) have no driver anywhere; TB5 (80 Gb/s) unverified on Linux.
- PCIe tunnels on T6050 need no new kernel work as far as the code shows: `apple,t6050-pciec` is upstream
  (`b1ffa4722f3d`, cold init by the kernel), the right tunnel's tunables equal the J716s ADT, the software connection
  manager runs at security level `user` (no ACPI), so a device router must be authorized
  (`echo 1 > /sys/bus/thunderbolt/devices/N-1/authorized`) before the PCIe tunnel is made. Unproven on hardware.
- Both PD controllers now name a router (`port@3`) and wait for `thunderbolt_apple` (a module) at boot; a router
  that binds after the port gave up makes tipd re-apply the cable state, which for an unchanged USB mode is a no-op
  in `combo_mux`, so a USB hub on the left-front port should not re-enumerate.

## Test

`/Volumes/m5pro/bench/requests/thunderbolt-1.md`: boot file `tb-apollo-20261115-a5dae327.bin` (today's loader),
modules `kbuild-tb/modules-7.3.0-g49c9b5ba0e78.tar.zst`, script `/Volumes/m5pro/bench/thunderbolt/tb-check.sh`.
Target: the right port's router trains a TB3 link to a UA Apollo x4 (connected at boot with a TB5 cable), the device
router enumerates and is authorized, the PCIe tunnel comes up and the Apollo's functions appear (no audio driver).

## Hardware for later tests

- A TB4/USB4 40 Gb/s or TB5 cable between a MacBook USB-C port and the Studio's free receptacle 6 (Thunderbolt
  Bridge member `en7`, a private link address): Thunderbolt networking (`thunderbolt_net`, already built).
- A USB4 device (not TB3), e.g. the ACASIS TBU405Pro NVMe enclosure from Studio receptacle 1, or the CalDigit TS5
  Plus from receptacle 4: USB4 link (gen 4), NVMe over the PCIe tunnel, USB3 tunnel.
- The left-front router: any of the above on the left-front port once the Anker hub can move.
- A DP display behind a dock: only after `display.external` (dcpext routes).

## thunderbolt-1 result (2026-11-16, booted, today's loader)

- Right port: TB3 link to the UA Apollo x4 (`0-1`, generation 3, 2 x 20 Gb/s bonded, TMU HiFi). The script
  authorized it, the PCIe tunnel came up on PCI domain 0003 (JHL6240 bridges, `1a00:0002`). The PHY's first CIO start
  (`CIO mode up`) worked with #2018's usb-aon always-on.
- Left-front: `2a9ac0000.acio` probed and bound; `set cable state: 0` (the Anker hub is USB only), so no domain. A
  router is powered only for a USB4/TB partner, by design. Its hub came up SuperSpeed Plus at the first start with
  #2018 in. The low-power branch dropped #2018 (`0878a4a50c52`) for USB2-only after a PHY stop/start; that path
  (a re-plug) has not run on this kernel yet.
- The three `w_speed_transport.c:398: Timeout for at_rt command response expired!!! register=8` lines come exactly
  between the kernel's `0:1: reading NVM authentication status of retimers` and `0:1: disabling sideband
  transactions`: the USB4 core's retimer scan, writing the sideband opcode register (USB4 SB register 8), which no
  retimer answers on this TB3 link. They also appear on the `j716s-next2` Apollo boots (`bench/apollo/results-1`).
  Harmless: the link, discovery and tunnel go on.
- 40 Gb/s: the Apollo link is already TB3's maximum (2 x 20 Gb/s bonded). Gen4 (80 Gb/s symmetric) is enabled in
  the T6050 driver data (`gen4_cable`, `gen4_link_recovery`; asymmetric and CL states off by design) and needs a TB5
  device (the CalDigit TS5 Plus on the Studio is one). Next request: `bench/requests/thunderbolt-2.md` (needs a
  person to move cables; no new kernel).

## thunderbolt-2 part A result (2026-11-16, booted, same kernel and loader)

The owner swapped the cables before the boot, so the Apollo was on the left-front port from boot (not a hot plug).

- Left-front router works: `2a9ac0000.acio` populated its PCIe tunnel, `2a9f00000.nhi` took the plug events,
  "PCIe-C: linked 1c60000000.pcie to 2a9f00000.nhi" and "PCIe-C populated after USB4 PCIe tunnel adapter enable".
  `0-1` = Apollo x4, generation 3, 2 x 20 Gb/s. It is `domain0` because domains are numbered in registration order
  and the right router had no partner on this boot. PCI domain 0002: JHL6240 bridges (`01:00.0`, `02:01.0`) and
  `1a00:0002` (`03:00.0`). So the J714s description with the J716s RX_TOP value carries a TB3 link and a PCIe tunnel
  on the J716s's left-front port.
- The Anker hub on the right port: `usb 2-1` SuperSpeed Plus Gen 2x1, `2-1.2` SuperSpeed, LAN and storage behind it,
  with #2018 in (first start of that port's PHY in USB mode on this boot).
- Type-C roles: port0 (left-front, Apollo) device-side `[device]`, port1 (right, hub) `[host]`.
- Results on the machine: `/root/tb-check-20261116-041222`. Part B (swap back: the PHY stop/start under #2018) is
  pending the owner.
- Ledger row `usb.thunderbolt` (for the orchestrator): both right and left-front routers bring up a TB3 link with a
  PCIe tunnel (booted on `thunderbolt` `49c9b5ba0e78`, today's loader); Gen4, USB4 (non-TB3) devices, DP tunnels,
  Thunderbolt networking and the left-back port (tether) untested.
