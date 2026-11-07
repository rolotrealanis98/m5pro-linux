# Wireless on the M5 Pro (T6050, J716s): the N1, and USB dongles as the fallback (agent report 2026-11-04; nothing run on the M5)

Short version: the N1 is a three-function Apple PCIe endpoint (VID 0x106b) on
apcie0 port 0. Nothing in the ADT ties it to an exclave. Aurora Silicon
published a GPL N1 driver stack in the last ten days: firmware boot, Wi-Fi
station with WPA2/WPA3-SAE, and Bluetooth HCI/ACL, plus a bare-metal T6050
PCIe host that adopts ports the bootloader has already trained. Bringing
that to our asahi-wip boot is a project of **months, not years**. Three
things gate it: training apcie0 in the bootloader (not public), a
per-device personalized FTAB firmware image, and USB-independent
validation. The practical path now is a USB Wi-Fi + BT dongle on the
left-front port, and it is **sequenced after** the pending USB-host DTB is
validated (USB 2.0 only, VBUS unproven, fragile hot-plug).

## 1. ADT: how the N1 is attached (verified from adt-runtime-j716s.bin; hardware-description properties only)

| What | ADT | Value |
|---|---|---|
| Chip | `/product wifi-chipset` | `proxima`; `bluetooth-le`=1, `bluetooth-lea2`=1 |
| Bus | `/arm-io/apcie0` | `apcie,t6050`, `#ports` 4, `device_type` pci, 40 reg entries |
| Port | `apcie0/pci-bridge0` | `apcie-port` 0, `maximum-link-speed` 3 (Gen3), `centauri-builtin`, `keep-root-port-on`, `enable-ptm`, `pci-aspm-default` 2, `manual-enable` |
| Functions | `pci-bridge0/centauri-control` / `-alpha` / `-beta` | `pcie-device` at unit 0/1/2 (dev 0, fn 0..2); alpha has `network-interface-unit-en` (+ a MAC, not quoted) |
| PCI IDs (from Aurora's driver) | n/a | control 106b:1900 (ROM) / 1901 (running), alpha (Wi-Fi) 106b:1902, beta (BT) 106b:1903 |
| ECAM | apcie0 reg[0] | 0x1cb0000000, 256 MiB |
| rc / port0 / phy0 / intr2axi0 | reg[1] / reg[16] / reg[18] / reg[19] | 0x414000000 / 0x410028000 (0x8000) / 0x417010000 / 0x410024000 (raw +0x2_0000_0000) |
| BAR windows | `ranges` | 32-bit bus 0x80000000 -> 0xb80000000 (1 GiB); 64-bit prefetch 0xbc0000000 (512 MiB) |
| IRQs | apcie0 `interrupts` | AIC 1523/1531/1539/1547 (per port), 1558, 1559; `msi-vector-offset` 1824, `#msi-vectors` 128 (bridge0 base 0, bridge1 base 32) |
| DART | `/arm-io/dart-apcie0` | `dart,t8110`, raw 0x210000000 (-> 0x410000000) + 0x803f0000, AIC 1524, `sid` 0x10/0x11/0x12, `sid-count` 19, page 16K, mappers control/alpha/beta/piodma (piodma SID 17), `bypass-16`/`bypass-18` |
| PIODMA | `/arm-io/apcie0-piodma` | `pcie-apiodma,t6020`, raw 0x210030000.., AIC 1525 |
| PERST# / CLKREQ | pci-bridge0 `function-perst` / `function-clkreq` | gpio0 pin 0x50 (80) / pin 0x4c (76) |
| Power / reset | `function-reset`, `function-warm_reset` | SMC (smc-pmu) key `gP13`, the same key the M1 BCM4378 port uses as `pwren-gpios = <&smc_gpio 13>`; warm reset via SMC key `bpli` |
| SID handling | `function-dart_request_sid/release_sid/self/force_active` | DART-side dynamic SID ops, called by macOS's PCIe driver |
| Power gates | apcie0 `power-gates` | APCIE_GP, APCIE_SYS_GP, APCIE_GE, APCIE_SYS_GE, APCIE_ST0/1, APCIE_SYS_ST0/1, APCIE_PHY_SW, APHY_{GP,GE,ST0,ST1}_AUS5(_A), ANS (shared with storage) |
| Misc node | `/arm-io/centauri` (`device_type` centauri) | `function-error_detect` on aop-gpio0 pin 0x12 (IRQ 18), `function-sac` -> `/sacm` SACC('lcd0','lcd1'), Wi-Fi power-backoff/duty-cycle/voltage tables (not quoted) |
| BT node | `/arm-io/bluetooth` | `transport-encoding` 9, no reg (address only) |
| PMU link | `/arm-io/aop-spmi0/spmi-wifibt` | slave on the **AOP-owned** SPMI bus (aop-spmi0, raw 0x90900000..), reg words 0x0e, 0x03, 0, 0x4, 0, 0 |
| Same controller | `apcie0/pci-bridge1/pcie-sdreader` | port 1, Gen1, PERST 0x51, CLKREQ 0x4d, own DART dart-apcie1 |
| Firmware names | none | the ADT names no Wi-Fi/BT firmware (the only `firmware-name` props are AOP/PMP/SMC/GFX) |

**Exclave/secure involvement:** no node references the N1, apcie0 or
dart-apcie0 from an exclave context. I walked every `function-*`,
`iommu-parent` and `interrupt-parent`. Compare ISP, DCP, ANE and AOP,
which do have `*-exclave` mappers. Two indirect paths exist. The PMU link
`spmi-wifibt` hangs off the AOP's SPMI bus, and the AOP has an
`aop-exclave-mailbox` (`iop,secure-rtbuddy-proxy`). The power key `gP13`
goes through the SMC. So power sequencing runs through SMC (Linux has
macsmc-gpio) and possibly AOP firmware. Whether the AP can drive
`spmi-wifibt` directly is unknown.

**Compared with M1-M3 (kernel DTs):** t8103-jxxx.dtsi has `&port00 { bus-range = <1 1>; pwren-gpios = <&smc_gpio 13 ...>; wifi@0,0 "pci14e4,4425"; bluetooth@0,1 "pci14e4,5f69" }`.
t602x-j414-j416.dtsi and t8122-jxxx.dtsi use `pci14e4,4434` (BCM4388). All
of those are Broadcom (brcmfmac + hci_bcm4377), with Wi-Fi at function 0
and firmware chosen by chip/board/antenna-SKU. The N1 differs in four
ways: Apple VID, a dedicated **control** function 0 that boots shared
firmware for both radios, Wi-Fi at fn 1, BT at fn 2, and one
**personalized FTAB** image (RTKit `rkosftab` magic at 0x20, with
per-device calibration). The pwren key (gP13) and the PERST convention
(gpio0, active low) carried over.
**Aurora's J716c DT** (aurora-silicon/linux `j716c/dt` b54638d,
2026-11-03) describes the same port: rc/port0/phy0/intr2axi0 at the
addresses above, `iommu-map = <0x100 &dart_apcie0 1 3>` (functions 0-2 on
DART streams 1-3, not the ADT `sid` values 0x10-0x12), MSI AIC 1888 x64
with `apple,msi-vector-base = <64>`, `reset-gpios = <&pinctrl_ap 80 ...>`,
`apple,link-trained-by-bootloader`, and
`apple,centauri-platform-id = <0x000e6050>` (board 0x0e for J716c), with
`firmware-name = "apple/centauri/j716c-ftab.bin"`. The board ID for J716s
is not known here.

