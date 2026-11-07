# USB Wi-Fi / Bluetooth dongles on the J716s Arch root

Fallback networking for Linux on the 16-inch MacBook Pro M5 Pro while the
internal N1 has no usable driver on our native boot path (see REPORT.md).
Nothing here has been run on the Mac. Do the steps in order, and only once
the owner has handed the machine back.

## 0. Prerequisite: USB host mode (blocking)

Every Type-C port is a dwc3 **gadget** today, so a dongle cannot enumerate.
First boot and check the pending series in
`~/Documents/GitHub/m5pro-linux/contrib/pending/usb/` (REPORT.md, TEST-PLAN.md):

- `t6050-j716s-usbhost.dtb` turns **dwc3_1 = left-front port** into a host;
  the left-back (MagSafe side) and right ports stay gadgets.
- **USB 2.0 high-speed only** (480 Mbit/s): a Wi-Fi 6/6E dongle tops out
  at about 250-300 Mbit/s, so a Wi-Fi 7 dongle gains nothing.
- **VBUS**: milestone 1a never switches VBUS on. If the port shows 0 V,
  nothing powers the dongle until 1b (the PD controller) lands.
- **Hot-plug** is fragile: the eUSB2 repeater only re-syncs after a PHY
  reset. Plug the dongle in **before boot**, and do not plan on replugging
  it to recover from a firmware load that failed.
- One host port: the USB Ethernet adapter and the dongles compete for it.
  Use a Wi-Fi+BT combo dongle, or a powered USB 2.0 hub once VBUS works.

Go/no-go: `cat /sys/bus/usb/devices/*/product` lists a plugged keyboard
or stick on the left-front port, and nothing has regressed on the gadget
ports (10.55.0.2 is unchanged; the right port renumbers to m5pro-1).

## 1. Buy (short list; details and alternatives in REPORT.md)

