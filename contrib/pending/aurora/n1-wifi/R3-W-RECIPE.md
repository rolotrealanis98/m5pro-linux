# R3-W: N1 Wi-Fi/Bluetooth on the Aurora kernel (kernel rebuild needed)

You build the kernel. I built only the m1n1 binaries, the DTB and the initramfs, and booted nothing.
Do the steps in order: **W0** (reads only) before **W1** (trains the port), and **W2** only if W1
stops at link-up.

## 0. Before booting: root setup
Do ROOT-SETUP.md §1 (firmware on the root) and §2 (iwd, no change to `20-wired.network`) first.
The payload's initramfs also carries the FTAB, so the root copy is only needed for rebinds.

## 1. Kernel (`/Volumes/linux-cs/wt-aurora`, branch aurora-j716s @ 6d9f1ec652a6)
```
cd /Volumes/linux-cs/wt-aurora
git log --oneline -1            # 6d9f1ec652a6 power: supply: macsmc-power: read battery identity strings ...
git am ~/Work/agents/n1-wifi/patches/kernel-n1/00*.patch          # 16 patches
scripts/config --file .config -e RFKILL -e PINCTRL_APPLE_GPIO -e CFG80211 \
    -e APPLE_CENTAURI -e APPLE_CENTAURI_WIFI -e BT -e BT_LE -e BT_HCICENTAURI -e MTD_PHRAM
make ARCH=arm64 LLVM=1 olddefconfig
grep -E '^CONFIG_(RFKILL|PINCTRL_APPLE_GPIO|CFG80211|APPLE_CENTAURI|APPLE_CENTAURI_WIFI|BT|BT_HCICENTAURI|PCIE_APPLE|APPLE_DART|MTD_PHRAM)=y$' .config | wc -l   # must print 10
grep -E '^CONFIG_PCIE_APPLE_MSI_DOORBELL_ADDR=0xfffff000$' .config
```
Then build `Image.gz` with the same make variables as for R3-R.

