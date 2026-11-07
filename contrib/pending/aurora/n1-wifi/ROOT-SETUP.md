# Root setup for the N1 (Wi-Fi/Bluetooth) on the MacBook's Arch root

Run the Studio steps on the Studio and the root steps over SSH on the MacBook (`/dev/nvme0n1p5`,
Arch Linux ARM). This is private material: the FTAB is per unit. Never copy it, or a payload or
initramfs that carries it, into a repo, a gist or a bug report.

## 1. Firmware

The kernel asks for one file, the control function's DT `firmware-name`. That is
`apple/centauri/j716s-ftab.bin` (fixed8/fixed9, and m1n1 0022 writes the same name from the ADT
`target-type`). It reads it with `request_firmware_direct()`: no user-mode helper and no fallback,
from `/lib/firmware` of whatever root is mounted when the driver probes.

| file | sha256 | size |
|---|---|---|
| `~/Work/studio-artifacts/j716s-fw/Firmware/t2026macG1/Release/ftab.bin` | sha256 of your own copy (not published) | about 31 MB |

On the Studio:
```
scp ~/Work/studio-artifacts/j716s-fw/Firmware/t2026macG1/Release/ftab.bin root@<macbook>:/root/j716s-ftab.bin
```
On the MacBook (root):
```
sha256sum /root/j716s-ftab.bin     # must equal the sha256 of the copy on the Studio (not published: the file is per unit)
install -D -m 0644 -o root -g root /root/j716s-ftab.bin /usr/lib/firmware/apple/centauri/j716s-ftab.bin
ls -l /lib/firmware/apple/centauri/                  # /lib -> usr/lib on Arch
head -c 40 /lib/firmware/apple/centauri/j716s-ftab.bin | tail -c 8; echo   # must print rkosftab
rm /root/j716s-ftab.bin
```
* Mode 0644, owner root, no execute bit. The driver does not care about SELinux or xattrs.
* No compression: `CONFIG_FW_LOADER_COMPRESS` is off, so a `.zst` or `.xz` name would not be found.
* **The `.im4m` manifests are not needed and not read.** The driver loads only `firmware-name`.
  Keep `centauri.j716sap*.im4m` on the Studio.
* **Caveat (ANALYSIS.md 2.3):** this `ftab.bin` has no ticket. The header words at 0x08-0x1f are zero,
  and none of its 83 entries is a ticket. The only `IM4M` bytes are inside the `rkos` image. If the
  N1 ROM wants a personalised ticket, the ROM boot fails with `N1 automatic startup failed in
  phase0: -5`, and the file then needs the manifest stitched in. That format is not known.

### The firmware must also be in the initramfs when the drivers are built in

With `APPLE_CENTAURI=y` (no modules are built for these payloads), the control function probes
during PCI enumeration. That is before `switch_root`, so the driver looks in the initramfs's
`/lib/firmware`. The R3-W payload therefore uses `initramfs-selftest-n1.cpio.gz`: the selftest
initramfs plus this one file, built on the Studio by `mk-initramfs-n1.py` (R3-W-RECIPE.md). It
stays in `~/Work/agents/n1-wifi/payloads/` and on the ESP only.

Fallback if the initramfs copy is missing: the driver logs `required firmware
apple/centauri/j716s-ftab.bin unavailable: -2` and `N1 automatic startup failed in phase0: -2`.
The N1 is still in its ROM stage then, so a rebind from the real root retries the boot:
```
echo 0000:01:00.0 > /sys/bus/pci/drivers/apple_centauri/unbind
echo 0000:01:00.0 > /sys/bus/pci/drivers/apple_centauri/bind
dmesg | tail -30
```

## 2. Wireless userspace: iwd, alongside the existing systemd-networkd Ethernet

The root uses systemd-networkd, with Ethernet in `/etc/systemd/network/20-wired.network`. Keep that
file and that service. Add iwd for Wi-Fi only, and let networkd keep doing DHCP on both
interfaces. iwd is what PR #938 was tested with (its connect path follows iwd's channel-subset
scans) and is the simplest choice next to networkd. Do not install NetworkManager: it would take over
`eth*`/`enp*` unless it is told not to. Do not run wpa_supplicant next to iwd.

Check first:
```
pacman -Q iwd wireless-regdb bluez bluez-utils 2>/dev/null
systemctl is-enabled systemd-networkd systemd-resolved iwd wpa_supplicant NetworkManager 2>&1
ls /etc/systemd/network/ /etc/iwd/ 2>/dev/null
networkctl list
```
Install and configure (no change to `20-wired.network`):
```
pacman -S --needed iwd wireless-regdb bluez bluez-utils
install -d -m 0755 /etc/iwd
cat > /etc/iwd/main.conf <<'CONF'
[General]
# networkd does the addressing; iwd only associates
EnableNetworkConfiguration=false

[Network]
NameResolvingService=systemd
CONF
cat > /etc/systemd/network/25-wireless.network <<'CONF'
[Match]
Name=wlan*

[Network]
DHCP=yes
IgnoreCarrierLoss=3s

[DHCPv4]
RouteMetric=600
CONF
systemctl disable --now wpa_supplicant.service 2>/dev/null || true
systemctl enable iwd.service bluetooth.service
systemctl restart systemd-networkd
```
* `RouteMetric=600` keeps the wired default route (networkd default 100 for DHCP on Ethernet)
  preferred when both are up, so SSH over Ethernet keeps working while you test Wi-Fi.
* `20-wired.network` sorts first and matches only the wired name, so `wlan0` falls through to
  `25-wireless.network`. If `20-wired.network` matches by `Type=ether` or `Name=*`, check that it
  does not also catch `wlan0`: `networkctl status wlan0` must show `25-wireless.network`.
* The interface is named `wlan0` by the driver (`wlan%d`). If systemd's predictable naming
  renames it (`wlp1s0f1`-style), the `wlan*` match misses it. Then add
  `Name=wlan* wlp*` to `[Match]`.
* regulatory: `wireless-regdb` provides `regulatory.db`. With `CFG80211=y` the first load
  happens before the root is mounted, so an early `failed to load regulatory.db` line is expected;
  cfg80211 then stays on the world domain (fewer 5/6 GHz channels) until a later reload. Harmless
  for a first test. `iw reg get` shows the domain in use.

First association (after R3-W shows `wlan0`):
```
iwctl station wlan0 scan; sleep 3; iwctl station wlan0 get-networks
iwctl --passphrase '<psk>' station wlan0 connect '<SSID>'
networkctl status wlan0; ip -4 addr show wlan0; ping -c3 -I wlan0 1.1.1.1
```
Bluetooth (after `hci0` appears):
```
btmgmt info; bluetoothctl show; bluetoothctl scan on
```

## Rollback
```
systemctl disable --now iwd.service bluetooth.service
rm /etc/systemd/network/25-wireless.network /etc/iwd/main.conf
systemctl restart systemd-networkd
rm /usr/lib/firmware/apple/centauri/j716s-ftab.bin
```
