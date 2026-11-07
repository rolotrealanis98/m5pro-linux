# USB-C host mode on the M5 Pro (T6050, J716s) (agent report 2026-11-04; nothing run on the M5)

Goal (milestone 1a): USB 2.0 host on one Type-C port (Ethernet/Wi-Fi dongle, keyboard, storage) while the CDC-EEM tether
keeps working on the others. 1b adds the PD controller (tipd/SN201202x) for role switching and VBUS.

## Changes
1. New USB2-only PHY driver drivers/phy/apple/usb2.c (CONFIG_PHY_APPLE_USB2, compatible apple,t6050-usb2phy): drives only
   the USB2 block of the Type-C PHY (ADT atc-phyN reg[0]); .init = m1n1's usb_phy_bringup() sequence (proven on T6050 in
   device mode) plus the host bits USB2PHY_SIG[14:12] that phy-apple-atc sets on M1-M4; .exit = atcphy USB2 power-off;
   set_mode flips the host bits; initial mode from apple,default-mode. PIPE mux stays on m1n1's dummy PHY (no USB3/USB4/DP).
2. typec Makefile fix: tipd/ was only entered with CONFIG_TYPEC_TPS6598X (the I2C front end), so SN201202X=y never built /
   linked (confirmed with nm). Keyed on TYPEC_TPS6598X_CORE now.
3. SN201202x without SPMI interrupts: irq/select/sleep/wake optional; select polled (bounded 100 ms) like m1n1; 10 ms waits;
   tipd core polls events every 500 ms; also fixes a stale ret in the polled path and a W=1 warning.
4. Device tree: dt/t6050-usb-host.dtsi (three usb2phy nodes; the port chosen by T6050_USB_HOST_PORT, default 1 = left-front,
   becomes dr_mode otg + usb-role-switch + role-switch-default-mode host + maximum-speed high-speed + snps,usb2-lpm-disable);
   dt/t6050-j716s-usbhost.dts is a SEPARATE DTB; t6050-j716s.dtb stays byte-identical.
5. configs/omarchy-usb-host.config: all =y (no modules on the target): xHCI platform, the PHY, r8152/ax88179/cdc_ether/
   ncm/eem/rndis, UAS/usb-storage/HID, cfg80211/mac80211 + rtl8xxxu/mt7601u/mt76x2u (RFKILL=y needed), TYPEC + SN201202X.

## Port map
| | dwc3_0 | dwc3_1 | dwc3_2 |
|---|---|---|---|
| ADT | usb-drd0 port 1 | usb-drd1 port 2 | usb-drd2 port 3 |
| dwc3 core | 0x2a2280000, AIC 1419 | 0x2aa280000, AIC 1451 | 0x382280000, AIC 1483 |
| DART pair | 0x2a2f00000/0x2a2f80000, AIC 1423 | 0x2aaf00000/0x2aaf80000, AIC 1455 | 0x382f00000/0x382f80000, AIC 1487 |
| usb2phy (inferred: dwc3+0x810000) | 0x2a2a90000 | 0x2aaa90000 | 0x382a90000 |
| PD controller | hpm0 on nub-spmi-a0 | hpm1 on nub-spmi-a0 | hpm2 on nub-spmi-a1 |
| PD SPMI SID (guessed, M3 Max) | 0xc | 0xa | 0x8 |
| physical | left back (MagSafe side) | left front | right |
| today | gadget 10.55.0.2 | gadget, nothing | gadget |
| this series | gadget | HOST | gadget |
Side effect: with drd1 no longer a UDC the right port renumbers m5pro-2/10.55.2.2 -> m5pro-1/10.55.1.2; 10.55.0.2 unchanged.

## What the ADT must confirm (stage 0)
atc-phy{0,1,2} reg[0] == the usb2phy addresses; after m1n1 USBCTL=0x2, SIG=0x01c1000f, MISCTUNE=0x008c0813 there;
nub-spmi-a0/a1 gen (4 polled vs 1 with interrupts), reg[0], AIC; hpmN SIDs and interrupts; usb-drdN quirks.
Tools: scripts/usb-proxy-probe.py (m1n1 proxy, read-only unless --pd; all loops bounded) and scripts/gen-usb-dt.py
(ADT dump: --check, --dump, --pd generates the PD dtsi by bus gen).

## Risks
VBUS: only the PD controller firmware sources it; 1a never touches it; measure with an inline meter; if 0 V -> 1b.
Hot-plug: the PD controller resets the eUSB2 repeater on attach; only a PHY reset re-syncs (unbind/bind dwc3 as a stopgap).
Inferred usb2phy address (PHY driver prints registers at probe; zeros/0xffffffff/SError = wrong). Host bits proven only M1-M4.
LPM disabled for the same reason as the gadget.

## Verified / inferred / guessed
Verified (compile): patches apply; phy/apple, usb/typec, usb/dwc3, spmi compile W=1 clean; sn201202x links only with the
Makefile fix; usbhost DTB builds clean and differs from j716s.dtb only in model string, dwc3_1 and the phy nodes; fragment
merges to =y; dwc3 phy_init-before-soft-reset order and role-switch naming checked in source.
From the ADT via omarchy generators: dwc3/DART/IRQ, port numbers, nub-spmi0 gen 4. Inferred: usb2phy addresses, hpm placement.
Guessed: hpm SIDs, IRQ offsets, physical labels. Not done: full link, dtbs_check, boot.

## Later
USB3/replug-proof USB2: T6050 in phy-apple-atc, atc tunables (kboot_atc.c has no t6050 entry), pipehandler to USB3,
dwc3-apple glue driven by tipd, ATC power domains (disabled today). DP alt mode, USB4/TB5: nothing exists. Wi-Fi dongles need
/usr/lib/firmware blobs on the root (mk-esp-install.sh --firmware). AX88179 needs no firmware.
