# ATC0 (left-back, MagSafe side) as a host port

Status: built offline 2026-11-16, not booted. Test request: `/Volumes/m5pro/bench/requests/atc0-host-1.md`.

Boot file: `atc0-host-1-test-20261116-51ed8e3e.bin` (sha256 `51ed8e3ef5ae237f677c7093e2e74cff684e5a1a8d608400a8404f60b086a85f`),
kernel `7.3.0-g82931daf23b6`, DTB `t6050-j716s-atc0-host.dtb`, loader `aura-j716s-fix3-nohostwait.bin`, initramfs
fsck v3; packed like `next6-aura-test-20261116-1dba7c28.bin`.

## Branch

`j716s-atc0-host` on `rolotrealanis98/linux`, based on `j716s-next6` (`eff3b30705ec`), two commits, `88f258fef640` and `82931daf23b6`
(they also apply cleanly to next4b `1052a5f7849e`):

1. `usb: typec: tipd: Renegotiate the J716s's inherited boot-port connection`: adds `apple,j716s` (key `J716`
   reversed, best effort) to the boards whose inherited boot-port USB2 connection is renegotiated before the host
   controllers start. Only a port controller with `apple,reset-inherited-usb2-connection` is affected (hpm0 in the
   variant DT; nothing in the default DT).
2. `arm64: dts: apple: j716s: Add a variant with the left-back port (ATC0) as a host`: new
   `t6050-j716s-atc0-host.dts` (`#define T6050_J716S_ATC0_HOST` + `#include "t6050-j716s.dts"`) and
   `t6050-j716s-atc0-host.dtsi` (combo PHY, usb-drd0 as Apple DWC3 OTG/host, DARTs, power states, hpm0 + connector,
   acio0 router + NHI, apciec0 tunnel). The tether block in `t6050-j716s.dts` is under `#ifndef`; the default
   `t6050-j716s.dtb` is byte-identical to next6's (also J716c and J714s DTBs unchanged).

The earlier local branch from 2026-11-07 (PHY opt-in `apple,boot-link-released` + a standalone DTS) is kept as
`j716s-atc0-host-20261107` (not pushed). Its PHY patch is no longer needed: next6's combo PHY driver accepts port 0
(`4c8f9d303941`); its DTS predates next6's USB4 support.

## Where the description comes from

- J716sAP ADT (`adt-runtime-j716s.bin`), compared node by node: `atc-phy0`, `acio-phy-cpu0`, `usb-drd0`, `dart-usb0`,
  `acio0`, `acio-cpu0`, `dart-acio0`, `apciec0`, `dart-apciec0` sit at ATC1's address less 0x8000000. Every tunable
  list equals ATC1's except the PHY's `tunable_ATC0AXI2AF` and `tunable_AUS40CMN_SHM` (loader-copied). RX_TOP_CIO = 0
  on all three ports.
- Interrupts: PHY mailbox 841-844, usb-drd0 1419, dart-usb0 1423, acio-cpu0 837-840, dart-acio0 1606, NHI TX
  1579-1590 / RX 1591-1602 / parity 1608, apciec0 1405, dart-apciec0 1406, MSIs AIC 1952 (vectors 128-159).
- LSTX: ADT `acio0 gpio-lstx` = AOP pin 77; router reset `cio_reconfig0 0`; PCI domain 1 (ADT `domain-id`).
- Host DROM: the ADT's `acio0 thunderbolt-drom` (UID zero; the loader replaces it).
- hpm0: `nub-spmi-a0` reg 0x0c, `port-location "left-back"`.
- The router/tunnel part was generated from `t6050-j714s-left-usb4.dtsi` (ATC1) by asserted token edits, then
  diffed token by token against the J716c's ATC0 (`t6050-j716c-left-usb4.dtsi`, derived independently): identical
  apart from names, the AOP reserved-range placement and the DROM UID.
- ATC0_COMMON's ADT parent is FAB3_SOC (as ATC1_COMMON's); this board's DT describes ATC1_COMMON without a parent and
  keeps `ps_fab3_soc` disabled, so the variant drops ATC0_COMMON's parent too.

## Loader

No loader change; the boot file uses the current loader, `aura-j716s-fix3-nohostwait.bin` (aura `16ab9c11`).

- Aura's `kboot_atc.c t6050_setup_atc()` skips port 0 ("carries aura's debug link") and never clears it, so the
  variant DT carries ATC0's PHY tunables itself: the fourteen lists aura copies for ATC1/ATC2, generated from the
  ADT's `atc-phy0` / `usb-drd0` with aura's table (bank bases asserted against the DT regs, offsets raw as the
  ADT gives them; same encoding as m1n1 0021). An m1n1 that fills port 0 replaces them with the same lists.
- Before the hand-off aura brings ATC0's USB2 up as a gadget (`t6050_usb_for_os()`: PIPE parked on the dummy
  producer 0x42, USB2 PHY in device mode with VBUS forced, hpm0's USB2 pair routed to the AP) and stops the
  controller before vectoring. The kernel's combo PHY then resets the port as a host; hpm0 renegotiates the
  inherited connection (J716c precedent). This hand-over is the main untested step.
- A loader-side alternative, if ever wanted: let `t6050_setup_atc()` fill port 0 when the DT describes it with a
  `chosen` opt-in; not needed for this test.

## What is lost

The Linux CDC-EEM tether: T6050's dwc3-apple is host-only, so no UDC exists. The initramfs `usb-gadget-net` waits
10 s for a UDC and gives up. Recovery: Wi-Fi/Tailscale ssh, the self-revert (`m5.selftest=1` pings 1.1.1.1), stage 1's
A/B fallback (watchdog.open_timeout=300 for a boot that never reaches userspace).
