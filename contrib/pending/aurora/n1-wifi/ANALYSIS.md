# N1 Wi-Fi/Bluetooth on the J716s (T6050) under the Aurora kernel

Studio-only work: nothing here was booted. Sources read: PR #937 (`aurora/pr-937-pcie`), PR #938
(`aurora/pr-938-n1`), PR #945 (`t6050-j716c.dts`), Aura main plus every Aura branch and PR ref
(including funkzy/aura), erikwb's public repos, the J716s ADT
(`~/Work/studio-artifacts/adt-runtime-j716s.bin`), the redacted macOS scan
(`~/Work/m5scan/redacted/03-wireless-n1.txt`) and fixed8. ADT extracts come from
`tools/adt-n1.py`, `tools/adt-node.py` and `tools/adt-phandles.py`. They print no MAC, serial or
calibration values.

## 0. Short answer

* **Who trains port 0 on J716c:** Aurora's boot loader, not iBoot. The PR #945 DT says "The boot loader
  trains the link after the SMC releases the N1's reset ... Disabled with its DART until the boot
  loader trains it, which also renumbers the bus". PR #937's commit says "the bootloader *now*
  trains [port 0] like ports 2 and 3". Ports 2 and 3 on J775D are trained by Aura's
  `src/pcie_t6050.c`: Aura PR #60/#61 (closed, never merged), whose PR text says "iBoot leaves apcie0's
  GP side powered down". That file trains ports 2 and 3 only. The port-0 variant, the N1 reset
  release and the FTAB are on no public branch: not in aura (all 93 PR refs and every branch were
  grepped), funkzy/aura, erikwb/m1n1, aurora-silicon/m1n1 or erikwb/linux. The FTAB on Erik's
  machine is described only as "Personalized FTAB including the required per-device calibration"
  (PR #938 binding). Its source is not published. Most likely it came from that machine's macOS
  install, as ours did.
* **J716s:** the ADT has no sign that iBoot trains port 0. `IOPCIConfigured`, `IOPCIExpressLinkStatus`
  and the rest are runtime IOKit properties that macOS's own PCI driver sets after it brings the
  port up. pci-bridge0 carries `manual-enable` (the OS enables the port). Read it as iBoot = cold,
  as on J775D. m1n1 0022 prints the real register state at the next boot (stage 0 in
  R3-W-RECIPE.md), with reads only.
* **Realistic:** DT-only (0022) is complete and safe, but by itself it brings nothing up. Wi-Fi needs the
  port-0 training (0023, the Aura sequence ported, behind `chosen.m5pro,n1`). It is unmeasured on
  J716s and has three open unknowns: whether iBoot leaves the PERST# pad output-low, whether the N1
  must first be released through SMC `gP13`, and whether our FTAB is acceptable to the ROM (2.3).

## a. What PR #937 expects from the boot loader

`apple,t6050-pcie` → `t6050_hw` (`adopt_link`). The probe (`pcie-apple.c` in wt-n1, from
`apple_pcie_probe` on) does this. Each line is a refusal condition. Every check runs before the
first PCIe write.

DT (host):
* `reg-names` `config`, `rc`, `port<n>`, `phy<n>`, `intr2axi<n>`; `interrupt-names` `port<n>`.
  **No `power-domains`** on the host (`-EINVAL`). It needs at least one *available* child, so with
  port 0 disabled the host returns `-EINVAL` before any MMIO (safe).
* `msi-ranges = <&aic 0 0 1888 IRQ_TYPE_EDGE_RISING N>` with N 32 or 64, `apple,msi-vector-base = <64>`,
  and `CONFIG_PCIE_APPLE_MSI_DOORBELL_ADDR=0xfffff000`. Anything else is `invalid_slice`.
* `iommu-map` entry for the endpoint RID → an `apple,t6050-dart`, one cell, SID nonzero and < 64.
  The RID2SID slot index is the SID. The RID must be on the bus the loader numbered.
* `bus-range` starting at 0.

DT (root port `pci@<n>,0`, n = 0..3):
* `apple,link-trained-by-bootloader`, no `pwren-gpios`.
* `reset-gpios` (optional): only a port that needs a root-port reset names it. The N1 needs it,
  for its post-ROM retrain. It is taken `GPIOD_ASIS` through the pin controller, so
  **`CONFIG_PINCTRL_APPLE_GPIO` must be `y`**. Today it is `m` with no modules built, and the host
  would defer forever.
* Optional tunables, replayed only by the root-port reset, each as `(offset, 4, mask, value)`
  groups (at most 16): `apple,apcie-config-tunables` (port block, offset < 16 KiB) and
  `apple,pcie-rc-tunables` / `apple,pcie-rc-gen{3,4,5}-shadow-tunables` (root port config space,
  < 4 KiB). If absent, they are skipped silently. The retrain then runs without Apple's values.

Register state at probe (`apple_pcie_adopt_link`):

| where | must be |
|---|---|
| rc + 0x50 / + 0x58 | RUN bit 0 / READY bit 0 |
| port + 0x804 | READY bit 0 |
| port + 0x208 | link UP (bit 0) and not BUSY (bit 2) |
| port + 0x080 | LTSSM start bit 0 |
| port + 0x800 | `& 0x101 == 0x101` (app clock on) |
| port + 0x82c | `& 0x10001 == 1` (internal reset released) |
| phy + 0x000 | `& 0x1000061f == 0x60f` (lane clocks requested and acked, bits 9/10, not 4/28) |
| 00:n.0 config | ID `0x100c106b`; primary 0, secondary = subordinate = bus ≠ 0 and ≤ host end; no bus reset |
| bus:00.0 | present, header type 0, COMMAND IO/MEM/MASTER clear, MSI or MSI-X present and disabled, sane capability chain |
| link | x1, not training, Gen1..Gen3 (the N1 ROM links at Gen1) |
| port + 0x3000.. | no valid RID2SID entry |

These are exactly the states Aura's stages C-G leave (and m1n1 0023 reproduces). There are no other
`apple,*` hand-off properties, no `memory-region`, and no `iommus` on the endpoints. On adoption it routes
RID 0x100 → SID 1 and then logs `adopted port 0, endpoint 01:00`. The N1's other functions are routed
when they appear. After the ROM boot, centauri calls `host->reset_root_port`: PME_Turn_Off, PERST#
through the GPIO, then port disable/reset/enable/configure/train, and logs `port 0: link retrained
after a root-port reset`. It retrains from Linux, so the boot loader only has to do the first
training.

**Does mBoot/iBoot leave apcie0 port 0 trained on J716s?** There is no evidence that it does, and there is evidence against it:
* ADT `pci-bridge0`: `manual-enable`, `keep-root-port-on`, `centauri-builtin`, `t-refclk-to-perst = 100`,
  `perst-to-config = 100`, `function-perst = GPIO 80`, `function-clkreq = GPIO 76`,
  `function-reset = pKW4(gP13, 0x00800000)` (SMC), `function-warm_reset = pKW4(bpli, 0x01000000)`.
  These are what an OS driver needs to bring the port up itself.
* The scan's `IOPCIConfigured = Yes`, bridge `IOPCIExpressLinkStatus = 0x3013` (DLL active, Gen3 x1) and
  endpoint `0x1013` are macOS run-time state after `AppleT6050PCIePort` trained it. The adt-runtime
  dump has none of them.
* J775D (same SoC, same apcie0 layout of 40 reg entries) is documented cold (Aura PR #60).
* The sibling port 1 (SD reader) has `IOPCIExpressLinkStatus = 0xffff` and is powered off in macOS.

## b. What the centauri drivers need at probe (PR #938 versions, now in patches/kernel-n1)

Integration's own `drivers/net/wireless/apple/centauri` is a **different driver**: J813/J873 only, a
board table keyed by `of_machine_is_compatible("apple,j813"/"apple,j873g")`, no DT firmware-name.
`btcentauri` there refuses any other machine. It cannot bind on J716s. PR #938 replaces it
(patches 0008-0016).

Control function 0 (`apple_centauri`, 106b:1900/1901):
* The host must be `apple,t6050-pcie`. Function 0 only.
* `firmware-name` (string), `apple,centauri-platform-id` (u32, written to BAR0+0x807c before the ROM
  boot), `apple,centauri-protocol = <27>` (anything else is `-EINVAL`).
* BAR0 must be ≥ 0x9080 bytes, and 40-bit DMA must be available.
* BAR0+0x8000 must read 0 (stopped ROM stage). Otherwise `-EBUSY`.
* `request_firmware_direct(firmware-name)`: `rkosftab` at 0x20, 0x30 B..64 MiB. It needs no other
  file and no `.im4m`.
* ROM boot: image response 1, then stage 4; then `centauri_port_cycle` (needs `reset_root_port`,
  i.e. reset-gpios); then IPC, which brings up Alpha (106b:1902) and Beta (106b:1903).

Wi-Fi (Alpha, function 1): `local-mac-address`. cfg80211 only (no mac80211). The interface is `wlan%d`.
Bluetooth (Beta, function 2, `btcentauri`): `local-bd-address` (LSB first, as m1n1 fills
`bluetooth0`), else `local-mac-address`.

No `memory-region`, `iommus` or `apple,*` hand-off on the functions: DMA goes through the host's
`iommu-map` (DART stream 1/2/3 for functions 0/1/2). The N1 is cold (ROM stage 0) when Linux takes
it, so no iBoot carve-out is involved.

### 2.3 Firmware

`ftab.bin` (about 31 MB) is a valid FTAB: `rkosftab`, 83 entries (`rkos`, `rkol`,
`aciw`, `acib`, `acim`, `bt*`, `w*`, `2ftb`, `ccaf`, ...). The header words at 0x08-0x1f are all
zero. No entry is a ticket, and the only `IM4M` bytes are inside the `rkos` image. The three
`centauri.j716sap{,.dev,.insecure}.im4m` are separate 7772-byte IM4M manifests. So either:
* the per-unit part is already in this file (for example `ccaf`), and the ROM accepts it as is; or
* the ROM wants the manifest stitched in, and "personalized FTAB" means exactly that.

The driver passes only the FTAB. The ROM's verdict shows as `image_response`. A value other than 1
gives `N1 automatic startup failed in phase0: -5`.

## c. What m1n1 must do

### DT fill-in only: patch 0022 (`kboot_n1.c`), always active, safe

| item | how | status / risk |
|---|---|---|
| `firmware-name = "apple/centauri/j716s-ftab.bin"` | ADT `target-type`, lower case | done. fixed8 already has the same static string. No risk |
| `apple,centauri-platform-id = 0x000c6050` | ADT `/chosen board-id` (12) << 16 \| `chip-id` (0x6050) | done (fixed8 has the same). No risk |
| `apple,centauri-protocol = 27` | set if absent | done. No risk |
| `local-mac-address` / `local-bd-address` | existing `dt_set_mac_addresses()`, ADT `mac-address-wifi0` / `-bluetooth0` through the `wifi0`/`bluetooth0` aliases (BT byte-swapped) | already in m1n1. fixed8's placeholders are zero |
| root-port tunables (5 lists) | ADT pci-bridge0 24-byte records → `(off, 4, mask, value)` | done. They are needed for a good post-ROM retrain |
| enable `pci@0,0` + `dart_apcie0` | only if port 0 is up as the adoption needs it (reads, plus bus numbering) | done. Otherwise both are forced to `disabled`, which avoids the DART SError Aura saw on untrained ports |
| memory reservations | none needed: the N1 is cold, and the driver allocates the FTAB DMA buffers itself | n/a |

Side effect: `dt_set_bluetooth()` adds `brcm,*-cal-blob` from `/arm-io/bluetooth` to the Beta node.
btcentauri ignores it.

### Hardware work: patch 0023 (`pcie_t6050.c`), only with `chosen.m5pro,n1=1|2`

| step | source | risk |
|---|---|---|
| A: check GPIO/APCIE_GP/FAB6_SOC/APHY_GP_AUS5_A active; raise APCIE_SYS_GP, APCIE_PHY_SW (non-virtual one), APHY_GP_AUS5 | Aura, J716s PMGR has the same names | medium: a keep-domain off → clean stop |
| A: PERST# (gpio0 pin 80) must be output-low | Aura check | unknown on J716s → clean stop if not |
| S: shared GP PHY: AUS5 AON, axi2af tunables (78 records), lane-cfg 0, phy tunables, Gen5 PHY start, RC run | Aura, J716s tunables present | **highest**: shared with storage (ANS on APCIE_ST*). Storage is snapshotted before and after; a change stops the training, but cannot be undone, so the boot may then lose NVMe |
| optional SMC `gP13 <- 0x00800001` (N1 reset release) | ADT function-reset; value format as `dcp.c`'s pKW4 power GPIOs | polarity is a guess; m1n1 SMC init/shutdown on T6050 is untested → only with `=2` |
| B-E: port reset table, config tunables, app clock/reset handshake, Gen3 x1 DBI policy, lane clocks, PERST# release, LTSSM, link up within 500 ms | Aura (measured on J775D port 2) | medium: N1 ROM may need the reset release first (then use `=2`) |
| F-G: bus 1, endpoint 106b:1900/1901, RID2SID empty, endpoint command clear, DART untouched | Aura + N1 IDs | low |
| CLKREQ# (GPIO 76) | not touched; the endpoint drives it | low |
| clock/power gates beyond the GP closure | none: ADT `clock-gates`/`power-gates` of apcie0 are the same PMGR devices | low |

Not implemented: the warm-reset path (`bpli`) and port 1 (SD reader).

## d. ADT vs PR #945 / fixed8 node

| item | J716s ADT | fixed8 (= J716c shape, J716s values) | match |
|---|---|---|---|
| config (ECAM) | apcie0 reg[0] 0x1cb0000000 / 0x10000000 | `config` 0x1c_b0000000 0x10000000 | yes |
| rc | reg[1] 0x414000000 / 0x4000 | `rc` 0x4_14000000 0x4000 | yes |
| port0 | reg[16] 0x410028000 / 0x8000 | `port0` 0x4_10028000 0x8000 | yes |
| phy0 (lane) | reg[18] 0x417010000 / 0x4000 | `phy0` 0x4_17010000 0x4000 | yes |
| intr2axi0 | reg[19] 0x410024000 / 0x4000 | `intr2axi0` 0x4_10024000 0x4000 | yes |
| port IRQ | interrupts[0] 1523 | `<AIC 0 1523 HIGH>` (0x5f3) | yes |
| DART | dart-apcie0 0x210000000 (→ 0x410000000 via arm-io ranges), IRQ 1524, `dart,t8110`, sid-count 19, bypass 16-18 | `iommu@410000000`, IRQ 0x5f4, `apple,t6050-dart` | yes |
| iommu-map | mappers control/alpha/beta (no SID in ADT) | `<0x100 &dart 1 3>` (RID 01:00.0-2 → SID 1-3) | as J716c; SIDs 1-3 are free (bypass is 16-18) |
| MSI | `msi-address 0xfffff000`, offset 1824, 128 vectors; bridge0 base 0, bridge1 base 32 | `msi-ranges <aic 0 0 1888 rise 64>`, `apple,msi-vector-base 64` | Linux's slice = vectors 64-127 of the 128, as on J716c. The kernel requires exactly this |
| ranges | `0x43000000 0xb_c0000000` 512 MiB pref + `0x02000000 0xb_80000000` 1 GiB | same | yes (macOS put the N1 BARs at 0xb82000000/0xb84020000, inside) |
| bus-range | <0 8> | <0 4>, port <1 1> | fine (kernel needs start 0, bus 1 ≤ end) |
| PERST# | function-perst GPIO 80 of gpio0 (0x29c000000) | `reset-gpios <&pinctrl_ap 80 ACTIVE_LOW>`, reserved ranges <0 80> <81 140> | yes |
| control fn | centauri-control 106b:1901 at runtime (1900 in ROM) | `pci106b,1900` | yes (driver takes both) |
| firmware-name / platform-id / protocol | target-type J716s, board-id 12, chip 0x6050 | `j716s-ftab.bin`, `0xc6050`, `0x1b` | yes |
| MACs | `/chosen mac-address-wifi0/-bluetooth0` (alpha also has local-mac-address) | zero placeholders | m1n1 fills |
| tunables on port | pci-bridge0 config/rc/gen3-5 shadow | none | **missing** → fixed9 adds them, and 0022 writes them anyway |

fixed9 (`mk-fixed9.py`) = fixed8 + the five `apple,*-tunables` lists on `pci@0,0`. Nothing else
needed changing: fixed8 already carried the J716s N1 node with zero MAC placeholders. The fixed9 DTB is
`dt/t6050-j716s-typec-fixed9.dtb`. Both stay private.

## e. Kernel patches (patches/kernel-n1, 16 files)

0001-0007 = PR #937 (two binding conflicts resolved: the T8152 `if/else` chain gained the T6050
branch; driver hunks identical by `git range-diff`). 0008-0016 = PR #938. Integration's J813/J873
N1 driver files are replaced by the PR's at each commit (`tools/pick938.sh`); the Bluetooth
Kconfig/Makefile swap `BT_CENTAURI` for the PR's `BT_HCICENTAURI`. The series applies in sequence on
6d9f1ec652a6 and gives tree 1cb07efad68b, identical to wt-n1 HEAD. Not built, not compile-tested.
