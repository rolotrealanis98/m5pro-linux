# Modules for the series and WFI kernels

Built 2026-11-07 on the Studio, macOS recipe from the brief (`PATH` with the gnubin/llvm dirs, `ARCH=arm64 LLVM=1`,
`HOSTCFLAGS=-I~/Work/omarchy-m5/scripts/host-shim`, `HOSTCFLAGS_file2alias.o=-D_POSIX_C_SOURCE=200809L`).
No Image/vmlinux target was run and no out dir was cleaned (`vmlinux`, `Image`, `Image.gz` mtimes are unchanged in
both out dirs).

| | series | WFI test |
|---|---|---|
| worktree / out dir | `/Volumes/linux-cs/wt-series` (j716s-series, tip dd6b39464ca9) / `wt-series-out` | `/Volumes/linux-cs/wt-betizzel` (f080637018df) / `wt-betizzel-out` |
| kernel release (matches the Image's own string, and every module's vermagic) | `7.3.0-g4f630b11270d` | `7.3.0-gf080637018df` |
| `=m` options (`grep -c '=m$' .config`) | 1539 | 1539 (the two sets are identical, `diff` is empty) |
| modules built and packaged | 170 `.ko` (unresolved symbols after closure: 0) | 170 `.ko` (0) |
| tarball (3.3 MB each, `SHA256SUMS`) | `modules-7.3.0-g4f630b11270d.tar.zst` | `modules-7.3.0-gf080637018df.tar.zst` |
| staged tree | `modstage-7.3.0-g4f630b11270d/` | `modstage-7.3.0-gf080637018df/` |