## 2. Public knowledge and feasibility

Public record (no die/bus analysis is free):
- Apple N1 shipped in iPhone 17 / Air in Sept 2025: Wi-Fi 7 (160 MHz max), BT 6, Thread
  ([MacRumors 2025-09-13](https://www.macrumors.com/2025/09/13/apple-n1-chip-has-wi-fi-7-limitation/),
  [Engadget 2025-09](https://engadget.com/mobile/smartphones/apples-new-wireless-chips-give-it-even-more-control-of-the-iphone-194820274.html)).
- TechInsights floorplan of the N1 package / "TMSX10" die, Oct 2025 (paywalled):
  [techinsights.com/ja/node/60557](https://techinsights.com/ja/node/60557); iPad Pro M5 teardown with N1, Dec 2025:
  [node/60896](https://www.techinsights.com/ja/node/60896).
- MacBook Pro M5 Pro/Max with N1, announced 2026-03-03
  ([MacRumors](https://www.macrumors.com/2026/03/03/apple-unveils-macbook-pro-with-m5-pro-and-m5-max-chips-with-neural-accelerators/));
  no 320 MHz / 4096-QAM ([mrncciew 2026-03-17](https://mrncciew.com/2026/03/17/macbook-pro-m5-wi-fi-7-missing-4096-qam-320-mhz/)).
- Asahi: M3 is close to release, and M4/M5 are early, with nothing on the N1
  ([Phoronix 2026](https://phoronix.com/news/apple-m3-asahi-linux-2026)).
  My searches for marcan/Asahi N1 notes, a "libn1"-style RE project, or iOS
  kext dumps (AppleN1*/centauri) found nothing public. That means "not
  found", not "does not exist".
- **Aurora Silicon (the substantive public work), all GPL in aurora-silicon/linux:**
  - `t6050/centauri-core` a3cc811 (2026-10-26): `drivers/net/wireless/apple/centauri/{centauri_pci,centauri_ipc}.c`.
    Control function: loads the personalized FTAB via `request_firmware_direct`, writes the platform ID and
    descriptor DMA address into BAR0 (0x807c/0x8044/0x8048), rings 0x9000, and waits for boot stage 4.
    Then comes the ACIPC transport (protocol 27).
  - `t6050/centauri-wifi` 9a4dad6 (2026-10-26): cfg80211 station mode; 2.4/5 GHz active scan; WPA2-PSK with handshake offload.
  - `t6050/centauri-bluetooth` 93c2c77 (2026-10-26): `drivers/bluetooth/btcentauri.c` (106b:1903), HCI/ACL, no SCO/ISO.
  - `j716c/t6050-n1` (2026-11-03/04): WPA3-Personal via firmware SAE, bands from the firmware channel list, and
    "Bind the N1 behind the bare-metal T6050 host" (6427fb6): it runs on a boot with no SPTM, where the bootloader trains apcie0
    port 0 and pcie-apple adopts it.
  - `j716c/t6050-pcie` (2026-11-02/04): `apple,t6050-pcie` adopts bootloader-trained ports
    (tested on J775D with an RTL8127 and an ASM3142). It also handles port 0's multi-function N1 and a `reset_root_port`
    that retrains after the ROM stage.
  - Their docs (`Documentation/arch/arm64/aurora-apif-centauri.rst` on integration/aurora 1d76233, 2026-11-04) say
    hardware qualification is pending, including suspend/resume. No commit states a successful association on hardware.
  - The bootloader side (apcie0 port-0 training, filling the FTAB name and platform ID, addresses from /chosen) is
    **not in their public m1n1 branches**, and I found no public source for the FTAB file.
  - The older APIF variant runs Linux as a guest under their EL2 monitor "Aura" (SPTM mediation). It is irrelevant to us.

**Feasibility verdict.** Without Aurora's work, this would be a
multi-year RE project. With it, J716s Wi-Fi association on our tree is
**roughly 1-3 months** of focused work. Production quality (6 GHz,
roaming, suspend, BT audio) takes longer. The long poles, in order:
1. apcie0 port-0 bring-up on T6050: PHY power, tunables, link training.
   Our m1n1 `pcie.c` stops at `apcie,t6040`. Aurora's kernel already
   carries the T6050 disable/reset/enable/configure/train sequence library
   (`drivers/pci/controller/apple-apif/t6050*`), so this is porting, not
   blind RE.
2. The personalized FTAB, plus its platform ID (board<<16 | 0x6050).
   Where macOS keeps it, and whether it is per-unit (Aurora: "per-device
   calibration"), is unknown. It is the firmware analogue of
   asahi-fwextract and has to live in the installer/loader, not in the
   driver.
3. Rebasing about 14 Aurora commits (pcie-apple T6050 adoption, centauri
   core/wifi/bt) from their 7.3 integration base onto asahi-wip-7.2, with
   our 2-cell AIC DT convention.

**First step** (design-only now; hardware later, after the owner releases
the Mac): cherry-pick `j716c/t6050-pcie` + `j716c/t6050-n1` into a
scratch worktree and compile-test them against our config. In parallel,
read the macOS 27.3 install to locate the N1 FTAB. The first hardware
step would be a read-only m1n1 proxy check at handoff: apcie0 port-0 link
state (the link-status offsets are in Aurora's `t6050_pcie_port.c`), and whether ECAM bus 1 dev 0 fn 0 reads 106b:1900.
That shows whether iBoot leaves the N1 powered and linked, or whether we
must sequence SMC gP13 + PERST + training ourselves.

**Optional DT deliverable:** `dt/t6050-n1.dtsi`, all `status = "disabled"`.
It takes ADT values in Aurora's J716c layout and compiles W=1 clean as a
separate test DTB (`t6050-j716s-n1test.dtb`) in `/Volumes/linux-cs/wt-wireless`.
`t6050-j716s.dtb` is untouched. Nothing binds `apple,t6050-pcie` in our
tree. It is a reference, not something to boot.

## 3. The practical fallback: USB dongles (main deliverable)

### Constraints that shape the choice
- **Host port:** only dwc3_1 (left-front) becomes host, and only with the pending
  `t6050-j716s-usbhost.dtb`. It runs **USB 2.0 HS only** (USB2-only PHY driver, `maximum-speed = "high-speed"`), so
  expect roughly 250-300 Mbit/s whatever the dongle's Wi-Fi generation.
- **VBUS** is not switched on in milestone 1a, so a bus-powered dongle may see 0 V until 1b (PD controller).
- **Hot-plug** is unreliable (eUSB2 repeater re-sync). Plug in before boot.
- **No modules:** everything =y. Built-in drivers probe at about 6 s,
  before the root mounts at about 13.5 s. With no firmware at that moment,
  mt7921u fails its MCU init for good, btusb setup fails, and cfg80211
  falls back to the world regdomain. So **the firmware must be embedded
  (`CONFIG_EXTRA_FIRMWARE`) or in the initramfs**. The loader calls
  `wait_for_initramfs()`, and omarchy's `mkinitramfs.py --firmware`
  already packs a `lib/firmware/` tree. Root-only firmware needs a
  replug, which is exactly what is fragile.
- **One host port:** the Ethernet adapter and the dongles share it, which
  argues for a Wi-Fi+BT combo dongle, or a powered USB 2.0 hub once VBUS
  works.

### Vetted list (driver IDs checked in asahi-wip-7.2 @ 236788cd2; maturity per morrownr's lists, updated 2026-05-08 and 2026-05-17)

| Tier | Product examples (US retail) | Chipset (USB ID) | Driver (CONFIG) | Firmware | Notes |
|---|---|---|---|---|---|
| **Wi-Fi first choice** | ALFA AWUS036AXML (also has BT), EDUP EP-AX1672, Panda PAU0F, BrosTrend AX9L, Fenvi FU-AX1800 (rtl8852bu lookalikes exist) | MediaTek MT7921AU/AUN (0e8d:7961) | mt7921u (`MT7921U`) | `mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin`, `mediatek/WIFI_RAM_CODE_MT7961_1.bin` | Wi-Fi 6/6E, single-state, in-kernel since 5.18, AP mode. Recommended by morrownr |
| same, non-standard IDs | Netgear A8000 (0846:9060), Netgear A7500 (0846:9065), TP-Link Archer **TXE50UH** (35bc:0107; *not* TX50UH) | MT7921AU(N) | mt7921u | same | IDs present in this tree's `mt7921/usb.c` |
| Wi-Fi 7 (no gain on USB2) | Netgear A9000 (0846:9072), A8500 (0846:9050) | MT7925 USB | mt7925u (`MT7925U`) | `mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin`, `..._RAM_CODE_MT7925_1_1.bin` | IDs present; expensive |
| Realtek Wi-Fi 6/6E/7 (second choice) | single-state RTL8832BU / RTL8832CU adapters | RTL8832BU/8852BU, RTL8832CU/8852CU, RTL8851BU, RTL8922AU | rtw89 USB (`RTW89_8852BU/8852CU/8851BU/8922AU`) | `rtw89/rtw8852b_fw*.bin`, `rtw8852c_fw*.bin`, `rtw8922a_fw*.bin` | Young: in-kernel since 6.17 / 6.19; 8922AU landed after May 2026 (present here). Multi-state units need usb_modeswitch. morrownr: 8832xx recommended, 8852xx (BT-enabled) not |
| Wi-Fi 5 | ALFA AWUS036ACM, Panda PAU0D (MT7612U); ALFA AWUS036ACHM, Panda PAU0B (MT7610U, USB2) | MT7612U / MT7610U | mt76x2u / mt76x0u | `mt7662.bin` (=> mediatek/), `mt7662_rom_patch.bin`, `mediatek/mt7610u.bin` | Very mature, but AC only |
| **Wi-Fi safe fallback** | ALFA AWUS036NHA, TP-Link TL-WN722N **v1 only** (v2/v3 are RTL8188EUS -> rtl8xxxu) | Atheros AR9271 (0cf3:9271) | ath9k_htc (`ATH9K_HTC`) | `ath9k_htc/htc_9271-1.4.0.fw` (open source) | 2.4 GHz N150, rock solid, open firmware |
| **BT first choice** | TP-Link UB500 (2357:0604), ASUS USB-BT500 (0b05:190e), generic RTL8761BU (0bda:8771, 2550:8761) | Realtek RTL8761BU | btusb + btrtl (`BT_HCIBTUSB`, `BT_HCIBTUSB_RTL`, `BT_RTL`) | `rtl_bt/rtl8761bu_fw.bin` (config optional) | BT 5.0 LE/BR-EDR; all IDs in this tree's btusb table |
| BT from combos | AWUS036AXML (MT7921AUN BT), RTL8852BU/CU combos | MT7961 BT / RTL8852B/C BT | btusb + btmtk / btrtl | `mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin`; `rtl_bt/rtl8852bu_fw.bin`, `rtl8852cu_fw.bin` | morrownr: combos "can be problematic" |
| **BT safe fallback** | genuine CSR8510 A10 (0a12:0001) | CSR BlueCore | btusb | none | Fake clones are common (btusb has workarounds) |
| Avoid | cheap "BT 5.3" dongles | Actions ATS2851 (10d7:b012), Barrot (33fa:*) | btusb quirks only | n/a | Partial support |

I can't verify availability "sold in the US today" from here: product
names come from morrownr's 2026 lists and the kernel ID tables, not from
store checks.

### Kernel config: `configs/omarchy-wireless-dongles.config` (all =y)
Wi-Fi core is `RFKILL`, `CFG80211`, `MAC80211`, signed regdb. RFKILL
must be =y because cfg80211 and BT depend on `RFKILL || !RFKILL`, and
RFKILL=m caps them at m. Drivers: `MT7921U MT7925U MT76x2U MT76x0U
MT7601U RTW89_8851BU/8852AU/8852BU/8852CU/8922AU
RTW88_8821CU/8822BU/8822CU/8812AU/8821AU/8814AU RTL8XXXU ATH9K_HTC`.
Firmware loader: `FW_LOADER_COMPRESS` with ZSTD and XZ. The crypto set
iwd checks at startup (`USER_API_HASH/SKCIPHER`, HMAC, CMAC, MD4/MD5,
SHA1/256/512, AES, ECB, CBC, DES, `KEY_DH_OPERATIONS`, X.509/PKCS7/PKCS8
for EAP-TLS) comes from iwd `src/main.c`. Bluetooth: `BT BT_BREDR BT_LE
RFCOMM BNEP HIDP BT_HCIBTUSB(_MTK/_RTL/_BCM) BT_MTK BT_RTL BT_BCM
BT_INTEL UHID UINPUT`.
`configs/omarchy-wireless-embed-fw.config` is optional:
`CONFIG_EXTRA_FIRMWARE` for MT7921 Wi-Fi+BT, RTL8761BU and
regulatory.db{,.p7s}, about 1.5 MB, from
`EXTRA_FIRMWARE_DIR=~/Work/agents/wireless/fw-staging`, which
`scripts/stage-wireless-fw.sh` fills.

**Checks done:** every symbol exists in this tree, except `RTW88_8811CU`,
which does not exist; the 8811CU is handled by `RTW88_8821CU`. I merged
the current omarchy `.config` + `omarchy-usb-host.config` + this fragment
with `merge_config.sh` + `olddefconfig` in a scratch `O=` directory, using
my worktree with the main tree's local diff mirrored, not the main tree.
Results:
- All fragment lines land exactly, and the selected cores come in:
  MT76_USB, MT792x_USB, RTW89_USB, RTW88_USB, ATH9K_HW, CRYPTO_ECDH/CCM/GCM.
- No previously =y symbol drops, and 114 symbols become =y.
- With the embed fragment, `drivers/base/firmware_loader/`,
  `drivers/net/wireless/{mediatek,realtek/rtw89,realtek/rtw88,realtek/rtl8xxxu,ath}/`,
  `drivers/bluetooth/` and `net/{wireless,mac80211,bluetooth,rfkill}/`
  all compile clean with LLVM. These were single targets, -j8, with no
  vmlinux, and the six `*.gen.o` firmware objects were produced.
- `PHY_APPLE_USB2` from the USB fragment is absent because that patch is
  pending, which is expected.

**Build-script trap:** `scripts/build-kernel.sh` only regenerates
`.config` when a `REQUIRED_Y` symbol is missing, so new fragments are
silently ignored on an existing tree. README step 2 adds wireless symbols
to `REQUIRED_Y` (or you delete `.config` once).

### Userspace (ALARM, `packages.txt`)
- `wireless-regdb`, plus `linux-firmware-{mediatek,realtek,atheros}`.
  ALARM's linux-firmware 20261019-1 (built 2026-11-01) is a meta package
  over these splits
  ([archlinuxarm.org](https://archlinuxarm.org/packages/aarch64/linux-firmware)),
  and its PKGBUILD uses plain `make install` (uncompressed) + `dedup`.
- `iwd` (recommended, with `EnableNetworkConfiguration=true`), `iw`,
  optionally NetworkManager with the iwd backend.
- `bluez`, `bluez-utils`, `usb_modeswitch` (multi-state Realtek only),
  `usbutils` (lsusb is missing on the root today).
- Note: `mkrootfs-image.py` drops `usr/lib/firmware/`, so after re-imaging
  the root you must reinstall the firmware packages.

## 4. Sequencing / port dependency
1. Validate the USB-host DTB: left-front enumerates a keyboard or stick,
   the gadget ports still carry 10.55.0.2, VBUS is measured. This is the
   gate.
2. Build the kernel with `omarchy-usb-host.config` +
   `omarchy-wireless-dongles.config` + (recommended)
   `omarchy-wireless-embed-fw.config`, or ship the firmware in the
   initramfs.
3. Plug the dongle (or combo/hub) into the left-front port before boot,
   then install the packages and bring up iwd/bluetoothd.
4. Thunderbolt/USB-C dock Ethernet carries the same dependency: on this
   host it can only work through the dock's USB 2.0 fallback hub. There
   is no USB3/USB4/TB/DP on T6050 in our tree, so a TB3-only dock will not
   enumerate at all. Expect a USB4/TB4 dock's USB NIC (RTL8153/8156 ->
   r8152) at HS speed.

## Verified / inferred / unknown
**Verified (ADT, source, build):**
- N1 node layout, port/DART/IRQ/GPIO/SMC-key/power-gate values above;
  the ADT names no Wi-Fi/BT firmware; no exclave mapper or reference to
  the N1 path.
- Aurora's driver files, PCI IDs, FTAB magic, protocol 27, feature scope
  and dates.
- Every CONFIG symbol, driver USB ID and firmware filename (against
  `request_firmware`/`MODULE_FIRMWARE` and linux-firmware 703a4d9).
- The olddefconfig merge, clean compiles of every wireless/BT/fw_loader
  directory, the EXTRA_FIRMWARE objects, and the disabled N1 test DTB
  (W=1).
- ALARM firmware packaging.

**Inferred:**
- alpha = Wi-Fi, beta = BT. This follows from the ADT MAC/BT nodes plus
  Aurora's IDs.
- The ADT `msi-vector-offset` is an AIC IRQ base; Aurora uses 1888/64.
- PERST is active-low by analogy with M1 (same ADT flag 0x0).
- `proxima` is the press codename for the N1.
- A dock NIC works through the USB2 fallback.
- Throughput of about 250-300 Mbit/s on the USB2 host.

**Unknown:**
- Whether iBoot leaves apcie0 port 0 trained and the N1 powered at
  handoff on J716s.
- The J716s board ID for `apple,centauri-platform-id`.
- Where macOS keeps the personalized FTAB, and whether it is per-unit.
- Whether `spmi-wifibt` (AOP SPMI) must be touched to power the N1.
- The role of `/sacm` SACC.
- Whether Aurora's N1 stack has associated on real hardware: their docs
  say qualification is pending.
- Whether VBUS is present on the host port in milestone 1a.
- Retail availability of the listed dongles today.

## Files (~/Work/agents/wireless/)
- `REPORT.md`, `README.md` (install steps), `firmware-files.txt`, `packages.txt`.
- `configs/omarchy-wireless-dongles.config`, `configs/omarchy-wireless-embed-fw.config`.
- `scripts/stage-wireless-fw.sh`, plus `fw-staging/`, which it already filled from linux-firmware.
- `dt/t6050-n1.dtsi` (disabled; reference only).
- `ref/` is read-only: aurora-linux sparse clone with extracted sources in
  `ref/aurora-src/`, a linux-firmware tree listing, wireless-regdb, iwd.
- Worktree `/Volumes/linux-cs/wt-wireless`, detached at 236788cd2, has the
  main tree's local diff mirrored, plus `t6050-n1.dtsi`,
  `t6050-j716s-n1test.dts` and a Makefile line. Scratch build output is in
  the session scratchpad. Nothing was committed, and neither the main
  tree, the other worktrees, omarchy-m5 nor the Mac were touched.
