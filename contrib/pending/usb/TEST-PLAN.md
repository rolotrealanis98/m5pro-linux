# USB host test plan (J716s)
Prereqs: `git -C ~/Work/omarchy-m5 am patches/omarchy-m5/0001-*.patch`; apply-patches.sh; build-kernel.sh (regenerates
.config via REQUIRED_Y); check CONFIG_PHY_APPLE_USB2=y and t6050-j716s-usbhost.dtb built; keep old Image.gz/dtb.
Hardware: passive USB-C to USB-A adapter, USB-A Ethernet dongle (AX88179 or RTL8153), flash drive or keyboard, optional
powered hub, inline USB-C power meter. Not the CalDigit on the host port. Host port = left front (drd1).

Step 0 (m1n1 proxy, no Linux change): get to the proxy (move m1n1/boot.bin aside on the ESP); `m5.sh py
scripts/usb-proxy-probe.py`: each atc-phyN "matches dtsi" and USBCTL=0x00000002 SIG=0x01c1000f MISCTUNE=0x008c0813. If an
address differs: fix t6050-usb-host.dtsi and stop. Then `--pd` (and `--wake` if select fails): record bus gen, SIDs, MODE
("APP " expected), SYSTEM_POWER_STATE, STATUS. From the ADT dump: `gen-usb-dt.py ADT --check` / `--dump`.
Step 1: new kernel + OLD DTB: tether as before; no phy-apple-usb2/xhci/sn201202x lines; `ls /sys/class/udc` = 3.
Step 2: new kernel + usbhost DTB, host port empty: three `phy-apple-usb2 ...` lines (2aaa90000 "default host mode",
others device); xhci-hcd on 2aa280000.usb with two root hubs, no -110/HC died/DART faults; usb_role 2aa280000.usb-role-switch
= host; udc = 2a2280000.usb and 382280000.usb only; ssh 10.55.0.2 still works; right port is now 10.55.1.2.
Step 3: first device (plugged before boot; meter ~5 V = PD sourcing VBUS, 0 V -> Step 7): `usb 1-1: new high-speed USB
device`, driver binds (usb-storage/sd or input); storage mount ro + dd ~30-40 MB/s; keyboard types on the panel; then hot-plug.
Step 4: Ethernet dongle: r8152/ax88179 eth0; link up, speed; systemd-networkd DHCP (20-usb-ether.network Match en* eth*,
DHCP=yes; networkctl reload); ping -I; initramfs: busybox udhcpc -i eth0.
Step 5: replug and re-sync: USB disconnect / replug; if no enumeration: unbind/bind 2aa280000.usb on the dwc3 driver;
record hot-plug/replug/rebind; repeat with a powered hub carrying keyboard+storage+Ethernet.
Step 6 (optional): role flip via /sys/class/usb_role/.../role device|host.
Step 7 (1b, after Step 0 --pd): `gen-usb-dt.py ADT --pd --host-port 1 > dt/t6050-usb-pd.dtsi`; t6050-j716s-usbpd.dts
includes usbhost + pd; expect sn201202x "no SPMI interrupts, polling", no select timeouts; /sys/class/typec/port*/data_role
[host] power_role [source] with a dongle; role change on unplug; replug without rebind. On failure: usbhost DTB.
Triage: PHY regs 0/0xffffffff/SError -> wrong address (Step 0); dwc3 -110 -> PHY order / ATC gating (try without phys, set
SIG host bits via busybox devmem 0x2aaa90008 32 0x01c1700f); xHCI up but 0 V -> Step 7; VBUS present no enumeration ->
host bits/repeater desync (rebind, plug before boot); first works replug doesn't -> repeater (rebind, Step 7); DART faults ->
stream IDs.
Rollback: always t6050-j716s.dtb (unchanged) with new or old Image.gz; ESP: boot.bin.prev; from macOS mount the OMARCHY FAT
volume to copy back. 1a writes only PHY/dwc3 registers; 1b also the PD controller power state / interrupt mask (assumed to
reset on power cycle, unverified).