Series note: HEAD (dd6b39464ca9) differs from the commit the Image was built at (4f630b11270d) only in
`arch/arm64/boot/dts/apple/t6050-j716s.dts`, so I passed `KERNELRELEASE=7.3.0-g4f630b11270d` to keep vermagic equal
to the running Image. (Side effect: kbuild regenerated `wt-series-out/arch/arm64/boot/dts/apple/t6050-j716s.dtb`
from HEAD's DT.)

## Why 170 modules and not all 1539 options

`make modules` for the whole set is ~4,900 compile units with `CONFIG_DEBUG_INFO`, and `wt-series-out` shares a
sparse 80 GiB volume with every other worktree; it had 5.3 GiB free when I started and 1.4 GiB (99 %) now. A first
full attempt compiled ~1,900 objects (about 1.2 GiB, still sitting in `wt-series-out`) before I stopped it. The
`=m` set is the arm64 "everything" set: 247 `snd`, 117 `drm` (panels, msm, tegra, rockchip, sun4i, ...), 85 `usb`,
45 `crypto`, and so on; almost none of it can bind on a MacBook. I built every module that can matter here plus
its dependencies (closure checked with `closure.py`, which compares each `.ko`'s undefined symbols with
`vmlinux.symvers` and the other modules), via single-module kbuild targets (`build-modules.sh`,
`targets-series.txt`). Because that is not a `make modules`, `make modules_install` cannot be used (it needs every
module built); `build-modules.sh` stages the same layout itself and strips debug info like `INSTALL_MOD_STRIP`.
The tarball puts the files under `usr/lib/modules/<release>/` (Arch's `/lib` is a symlink to `usr/lib`).

Counts of `=m` options per category (series config, same in WFI): apple 24, brcm/bcm 42, mt79/mt76 6, centauri 0,
snd 247, hid 8, usb 85, typec 19, drm 117, bluetooth 15, crypto 45, netfilter family 14, `nft_*` 1 (`NFT_COMPAT`),
tun/tap/veth/bridge/macvlan 4 (tap, veth, bridge, macvlan), zram 0, landlock 0, wireguard 0.

## What matters on the J716s, and what is built in

The R1 desktop fragment in the integration tree says "the root has no modules, so everything is =y", so a module
tarball is new capability for the root, not a replacement.

Already built in (`=y`) in both configs, nothing to install: `TUN`, `NF_TABLES` (core only, see below),
`SECURITY_LANDLOCK`, `ZRAM` (zstd backend, default comp zstd), `EXT4_FS`, `VFAT_FS`, `SQUASHFS`, `HIDRAW`,
`HID_APPLE`, `USB_HID`, `USB_XHCI_HCD`, `TYPEC_TPS6598X`, `USB_STORAGE`, `USB_UAS`, `DRM` + `DRM_SIMPLEDRM`,
`NVME_APPLE`, `MFD_MACSMC`, `SENSORS_MACSMC_HWMON`, `RTC_DRV_MACSMC`, `BPF_SYSCALL`, `USER_NS`, `NFS_FS`, `IPV6`,
`KVM`, `VIRTIO_NET`, USB-ethernet class drivers (`USB_USBNET`, `CDCETHER`, `NCM`, `RTL8152`), crypto CE/AES.

Built here (`=m`), grouped by use. DTB column: the module has an `of:` alias matching a compatible in HEAD's
`t6050-j716s.dtb` (the node is `status = "disabled"` in the static DTB; m1n1 enables nodes from the ADT, so this
is evidence, not proof).

| use on this machine | modules | note |
|---|---|---|
| USB gadget tether (CDC-EEM) | `libcomposite`, `usb_f_eem`, `u_ether`, `usb_f_ecm`, `usb_f_ncm`, `usb_f_acm`, `u_serial`, `usb_f_serial`, `usb_f_mass_storage`, `usb_f_fs`, `usb_f_rndis`, `usb_f_ecm_subset`, `g_mass_storage` | `USB_GADGET=y` but `USB_CONFIGFS`/`LIBCOMPOSITE`/`USB_F_*` are `=m`; the EEM tether needs these wherever the gadget is set up (probably the debug initramfs) |
| Crash logs | `ramoops` (+ `reed_solomon`) | `PSTORE_RAM=m`; ANALYSIS section 4 already notes "ramoops is still =m" |
| Apple SoC blocks (J716s relevant) | `apple-admac` (DTB), `i2c-pasemi-platform` + `-core` (DTB, `I2C_APPLE`), `spi-apple-qspi` (DTB), `spi-apple`, `thunderbolt` + `thunderbolt_apple` (USB4 / Thunderbolt, right port), `phy-apple-dptx`, `mux-apple-display-crossbar` (DP alt mode), `apple_dwi_bl` (backlight), `nvmem-apple-efuses`, `nvmem-reboot-mode`, `apple-sio`, `clk-apple-nco`, `apple_soc_edac` | `i2c`/`qspi`/`admac` are the only three with a DTB-matching alias |
| Apple audio | `snd`, `snd-pcm`, `snd-timer`, `snd-compress`, `snd-hwdep`, `snd-rawmidi`, `snd-pcm-dmaengine`, `snd-ctl-led`, `snd-soc-core`, `snd-soc-apple-mca`, `snd-soc-macaudio`, `snd-soc-tas2764`, `snd-soc-tas2770`, `snd-soc-cs42l42`, `snd-soc-cs42l84`, `snd-soc-dmic`, `snd-soc-hdmi-codec`, simple/audio-graph card, `snd-aloop`, `soundcore` | built, but J716s audio is AOP-owned (audio report), so expect no card |
| USB audio / video / serial / storage | `snd-usb-audio` (+ `snd-usbmidi-lib`), `uvcvideo` (+ `videodev`, `mc`, `videobuf2-*`, `uvc`), `cdc-acm`, `usbserial`, `ftdi_sio`, `cp210x`, `option`, `usb_wwan` | external devices on USB-C |
| USB Ethernet / Bluetooth dongles | `asix`, `lan78xx`, `smsc75xx`, `smsc95xx`, `dm9601`, `mcs7830`, `sr9800`, `pegasus`, `rtl8150`, `net1080`, `plusb`, `zaurus`, `cdc_subset`, `btusb` (+ `btbcm`, `btintel`, `btmtk`, `btrtl`, `btqca`), `hci_uart`, `hidp`, `hid-multitouch`, `i2c-hid(-of)` | the only networking besides the tether on a MacBook with no Ethernet |
| Containers / filesystems | `overlay`, `fuse`, `btrfs` (+ `libblake2b`, `raid6_pq`, `xor`), `veth`, `bridge` (+ `stp`, `llc`), `macvlan`, `tap`, `9pnet`/`9pnet_virtio` (+ `netfs`) | Omarchy/Docker/Flatpak style use |
| Netfilter bits | `nf_conntrack`, `nf_defrag_ipv4/6`, `x_tables`, `xt_mark`, `nft_compat`, `sch_ingress` | useless alone, see below |
| Crypto | `zstd`, `deflate`, `ccm`, `ctr`, `gcm`, `xts`, `chacha`, `md5`, `sha3`, `des_generic`, `dh_generic`, `crypto_engine`, `af_alg`, `algif_rng` (+ `libarc4`, `libchacha`, `libdes`, `libmd5`, `libsha3`) | the NEON AES modules were skipped: the CE versions are built in |
| Present in config, cannot bind on this board (built because the brief listed brcm/mt79/apple) | `brcmfmac` (+ `brcmutil`), `hci_bcm4377`, `mt7921e` (+ `mt76`, `mt76-connac-lib`, `mt792x-lib`, `mt7921-common`, `phylink`), `mac80211`, `apple_z2`, `spi-hid-apple(-of)`, `apple-pmp-j613-hwmon`, `rtc-apple-pmu`, `adpdrm` (+ `drm_display_helper`, `drm_dma_helper`), `ane`, `apple-isp`, `apple-avd`, `apple-ave`, `apple-jpeg`, `apple-prores` (+ `v4l2-mem2mem`, `v4l2-h264`, `v4l2-vp9`, `cec`), `nvme` | N1 Wi-Fi is Apple PCIe, not Broadcom; ISP is behind exclaves; J613 is another board |

Not built because they are not `=m`: centauri (no option exists), wireguard, zram, landlock (the last two are `=y`).

## Install on the root (root-side, as root)

Copy `modules-<release>.tar.zst` to the MacBook root (iCloud `m5pro-r1/` or the ESP, as with the payloads), check
`sha256sum` against `SHA256SUMS`, then for the series kernel:

```
tar -C / --zstd -xf modules-7.3.0-g4f630b11270d.tar.zst
depmod 7.3.0-g4f630b11270d
```

and for the WFI kernel the same with `7.3.0-gf080637018df`. `uname -r` of the booted kernel must equal that string
exactly, or modprobe will not look in the directory and the vermagic check refuses the files. Extraction touches
only `usr/lib/modules/<release>/`. If the root's `/lib` is not a symlink to `usr/lib`, run
`tar -C / --zstd -xf ... && mv /usr/lib/modules/<release> /lib/modules/` instead. Modules needed before the root is
mounted (the gadget tether, ramoops) also have to be in the initramfs; this tarball does not change the initramfs.

## Does anything that is missing on the root change? (Tailscale, tun, nft, wireguard)

- `tun`: `CONFIG_TUN=y`, built in, in both kernels. `/dev/net/tun` already works; no module involved.
- `wireguard`: `# CONFIG_WIREGUARD is not set`. Not a module either. Tailscale does not need it (userspace
  wireguard-go), so this does not block Tailscale.
- `nft_*`: the config has `NF_TABLES=y` but almost none of the expression/family modules: `NF_TABLES_IPV4`, `_IPV6`,
  `_INET`, `NFT_CT`, `NFT_NAT`, `NF_NAT`, `NFT_MASQ`, `NFT_LIMIT`, `NFT_REJECT`, `NFT_LOG`, `NFT_FIB_*` are all
  unset or absent; only `NFT_COMPAT=m`, `NF_CONNTRACK=m` and `NETFILTER_XTABLES=m` exist. With `NF_NAT` unset
  there is no NAT at all. So `ufw`, `iptables-nft` and Tailscale's exit-node masquerade cannot work with this
  `.config`, and the 170 modules do not change that. The integration tree's `omarchy-desktop.config` fragment
  (patch 0033) has the full list, all `=y`; the series `.config` does not include it.
- Policy routing: `IP_ADVANCED_ROUTER` is not set, so `IP_MULTIPLE_TABLES` and `IPV6_MULTIPLE_TABLES` are absent.
  Tailscale's Linux router installs `ip rule` entries (table 52); I believe it will not route in kernel mode without
  them (inference from how tailscaled works, not tested here). Needs a config change.
- Adding any of the above means editing the `.config` that the booted Image was built from (it is embedded in the
  Image via `IKCONFIG`), which I did not do. `IP_ADVANCED_ROUTER` / `IP_MULTIPLE_TABLES` are built-in booleans, so
  they need a new Image. `WIREGUARD`, `NFT_*` and `NF_NAT` could in principle be `=m` next to the built-in
  `NF_TABLES`, but options such as `NF_CONNTRACK_MARK` change `struct nf_conn`, and modules built against a
  `.config` that no longer matches the running Image would be unsafe. Merge the missing options into the next
  kernel build (the fragment makes them `=y`, matching "no modules on the root"), not into this tarball.

## Reproduce

`build-modules.sh SRC OUT RELEASE TARGETS [override]`, targets in `targets-series.txt` / `targets-wfi.txt`
(identical content). `closure.py OUT TARGETS` prints unresolved symbols (empty `{}` = closed). `resolve.py SRC
UNRES.json` maps unresolved symbols to the module that exports them. The build logs are `build-series.log`,
`build-wfi.log`. Free space on `/Volumes/linux-cs` is the limit; the script kills `make` under 768 MiB.