| Role | Pick | Chip / driver | Firmware |
|---|---|---|---|
| Wi-Fi + BT on one port | ALFA AWUS036AXML | MT7921AUN / mt7921u + btusb(btmtk) | mediatek/*MT7961* |
| Wi-Fi only | EDUP EP-AX1672, Panda PAU0F, BrosTrend AX9L, Netgear A8000, TP-Link Archer TXE50UH | MT7921AU(N) / mt7921u | mediatek/*MT7961* |
| BT only | TP-Link UB500, ASUS USB-BT500 | RTL8761BU / btusb(btrtl) | rtl_bt/rtl8761bu_fw.bin |
| Safe Wi-Fi fallback (2.4 GHz, N150) | ALFA AWUS036NHA, TP-Link TL-WN722N **v1 only** | AR9271 / ath9k_htc (open firmware) | ath9k_htc/htc_9271-1.4.0.fw |
| Safe BT fallback | genuine CSR8510 A10 (0a12:0001); clones are common | btusb | none |

You also need a passive USB-C (male) to USB-A (female) adapter.

## 2. Kernel config (on the Mac build host)

```sh
cd ~/Work/omarchy-m5
cp ~/Documents/GitHub/m5pro-linux/contrib/pending/usb/config/omarchy-usb-host.config configs/
cp ~/Work/agents/wireless/configs/omarchy-wireless-dongles.config configs/
# optional, recommended (step 3a):
cp ~/Work/agents/wireless/configs/omarchy-wireless-embed-fw.config configs/
```

Then edit `scripts/build-kernel.sh` by hand (it is not changed here):

1. Append the fragments to `KCONFIG`, after `omarchy-smc.config`:
   `omarchy-usb-host.config omarchy-wireless-dongles.config [omarchy-wireless-embed-fw.config]`.
2. Add the same file names to the `install -m 0644 configs/... "$LINUX/arch/arm64/configs/"` line.
3. Add `CONFIG_CFG80211 CONFIG_MAC80211 CONFIG_MT7921U CONFIG_BT CONFIG_BT_HCIBTUSB`
   to `REQUIRED_Y`. **This matters:** `ensure_config` only rebuilds `.config`
   when a `REQUIRED_Y` symbol is missing, so new fragments are otherwise
   silently ignored. You can also delete `$LINUX/.config` once instead.

Checked here: merged on top of the current `/Volumes/linux-cs/linux/.config`
in a scratch `O=` directory with `merge_config.sh` and `olddefconfig`. All
symbols come out as requested, nothing that was =y drops, and 114 new =y
symbols are added. The wireless, BT, cfg80211/mac80211 and firmware_loader
directories compile clean with LLVM (single targets, no vmlinux).

## 3. Firmware must be there at FIRST enumeration

The drivers are built in, so they probe as soon as the dongle enumerates
(the dwc3 probe is at about 6 s), before the root mounts (about 13.5 s).
mt7921u retries its MCU init a few times with no delay and then stays dead.
btusb's setup and cfg80211's `regulatory.db` load (late_initcall) also run
before the root is mounted. Choose one of these:

**3a. Embed in the kernel (recommended, self-contained).**
`omarchy-wireless-embed-fw.config` lists the MT7921 Wi-Fi + BT blobs, the
RTL8761BU blob and `regulatory.db{,.p7s}` (about 1.5 MB). Edit the list to
match the hardware you actually have, then stage the files:

```sh
git clone --depth 1 https://gitlab.com/kernel-firmware/linux-firmware.git /tmp/lf
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git /tmp/regdb
~/Work/agents/wireless/scripts/stage-wireless-fw.sh /tmp/lf /tmp/regdb
# -> ~/Work/agents/wireless/fw-staging (= CONFIG_EXTRA_FIRMWARE_DIR); already staged once here
```

A file missing from the list fails the build, so you cannot ship an image
with a hole in it.

**3b. Initramfs.** `scripts/mkinitramfs.py --firmware <dir>` packs `<dir>`
as `lib/firmware/` inside the initramfs, and the firmware loader waits for
the initramfs (`wait_for_initramfs()`). Put the same paths from
`firmware-files.txt` under `<dir>`, keeping the existing
`apple/tpmtfw-j716s.bin`.

**3c. Root only.** Works only if the dongle is plugged in after boot, and
hot-plug is unreliable (step 0). Do not rely on it.

## 4. Arch root (once booted with the usbhost DTB and the new kernel)

```sh
pacman -Syu
pacman -S --needed wireless-regdb linux-firmware-mediatek linux-firmware-realtek \
    linux-firmware-atheros iwd iw bluez bluez-utils usb_modeswitch usbutils
mkdir -p /etc/iwd && printf '[General]\nEnableNetworkConfiguration=true\n' > /etc/iwd/main.conf   # iwd does DHCP itself
systemctl enable --now iwd bluetooth
```

ALARM's linux-firmware 20261019 installs **uncompressed** files under
`/usr/lib/firmware` (`make install` in its PKGBUILD). The fragment still
accepts `.zst` and `.xz` in case a file is copied over from x86 Arch.
`mkrootfs-image.py` drops `usr/lib/firmware/` when it builds an image, so
after re-imaging the root you must reinstall these packages.

Wi-Fi:

```sh
iw reg get                      # should show the db loaded, not just "00" with a warning in dmesg
iwctl device list; iwctl station wlan0 scan; iwctl station wlan0 connect "<SSID>"
ip -4 addr show wlan0           # DHCP lease from iwd (main.conf above)
```

Bluetooth:

```sh
bluetoothctl power on; bluetoothctl scan on; bluetoothctl pair <MAC>; bluetoothctl trust <MAC>; bluetoothctl connect <MAC>
```

## 5. What to check in dmesg

- `cfg80211: loaded regulatory.db` (not `failed to load regulatory.db`).
- `mt7921u ... HW/SW Version ... WM Firmware Version` followed by a wiphy.
  If it says `hardware init failed`, the firmware was missing at probe (step 3).
- `Bluetooth: hci0: RTL: fw version ...` or `hci0: HW/SW Version` (MediaTek).
- A dongle that appears as a CD-ROM (`usb-storage`, `sr0`) is a
  "multi-state" Realtek part: `usb_modeswitch` (its udev rule) switches it.
  Prefer single-state models instead.

## Files

- `configs/omarchy-wireless-dongles.config`: drivers, cfg80211/BT, firmware loader, iwd crypto (all =y).
- `configs/omarchy-wireless-embed-fw.config`: optional `CONFIG_EXTRA_FIRMWARE` set.
- `scripts/stage-wireless-fw.sh`: stages the embed set from linux-firmware + wireless-regdb.
- `firmware-files.txt`: linux-firmware paths per chip.
- `packages.txt`: Arch packages.
- `dt/t6050-n1.dtsi`: **disabled**, descriptive-only N1 PCIe nodes (not for use; see REPORT.md).
