# ISP / Thunderbolt test plan (J716s, T6050), for the hardware agent

Run nothing here until the owner has finished recovering the machine and allows hardware work again. Order:
I0, I1, then T0. Everything after T0 waits for its gate.

## Standing rules (tether)
- The MagSafe-side port (left-back = port 1 = hpm0/atc-phy0/acio0/usb-drd0) carries the CDC-EEM tether
  (10.55.0.2) to the Mac Studio through the Thunderbolt cable and dock. Never unplug it. Never plug test devices
  into it. Never boot a DTB that has an hpm0, atcphy0, acio0 or apciec0 node or a `usb4-0-*` alias. Check
  before every boot:
  `dtc -I dtb -O dts <dtb> | grep -E 'usb4-0|acio@2a1|atcphy0|usb-pd@c' ; # must print nothing`
  (usb-pd@c on nub-spmi-a1 is hpm2 and is allowed in T2+; check which bus it sits under).
- Hazard: if port 1 ever came up as a USB4/TB host router, the dock/Studio would see a TB host instead of a USB
  device. The gadget link would drop (XDomain host-to-host), and SSH and the console tether would go with it.
  Recovery would then need R2 (power-hold + macOS).
- No TB experiment runs until a second access path works. Accepted paths: the USB agent's USB Ethernet dongle
  on the left-front host port, or keyboard + panel with a local shell.

## Deploy and rollback (same as the platform plan)
- Before each new payload: `cp /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev && sha256sum /boot/m1n1/boot.bin*`.
- R1 (Linux reachable): `cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin && sync && reboot`.
- R2 (no SSH): hold power until off, then hold power to reach the boot picker. One-time boot Macintosh HD. Run
  `diskutil list`, then `diskutil mount` the FAT32 OMARCHY partition (p4), then
  `cp /Volumes/OMARCHY/m1n1/boot.bin.prev /Volumes/OMARCHY/m1n1/boot.bin`, then restart.
- R3 (preferred for every first boot of a new DTB): rename `m1n1/boot.bin` to `boot.bin.hold`, boot the stage-1
  proxy, then from the Studio run tools/linux.py with Image.gz + the test DTB (docs/boot-and-recovery.md).
  Rename the file back afterwards.

## Camera
- I0 (no change, no risk): under today's kernel, look at the notch. Is the green camera LED lit? Record it
  with a photo.
  `grep -iE 'isp|sens' /sys/kernel/debug/pm_genpd/pm_genpd_summary` (record isp_sys / ispsens0 state).
  `dmesg | grep -i isp` should be empty. In the m1n1 log, expect `isp: Unsupported SoC` and
  `FDT: 'isp' not found`.
- I1 (patch 0001, DTB sha256 e51ed544...7216, normal kernel):
  1. Apply with `git -C ~/Work/omarchy-m5 apply patches/omarchy-m5/0001-dt-t6050-describe-the-camera-ISP-disabled.patch`,
     then build-kernel.sh dtbs.
  2. Pass criteria:
     - `cat /proc/device-tree/soc/isp@580000000/status` = disabled;
     - no apple-isp or DART messages for 5828c0000/5828e0000/582900000;
     - the m1n1 log is unchanged ("'isp' not found");
     - tether, keyboard, NVMe and fans behave as before;
     - genpd summary is unchanged from I0.
  3. Rollback: R1.
- I2 and I3 (research, not this agent without owner approval): m1n1-proxy probing of ISP_SYS / ISP power
  states and a macOS hypervisor trace. See REPORT Part A. Never under Linux: an SError there takes the root FS
  down with it.

## Thunderbolt (right port only)
- T0 (read-only, today's kernel): record
  `busybox devmem 0x2806002e8 32; busybox devmem 0x2806003f8 32; busybox devmem 0x280600400 32;`
  `busybox devmem 0x280600408 32; busybox devmem 0x2806002f0 32; busybox devmem 0x280600238 32`
  (ATC2_CIO, _CIO_PCIE, _CIO_USB, _CIO_AUSS, ATC2_PCIE, ATC2_COMMON). Expect 0x300 x5 and an "on" value for
  COMMON. These are reads of PMGR pwrstate words only; never write. Also record what is plugged into each port.
- Gate for T1+: the USB agent's milestones 1a and 1b pass (left-front host port with Ethernet, polled
  SN201202x). A second access path exists. A kernel with aurora's j716c/thunderbolt series
  (81bd9173..2ac11995) has been imported and builds. A separate `t6050-j716s-tb.dtb` describes ATC2 only.
- T1: TB kernel + OLD DTB (t6050-j716s.dtb). Expect identical behaviour: no phy-apple-t6050/acio/nhi probe lines;
  3 UDCs (or 2 with the usbhost DTB).
- T2: TB kernel + tb DTB, right port EMPTY.
  - Expect: combo PHY probe on 382a90000/383000000; hpm2 registered ("polling"); no ACIO power-on; T0 PMGR values
    unchanged (router off).
  - The tether at 10.55.0.2 still works. The right-port gadget interface is gone (expected).
  - No async SError and no watchdog reset within 10 minutes.
- T3: native USB3 device (flash drive) on the right port: USB3 SuperSpeed enumeration via the combo PHY. Then
  unplug and replug twice.
- T4: a USB4/TB device on the right port. Use a TB SSD enclosure or a second dock, never the tether dock.
  - Expect:
    - PHY CIO mode;
    - ATC2_CIO* domains on;
    - "M3 firmware" ready;
    - NHI probe on 381f00000;
    - `thunderbolt 0-0` domain, device authorised (`boltctl`/sysfs);
    - USB3 tunnel: the hub appears on dwc3_2.
  - PCIe tunnel (enclosure NVMe in `lspci`) is a bonus, not a pass criterion.
  - Then unplug: domains back to 0x300.
- T5: connect/disconnect T4 three times. Every second connection failing points to the PHY firmware data
  restore (aurora ffb98ff6) missing.
- T6 (optional; becomes the second access path): right port to a free Mac Studio Thunderbolt port. On the
  Studio, enable Thunderbolt Bridge. On the M5, `ip link` should show thunderbolt0; assign an address and ssh
  over it. Never use the tether cable for this.

Triage:
- SError or reset at plug-in: ordering (PHY not in CIO before the router, or CIO reconfig not complete). Roll
  back with R1/R2 and keep the log.
- DART faults on 381a80000: missing DART tunables or bypass SID 15.
- Router never ready: tunables/DROM not filled. Check that the DT carries the ADT tunables. Do not paste our
  DROM into tracked files.
- Port dead after the first unplug: PHY firmware data restore.
- Anything at all on port 1: stop, R1, report.
