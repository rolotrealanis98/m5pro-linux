PCI: apple: train a T6050 root port the boot loader left down (J716s N1)

On the M5 Pro/Max laptops iBoot leaves apcie0 port 0, the N1 Wi-Fi/Bluetooth, untrained: the N1 is held off (SMC GPIO gP13 low, PERST# low), the shared PCIe PHY is in reset with its clocks off, and the port's power states are gated. #937 adopts a port only if the boot loader trained it, so until now Wi-Fi needed a loader that trains the port (on the J716s our m1n1 does, with ANS started for its storage checks and an SMC reset pulse). edimoldovan's J714c tree lets the kernel train the port itself when the adoption checks find the link down and the port names its endpoint's power line; the adoption checks then run unchanged. This brings that work here, with what the J716s (MacBook Pro 16-inch, M5 Pro) needs on top.

Commits:
1. `PCI: apple: T6050 adopted ports: no ASPM, and a shutdown that holds the port` (ed). ASPM stripped from adopted root ports, and a shutdown that parks each adopted port as the boot stage leaves it. Without it the J716s freezes about 30 s after the N1 firmware starts unless `pcie_aspm=off` is set, and a restart with the link alive does not come back. This supersedes the ASPM-only change I had held for #937.
2. `dt-bindings: pci: apple,pcie: Let the OS train a T6050 root port`. `pwren-gpios` on a T6050 root port, the new reg-names and the six host tunable lists.
3. `PCI: apple: T6050 adopt: train a port the boot loader left down` (ed). The shared PHY is brought up (clocked and out of reset), then the RC run bit, PERST# held, the endpoint powered, then #937's port enable, configure and train sequences, then the bus numbers. Root-port configure now reaches the root port through ECAM, because there is no pci_dev before enumeration.
4. `PCI: apple: T6050 cold train: apply the host tunables` (ed). `apple,tunable-{axi2af,cio3pllcore,pcieclkgen,phy,phy-ip-pll,phy-ip-auspma}` in m1n1's order. The `phy` list is what clears lane bit 28, which the adoption checks require.
5. `dt-bindings: iommu: apple,dart: add apple,manual-availability` (ed).
6. `iommu: apple-dart: probe a manual-availability DART after its client` (ed). Merged next to the J713 display-DART checks in `apple_dart_probe()`.
7. `PCI: apple: make an adopted port's DART available` (ed). The DART of a port that is not up takes an SError when probed. With this it can be enabled in the DT and still probe only after the host has the port up.
8. `PCI: apple: T6050 cold train: reset a warm N1, power it off at shutdown`. A restart resets the SoC but not the N1, which keeps running its firmware. The train now holds the power line low for 250 ms (the 50 ms of commit 3 does not reset a warm N1; m1n1 measured 250 ms on the J716s). It takes PERST# and the power line before its first register write, so that a probe deferred for the late SMC GPIO bank leaves the hardware untouched. The link-up wait is 1 s, as m1n1 allows. Shutdown drops the power line after the park when Linux trained the port.
9. `gpio: macsmc: drive the J716s N1 power line with its ADT template`. The J716s ADT gives the N1's power line as pKW4("gP13", 0x00800000), the same descriptor as J713's radio. It is written as `0x00800000 | level`, the write m1n1 uses on this machine, instead of the generic `CMD_OUTPUT` (which the J714c uses).

The J716s DT change goes on top of #1167, because the J716s DT is not in this tree: branch `n1-kernel-train-dt` = #1167 + commit 5 + `arm64: dts: apple: t6050-j716s: let the kernel train the N1's port`. That commit adds the shared PHY, PHY common block and the four tunable windows to pcie0, `pwren-gpios = <&smc_gpio 0x13>` on port00, the SMC's first GPIO bank (gP keys), `apple,manual-availability` on dart_apcie0, and the port's power chain in pmgr1. iBoot leaves APCIE_SYS_GP, APCIE_PHY_SW and APHY_GP_AUS5 in auto-PM with the block gated, the same on the J714c. In that commit they are always on with auto-PM off, rather than genpd-managed as in the J714c tree: the adopted link is kept up through suspend-to-idle, and genpd would power a consumer's domain off in system sleep. I can add it to #1167 instead if you prefer.

Loader contract. port00 and dart_apcie0 stay disabled in the DT. The loader enables them when the port is up, or when the port is down but names `pwren-gpios` and its DART has `apple,manual-availability`. The loader copies the six host lists from the ADT (`apcie-<name>-tunables`, cio3pllcore moved into the pcieclkgen window at +0x2200 as in the J714c tree) next to the port lists it already copies. These values differ between the J716s and the J714c (the PHY PLL fields), so they cannot be static. That is the m1n1 side (follow-up to aurora-silicon/m1n1#65): with it, the m1n1 N1 training (ANS start, SMC pulse, warm-entry handling) is no longer needed.

**Tested on:** J716s, kernel `7.3.0-g50d99dcea7b4` = our J716s series (#937, #938, #1167 and the T6050 PRs) + these commits. The patches here are the same, rebased, with two cosmetic changes: kzalloc_obj() in the DART change and a shorter field comment. Boots self-testing from the primary slot, battery on, no `pcie_aspm=off`:
- **Port left down by the loader** (m1n1 fills the DT only, no training): m1n1 `n1: port 0: rc ctl 0x0 stat 0x1, port status 0x6 linksts 0xc300220c ltssm 0x0`, `n1: port 0 not up: root port and DART okay`. Kernel:
  ```
  [    1.004191] pcie-apple 1cb0000000.pcie: port 0: trained by Linux, the boot loader left it down
  [    1.005704] pcie-apple 1cb0000000.pcie: port 0: RID 0100 -> SID 1, slot 1
  [    1.006961] pcie-apple 1cb0000000.pcie: adopted port 0, endpoint 01:00
  [    1.360162] pcie-apple 1cb0000000.pcie: port 0: link retrained after a root-port reset
  [    1.387031] pcie-apple 1cb0000000.pcie: port 0: RID 0101 -> SID 2, slot 2
  [    1.389455] pcie-apple 1cb0000000.pcie: port 0: RID 0102 -> SID 3, slot 3
  [    4.320192] apple_centauri 0000:01:00.0: Wi-Fi firmware channel list: 709 bytes, capabilities: 570 bytes
  ```
  106b:1900, 1902 and 1903 enumerate; wlan0 associates; hci0 up; uptime 77 s at the first SSH login.
- **Warm restart** (`systemctl reboot` with wlan0 in use): the next boot trains the port again (same lines, 1.036 s), Wi-Fi and Bluetooth back.
- **Port trained by the loader** (the previous path): adopted as before, with the DART probed after the host; Wi-Fi and Bluetooth up.
- Suspend-to-idle with the N1 adopted (our s2idle patch for adopted links, not part of this PR) passed twice on the loader-trained path. The kernel-trained port goes through the same adoption.

**Checks** (omacom's `tools/aurora-ci`, run locally against this base):
  - check-commits: pass (every commit signed off; checkpatch notes only the missing author sign-off on edimoldovan's six commits).
  - compile-check, per commit (defconfig + asahi.config, PCIE_APPLE, APPLE_DART, GPIO_MACSMC, MFD_MACSMC on; clang 21.1.8, W=1): pass. The base and each of the 9 commits compile with 0 errors and 0 new W=1 warnings, including the three users of `include/linux/soc/apple/dart.h`.
  - dt-check (dtschema 2026.9): PASS. No new problems. The two changed bindings pass dt_binding_check; 118 DTBs build at base and head.
  - checkpatch --strict: 0 warnings. The only errors are NO_AUTHOR_SIGN_OFF on edimoldovan's commits (see Authorship).
  - DT half (`n1-kernel-train-dt` on #1167): t6050-j716s.dtb builds and its dtbs_check has no new warnings. dt-check reports no new blocking problems, but its dt-validate step fails at base and head alike (KeyError 'uint8-array', from conflicting `apple,tunable` types in three bindings). Advisory only: `gpio@67500000` has a unit name without reg (the same pattern as the existing gp bank at `gpio@67700000`).

**Dependencies:** #937: branch `n1-kernel-train` is stacked on its head a873be047e9a (`j716c/t6050-pcie`), so this PR targets `j716c/t6050-pcie` and can be retargeted to integration/aurora once #937 lands. Nothing in integration/aurora adopts a T6050 link without it. The DT half depends on #1167 and on commit 2 here.

**Authorship:** commits 1, 3-7 are edimoldovan's (from `t6050-j714c` on his fork, where the cold train has run on the J714c). They carry his authorship but no Signed-off-by of his own, only mine. @edimoldovan, could you add your Signed-off-by, or say if you would rather send them yourself?

**Open questions:**
- gP13: the template write on the J716s and `CMD_OUTPUT` on the J714c. Is the template right for both machines? Then the J714c could take the same path.
- cio3pllcore at pcieclkgen + 0x2200 is the J714c tree's placement. The m1n1 training this replaces never applied cio3pllcore, pcieclkgen or the PHY-IP lists, and trained the J716s anyway.
- Always-on GP domains (J716s DT) versus genpd consumers (J714c tree). The second needs the host to stay out of genpd's system-sleep power-off for a link kept through s2idle.