| symbol | today | R3-W | why |
|---|---|---|---|
| `PCIE_APPLE` | y | y | host (PR #937 adds `apple,t6050-pcie`) |
| `PCIE_APPLE_MSI_DOORBELL_ADDR` | 0xfffff000 | same | the adoption refuses any other value (ADT `msi-address` is 0xfffff000) |
| `PCIE_APPLE_MSI`, `PCIE_APPLE_T8140_BOOTSTRAP` | n, y | unchanged | not used on T6050 |
| `APPLE_DART` | y | y | `dart_apcie0` |
| `PINCTRL_APPLE_GPIO` | **m** | **y** | port 0 `reset-gpios`. With `m` and no modules, the host defers forever |
| `RFKILL` | **m** | **y** | `CFG80211` and `BT` cannot be `y` while RFKILL is `m` |
| `CFG80211` | m | y | centauri is a cfg80211 (fullmac) driver. `MAC80211` can stay `m` |
| `APPLE_CENTAURI` / `APPLE_CENTAURI_WIFI` | m / – | y / y | PR #938 control + Wi-Fi |
| `BT` / `BT_LE` / `BT_HCICENTAURI` | m / n / – | y / y / y | PR #938 renames integration's `BT_CENTAURI` to `BT_HCICENTAURI`. `BT_LE` is for LE devices |
| `MTD_PHRAM` | m | y | exposes m1n1's log as `/dev/mtdN` (`m1n1_stage2.log`): the m1n1 lines below |
| `FW_LOADER` | y | y | `request_firmware_direct()`. `FW_LOADER_COMPRESS` stays off |

* Patches 0001-0007 are PR #937 and 0008-0016 are PR #938. They apply in sequence on 6d9f1ec652a6, and the
  result equals `/Volumes/linux-cs/wt-n1` (branch `n1-wifi`, tree 1cb07efad68b). They are not
  compile-tested: if 0008-0016 fail to build, build 0001-0007 alone first. That still gives the
  `adopted port 0` line with W1.
* 0008 removes integration's J813/J873 N1 driver (`centauri_port.c`, the board table). This kernel is
  for J716s only.

## 2. Payloads
```
python3 -I ~/Work/agents/n1-wifi/mk-initramfs-n1.py   # already done; prints caec8090...
python3 -I ~/Work/agents/n1-wifi/mk-fixed9.py         # already done; prints edac01e0... for the DTB
python3 -I ~/Work/agents/n1-wifi/mk-r3w.py probe      # R3-W0
python3 -I ~/Work/agents/n1-wifi/mk-r3w.py train      # R3-W1
python3 -I ~/Work/agents/n1-wifi/mk-r3w.py train-smc  # R3-W2
```
Layout as R3-R: m1n1 (0x400000), then a `chosen.bootargs=` line, `chosen.asahi,show-notch=1`, for
W1/W2 `chosen.m5pro,n1=1|2`, then Image.gz, the DTB and the initramfs. The script refuses a kernel
without the strings of 0003/0006/0008/0010/0015 or without built-in pinctrl.

| input | path | sha256 |
|---|---|---|
| m1n1 W0 (pipe-park-atc + 0022, v2.0.0-74-g0bc8917e) | `~/Work/agents/n1-wifi/build/m1n1-plain-n1-dt.bin` | 7621429bcd5716ad6443f131241d4cb9a3a54b6bfa7181da71390f9499a83914 |
| m1n1 W1/W2 (+ 0023, v2.0.0-75-g119168fa) | `~/Work/agents/n1-wifi/build/m1n1-plain-n1-train.bin` | d31e5248fed273fdb4fd81cdb08bd007f82fc0df7e953e6ffb75434ba6a3deae |
| kernel | `/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz` (rebuilt) | printed by the script |
| DTB (fixed8 + port-0 tunables) | `~/Work/agents/n1-wifi/dt/t6050-j716s-typec-fixed9.dtb` | edac01e04e254eb9bbc18b0a1332bb753357816d70bfc5ab186559275479e969 |
| initramfs (selftest + FTAB) | `~/Work/agents/n1-wifi/payloads/initramfs-selftest-n1.cpio.gz` | caec8090b12f54614bc36bf652edfe55a944ddd52d07cb8b7a6a306d4c69e78a |

Bootargs (as R3-R):
```
earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 initcall_blacklist=macsmc_power_driver_init m5.selftest=1
```
* m1n1 build: `~/Work/agents/n1-wifi/build.sh` (m1n1-r2 recipe). `pipe-park-atc` reproduces pipe-park's
  5ef3c0dc..., and both N1 images are exactly 0x400000. 0023 first came out at 0x410000 (the
  rodata+rela window); its strings were trimmed until it fit.
* The payloads and the initramfs carry the per-unit FTAB. Keep them on the ESP and in
  `~/Work/agents/n1-wifi/payloads/` only.

## 3. What proves each stage

Read the m1n1 log after boot: `cat /proc/mtd`, then `strings /dev/mtdN` for the `m1n1_stage2.log`
entry (16 KiB ring). Also read `/proc/device-tree/pcie@1cb0000000/pci@0,0/status`.

**W0 (no training), the answer to "does iBoot leave port 0 trained?":**
1. m1n1: `n1: control function: firmware-name apple/centauri/j716s-ftab.bin, platform-id 0x000c6050`
2. m1n1: `n1: port 0: rc ctl 0x.. stat 0x.., port status 0x.. linksts 0x.. ltssm 0x..`. **Copy this
   line to me.** linksts bit 0 = 1 means iBoot trained it.
3. m1n1: `n1: port 0 not up: root port and DART disabled` (expected), then in the kernel
   `apple-pcie 1cb0000000.pcie: probe with driver apple-pcie failed with error -22` (no available
   port, nothing touched). No DART probe for 410000000. The rest boots as R3-R.
   If line 2 shows the link up, you get `port 0 up` and W0 goes on as in W1 step 3.

**W1 (`chosen.m5pro,n1=1`):**
1. m1n1: `n1: chosen.m5pro,n1=1: training apcie0 port 0`, `pcie-t6050: storage before: reference`,
   `storage after A: unchanged|allowed`, `storage after S: ...` (or `shared GP init already in place`).
2. m1n1: `pcie-t6050: port 0 link Gen1 x1` (ROM personality), `pcie-t6050: endpoint 01:00.0 is
   0x1900106b`, `storage after F`, `pcie-t6050: port 0 up, N1 at 01:00`, `n1: port 0 up: root port
   and DART okay`.
3. Kernel PCIe: `apple-pcie 1cb0000000.pcie: port 0: RID 0100 -> SID 1, slot 1`, `adopted port 0,
   endpoint 01:00`, `pci 0000:01:00.0: [106b:1900] type 00 class 0xff0000`, `apple-dart
   410000000.iommu` probe with no fault.
4. Firmware request: no `required firmware ... unavailable` line (it was found in the initramfs).
   ROM boot is silent on success.
5. Port cycle: `apple-pcie 1cb0000000.pcie: port 0: link retrained after a root-port reset`. Then the
   functions appear: `[106b:1901]` on 01:00.0, `[106b:1902]` on 01:00.1, `[106b:1903]` on 01:00.2,
   with `port 0: RID 0101 -> SID 2, slot 2` and `RID 0102 -> SID 3, slot 3`.
6. Alpha (Wi-Fi): `apple_centauri 0000:01:00.0: Wi-Fi firmware channel list: N bytes, capabilities: M
   bytes`, `Wi-Fi firmware channels: 2.4 GHz a, 5 GHz b, 6 GHz c (...)`, then `ip link` shows
   **`wlan0`**. Check `iw dev`, `iw phy | grep -A3 Frequencies`.
7. Beta (Bluetooth): `Bluetooth: hci0: ...` lines from btcentauri, then **`hci0`** in `btmgmt info` /
   `bluetoothctl show`, with the factory address (m1n1 fills `local-bd-address` from the ADT).
8. Pass: `iwctl station wlan0 scan` lists networks, the connect gets a DHCP lease on wlan0
   (ROOT-SETUP.md §2), and `bluetoothctl scan on` sees devices. Three boots in a row.

**W2 (`chosen.m5pro,n1=2`):** as W1, plus before B:
`pcie-t6050: SMC key gP13 <- 0x00800001: 0`.

## 4. Failure signatures

| where / what you see | meaning | next |
|---|---|---|
| m1n1 `STOP: port 0 PERST# is not output-low: 0x...` | iBoot left pin 80 in another mode | send the value. The pad needs configuring before A |
| m1n1 `STOP: <domain> is not active, and it is not ours to raise` | the GP closure differs on J716s | send the line |
| m1n1 `STOP: ... did not come up with auto-PM off` | PMGR raise failed | send the line |
| m1n1 `STOP: shared PHY status 0x...: not cold` / `GP port 1 has a link` | iBoot left the GP PHY half up | send the line (S is refused, nothing written) |
| m1n1 `tunable: ... reads ... wrote ...` + `STOP: ...-tunables: readback differs` | a J716s readback quirk | send the lines (would need a J716s excuse table) |
| m1n1 `STOP: link up: 0x410028208 = 0x... after 500 ms` | the endpoint did not train: N1 most likely still in SMC reset | **W2** |
| m1n1 `STOP: endpoint 01:00.0 is 0x..., not the N1` | wrong device / no device | send the line |
| m1n1 `pcie-t6050: storage after A/S/F: ... -> ...` + `STOP: storage changed` or `NVMe BOOT_STATUS` | GP init disturbed ANS | root mount may fail. Power off, go back to R3-R's payload, send the lines. Do not retry |
| kernel: no `apple-pcie 1cb0000000` line at all; `/sys/kernel/debug/devices_deferred` lists it | pinctrl not built in | `PINCTRL_APPLE_GPIO=y` |
| kernel `Port /pcie@1cb0000000/pci@0,0 probe fail: -22` | pin 80 refused by `gpio-reserved-ranges` | DTB mix-up (fixed9 opens pin 80) |
| kernel `Port ... setup fail: -67` (ENOLINK) / `-19` (ENODEV) / `-16` (EBUSY) | adoption check failed: link/PHY state / bus numbers or endpoint / route or MSI already on | send dmesg and the m1n1 `n1: port 0:` line |
| SError / DART fault at the `410000000.iommu` probe | DART enabled on an unpowered port | should not happen (0022 enables only a live port); send a photo |
| `required firmware apple/centauri/j716s-ftab.bin unavailable: -2` | not in the initramfs (wrong initramfs) | rebind from the root (ROOT-SETUP.md §1) or rebuild the payload |
| `N1 automatic startup failed in phase0: -5` | ROM rejected the image (`image_response` ≠ 1) or did not reach stage 4 | FTAB personalisation (ANALYSIS.md 2.3): needs the im4m stitched in |
| `... phase0: -110` | the ROM never answered: DMA/DART/MSI path | send dmesg incl. DART faults |
| `... phase0: -16` | BAR0+0x8000 ≠ 0: the N1 was not in its ROM stage (W2's SMC write or a warm boot) | cold boot (power off) and retry |
| `... phase1: -95` | no `reset_root_port` (port without reset-gpios) | DTB check |
| `N1 port cycle stopped: N` or `port 0: root-port reset stopped: N` | retrain after the ROM boot failed | send dmesg. The tunables on `pci@0,0` matter here |
| `IPC bootstrap failed: N (Control stage=...)` (+ Alpha/Beta stage lines) | firmware runs, IPC did not come up | send dmesg |
| `Beta driver attachment failed: N` | Wi-Fi fine, Bluetooth not | send dmesg |
| `wlan0` present, scan empty / `failed to load regulatory.db` | regdb not loaded yet | `iw reg get`. Harmless for the first test |

## Rollback
Restore `boot.bin.prev` (R3-R). R3-W changes the m1n1, the kernel, the DTB and the initramfs. The root
changes are undone with ROOT-SETUP.md's rollback. A failed W1/W2 leaves no state across a power cycle.
