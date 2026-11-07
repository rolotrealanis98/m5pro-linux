# J716s patch series on Aurora `integration/aurora`

58 patches on `aurora/integration` = `33bec4016c46` (aurora-silicon PR #1040 merge). They replace
branch `aurora-j716s` (`b790125548c4`, worktree `/Volumes/linux-cs/wt-aurora`) as the kernel source
for the J716s (MacBook Pro 16-inch, M5 Pro). Built from worktree `/Volumes/linux-cs/wt-series`
(branch `j716s-series`, tip `c2e1be601fb4`, 62 patches since 2026-11-07 12:00 UTC: 0059 SMC sensors, 0060 right Type-C port, 0061 WFI idle override, 0062 PM_DEBUG, all loop-tested, re-authored 2026-11-07 to `Rolando Trevino <rolotrealanis@gmail.com>` with `Signed-off-by` and without assistant trailers; the content is byte-identical to `4f630b11270d`, which is the hash in the booted kernel version string), checked by `git am` in `/Volumes/linux-cs/wt-series-verify`.

- `patches/series/0001..0058-*.patch`, order in `patches/series/series`. Aurora's patches keep their
  authors and messages; ours are authored and signed off by Rolando Trevino, without assistant trailers.
- `patches/j716s.config`: the config fragment (also patch 0058, `arch/arm64/configs/j716s.config`).
- `dt/t6050-j716s.dts`: the source device tree (patch 0057), `dt/t6050-j716s.dtb` built from the
  series, `dt/t6050-j716s.decompiled.dts`, `dt/dt-diff.txt` (against the booted DTB).
- `tools/dtnorm.py`, `tools/compare-dt.sh`: the DTB comparison used below.

## The patches

A = Aurora's work we carry, B = ours. "Upstream" is where the patch lives or should go
(aurora-silicon/linux; targets for B are argued in `UPSTREAM-NOTES.md`).

| # | Author | Subject | Group | Upstream |
|---|---|---|---|---|
| 0001 | Jeff Queisser | arm64: dts: apple: Add the J775D (Mac Studio, M5 Ultra) device trees | A | PR #945 (`pr-945-j716c-dt`) |
| 0002 | Jeff Queisser | arm64: dts: apple: Build the J775D device tree | A | PR #945 |
| 0003 | Jeff Queisser | dt-bindings: mailbox: apple,mailbox: Add T6050 ASC mailboxes | A | PR #945 |
| 0004 | Jeff Queisser | dt-bindings: arm: apple: Add the Mac Studio (M5 Ultra, 2026) | A | PR #945 |
| 0005 | Jeff Queisser | dt-bindings: interrupt-controller: apple,aic2: Add T6050 | A | PR #945 |
| 0006 | Jeff Queisser | dt-bindings: watchdog: apple,wdt: Add T6050 | A | PR #945 |
| 0007 | Jeff Queisser | dt-bindings: iommu: apple,dart: Add the T6050 DART | A | PR #945 |
| 0008 | Jeff Queisser | dt-bindings: spi: apple,qspi: Add t6050 | A | PR #945 (conflict resolved, see below) |
| 0009 | Jeff Queisser | arm64: dts: apple: t6050: Add the PMU's power-on policy cell | A | PR #945 |
| 0010 | Erik Bourget | arm64: dts: apple: Add J716c (MacBook Pro 16-inch, M5 Max) | A | PR #945 |
| 0011 | Erik Bourget | pinctrl: apple-gpio: Use the uncached regmap on T6050 | A | PR #945 |
| 0012 | Erik Bourget | arm64: dts: apple: j716c: Add the N1 on PCIe port 0 | A | PR #945 |
| 0013 | Jeff Queisser | dt-bindings: iommu: apple,sart: Add the T6050 SART | A | PR #936 (`pr-936-nvme`) |
| 0014 | Jeff Queisser | soc: apple: sart: Add SARTv4 for T6050 | A | PR #936 |
| 0015 | Jeff Queisser | dt-bindings: nvme: apple: Add the T6050 ANS | A | PR #936 |
| 0016 | Jeff Queisser | nvme: apple: Add the T6050 ANS on bare metal | A | PR #936 |
| 0017 | Jeff Queisser | dt-bindings: nvme: apple: Allow the boot loader's RTKit handoff on T6050 | A | PR #936 |
| 0018 | Dj | phy: apple: Add T6050 DisplayPort and USB combo PHY | A | PR #939 (`pr-939-typec`) |
| 0019 | Jeff Queisser | dt-bindings: phy: apple,t6050-dp-phy: Allow the USB domain on combo PHYs | A | PR #939 |
| 0020 | Jeff Queisser | phy: apple: t6050: Hold the USB domain for the combo PHY's USB2 banks | A | PR #939 |
| 0021 | Jeff Queisser | dt-bindings: phy: apple,t6050-dp-phy: Type apple,port-index as uint32 | A | PR #939 |
| 0022 | Jeff Queisser | usb: dwc3: apple: Add the bare-metal T6050 controller | A | PR #939 |
| 0023 | Jeff Queisser | phy: apple: t6050: Enable the dummy PIPE PHY for the USB3 lock | A | PR #939 |
| 0024 | Jeff Queisser | phy: apple: t6050: Stay on USB2 when the PIPE never left the dummy | A | PR #939 |
| 0025 | Jeff Queisser | phy: apple: t6050: Accept every Type-C port but the debug port | A | PR #939 |
| 0026 | Erik Bourget | phy: apple: t6050: park the PIPE from a dummy producer on any clock | A | branch `j716c/thunderbolt` `6f93def30893` |
| 0027 | Erik Bourget | phy: apple: t6050: carry on when the PIPE lock is not acknowledged | A | `j716c/thunderbolt` `e604b7f414b4` |
| 0028 | Erik Bourget | phy: apple: t6050: restart the PHY firmware on its original data | A | `j716c/thunderbolt` `b8f2be0fef93` |
| 0029 | Jeff Queisser | dt-bindings: pci: apple,pcie: Add T6050 hosts adopted from the boot loader | A | PR #937 (`pr-937-pcie`) |
| 0030 | Jeff Queisser | dt-bindings: pci: apple,pcie: Give the T6050 conditions a then branch | A | PR #937 |
| 0031 | Jeff Queisser | PCI: apple: Adopt T6050 root ports the boot loader trained | A | PR #937 |
| 0032 | Dj | PCI: Add pci_trylock_rescan_remove() | A | PR #937 |
| 0033 | Erik Bourget | PCI: apple: Add the T6050 port reset, enable, configure and train sequences | A | PR #937 |
| 0034 | Jeff Queisser | PCI: apple: Adopt T6050 port 0's multi-function N1 and reset its root port | A | PR #937 |
| 0035 | Jeff Queisser | PCI: apple: Drive T6050 port 0's PERST# through the pin controller | A | PR #937 |
| 0036 | Dj | net: apple: Add T6050 N1 firmware and ACIPC transport | A | PR #938 (`pr-938-n1`) |
| 0037 | Dj | wifi: apple: Add N1 protocol-27 station support | A | PR #938 |
| 0038 | Dj | Bluetooth: Add N1 protocol-27 HCI and ACL transport | A | PR #938 |
| 0039 | Erik Bourget | Bluetooth: btcentauri: Drop an unused variable | A | PR #938 |
| 0040 | Jeff Queisser | Bluetooth: btcentauri: Take the factory address from local-bd-address | A | PR #938 |
| 0041 | Jeff Queisser | wifi: apple: centauri: Connect to the BSS the request names | A | PR #938 |
| 0042 | Jeff Queisser | wifi: apple: centauri: Read the firmware's channel list and capabilities | A | PR #938 |
| 0043 | Jeff Queisser | wifi: apple: centauri: Take the bands from the firmware's channel list | A | PR #938 |
| 0044 | Jeff Queisser | wifi: apple: centauri: Support WPA3-Personal through the firmware's SAE | A | PR #938 |
| 0045 | rolotrealanis98 | soc: apple: rtkit: wait up to 10 s for a handshake reply | B | new PR, or into PR #936 |
| 0046 | rolotrealanis98 | HID: dockchannel-hid: settle 50 ms after releasing the AFE reset | B | new PR to integration |
| 0047 | rolotrealanis98 | hwmon: (macsmc) keep a fan whose optional keys are missing | B | new PR to integration |
| 0048 | rolotrealanis98 | power: supply: macsmc-power: initialise work items before the notifier | B | new PR to integration |
| 0049 | Dj | power: supply: macsmc-power: read battery identity strings at their key size | B (Dj's) | Aurora `54b12371013e` on `j716c/t6050-platform`; drop when that lands |
| 0050 | rolotrealanis98 | drm/sysfb: simpledrm: report an eDP connector for an Apple built-in panel | B | with edimoldovan (`linux-aurora` `9dee12b1266c`) |
| 0051 | rolotrealanis98 | reset: apple-cio: Add the T6050 reconfiguration register | B | new PR to integration |
| 0052 | rolotrealanis98 | mfd: macsmc: Match the T6050 SMC | B | subset of `j716c/t6050-platform` `54b12371013e`/`64f198a02f63`; PR or drop when that lands |
| 0053 | rolotrealanis98 | dt-bindings: cpufreq: apple,cluster-cpufreq: Add T6050 | B | discuss with the `j716c/t6050-platform` cpufreq owner |
| 0054 | rolotrealanis98 | arm64: dts: apple: t6050-max: List the CPUs in the ADT's order | B | PR on top of PR #945 (touches J716c) |
| 0055 | rolotrealanis98 | arm64: dts: apple: t6050: Describe the SMC's second GPIO bank | B | with the J716s DT PR |
| 0056 | rolotrealanis98 | dt-bindings: arm: apple: Add the MacBook Pro (16-inch, M5 Pro) | B | with the J716s DT PR |
| 0057 | rolotrealanis98 | arm64: dts: apple: Add J716s (MacBook Pro 16-inch, M5 Pro) | B | new PR "J716s DT" on top of #945/#936/#939/#937/#938 |
| 0058 | rolotrealanis98 | arm64: configs: Add a J716s fragment | B | ours; offer it (the tree has `j813.config`) |

Patches 0001-0044 are the commits of `aurora-j716s` cherry-picked unchanged in this order (PR #945 linearised
instead of merged). 0045-0050 are `aurora-j716s`'s own commits with rewritten messages (the rtkit one gained
a body); 0049 is Dj's and unchanged. 0051-0058 are new and replace
`6a6d7dfdc307` (the J716s DT that was not what we boot) and the hand-edited DTB.

## Differences from `aurora-j716s`

`git diff --stat aurora-j716s <series tip> -- drivers/ arch/arm64/boot/dts/apple/`:

```
 arch/arm64/boot/dts/apple/t6050-die0.dtsi |  11 ++         (0055: smc_gpio_low)
 arch/arm64/boot/dts/apple/t6050-j716s.dts | 184 +++------  (0057 replaces 6a6d7dfdc307)
 arch/arm64/boot/dts/apple/t6050-max.dtsi  |  13 ++-       (0054: CPU order)
 drivers/mfd/macsmc.c                      |   1 +         (0052)
 drivers/reset/reset-apple-cio.c           |  23 +++-      (0051)
```

Outside those directories: the bindings of 0051-0053 and 0056, `arch/arm64/configs/j716s.config` (0058), and
`Documentation/devicetree/bindings/spi/apple,qspi.yaml`: `aurora-j716s` merged PR #945 with a bad resolution
(three `const` items: `t8152-qspi`, `t6050-qspi`, `t8140-qspi`). Linearising hit the same conflict at 0008;
it is resolved as `enum: [t6050-qspi, t8152-qspi]` + `const: t8140-qspi`, which is what both sides meant.
Every other file is identical to `aurora-j716s`.

## Device tree (deliverable 1)

`arch/arm64/boot/dts/apple/t6050-j716s.dts` against Aurora's `t6050-max.dtsi`/`die0`/`dieX`/`base`, no cpp
switches. Built with the tree's dtc by `make LLVM=1 ARCH=arm64 dtbs` (all 1912 arm64 DTBs, no warnings).
DTB sha256 `8c4df67ac743a08b633f7e5233004180e5b18d9f82c56b9261ec76eb77458e6e`, byte-identical from
`/Volumes/linux-cs/wt-series` and from the `git am` tree.

Reference: the booted DTB `~/Work/agents/aurora-kernel/t6050-j716s-typec-fixed8-notun-edp.dtb`
(sha256 `60114b95...`, byte-identical to compiling `dts/j716s-typec-fixed8-notun-edp.dts`; it is the repo's
`t6050-j716s-aurora-decompiled.dts` (retired, see git history) plus `apple,internal-panel`). `tools/compare-dt.sh` lists every property
with phandles resolved to node paths (so numbering cannot hide or fake a difference) and the child order of
every node. Remaining differences (`dt/dt-diff.txt`):

| Difference | Why it is fine |
|---|---|
| `power-controller@140` ("ans") absent | Nothing references it: PR #936's driver adopts the running ANS and wants no `power-domains`/`resets`. It was added for the pre-#936 driver. With it, a boot without `pd_ignore_unused` would let genpd switch the ANS domain off as unused; without it Linux never touches that domain. |
| SMC `compatible = "apple,t6050-smc"` (booted: `+ "apple,t8103-smc"`) | 0052 matches the string in macsmc; same probe path as the fallback. Aurora's platform branch uses the same single string. |
| CIO reset `compatible = "apple,t6050-cio-reset"` (booted: `+ "apple,t8142-cio-reset"`) | 0051 gives T6050 its own variant. The T8142 fallback was wrong: T8142's register is at +0x30, T6050's at +0x60 (same bits). Harmless so far because the only consumer (`usb4_3_acio`) is disabled. |
| CIO reset `status = "okay"` (booted: no `status`) | Same meaning. |
| `/cpus` order: none | Fixed in the dtsi (0054), see below. |

Phandle numbers differ by construction; the normalised comparison makes that irrelevant. A plain
`dtc -s` diff (`dt/dtc-sorted.diff`) shows only the four rows above. Against the audio DTBs
(`~/Work/agents/audio-aurora/dt/`) the difference is exactly their audio additions (i2c3 and `ps_i2c3`, the
codecs, the AOP audio node and its setup mailbox, a DMA controller, SMC and pin changes) plus the same
`power-controller@140`.

### CPU order: dtsi, not post-processing

m1n1's `dt_set_cpus()` walks the DT's CPU nodes and compares node N with ADT cpu N; it prunes nodes of
cores that are not alive and stops at the first other mismatch. `t6050-max.dtsi` put the sixth core of each
cluster after the other fifteen, so the J716s stopped at `DT CPU 5 MPIDR mismatch: 0x40100 != 0x40005`.
0054 lists the 18 cores in ADT order in `t6050-max.dtsi`. Reasons over `reorder-cpus.py`: the order is a
property of the SoC, not the board (the J716c with the same ADT layout hits the same check); the labels
already assumed it (cpu5 = 40005); a post-processing step is invisible to anyone building from the tree;
and Linux's logical CPU numbers now match the ADT's. A part with a core fused off still lists it in the
ADT, so m1n1 prunes it by position and the order stays right. `t6050-ultra.dtsi` (J775D) has the same
layout per die and is left as it is (no J775D ADT to check).

### Fallback compatibles: what was chosen

| Booted fallback | Chosen fix | Why |
|---|---|---|
| `apple,t8103-smc` | driver match `apple,t6050-smc` (0052) + binding `const` | Aurora's own direction: `j716c/t6050-platform` matches the single string and adds a T6050 cell list. A driver entry merges trivially with that; a DT fallback would be at odds with their binding. |
| `apple,t8142-cio-reset` | driver variant `apple,t6050-cio-reset` (0051) | The layouts differ (register offset), so a fallback is wrong, not just unclean. |
| `apple,t8112-cluster-cpufreq` | DT fallback in the J716s board file + binding entry (0053, 0057) | The hardware is the T8112 layout (measured), which is the textbook case for a fallback (as T6020/T6030/T6031/T6041/T8122). A driver entry with T8112 data would collide with the platform branch's own `soc_t6050_info` (transition verification, required firmware thermal); the fallback yields to it automatically. Kept in the board file, not `t6050-dieX.dtsi`, so the J716c and J775D do not start running cpufreq untested; move it once Aurora agrees. |

Side effects on other boards: J716c gets the CPU order fix, the `smc_gpio_low` node and a bound SMC (0052);
J775D gets the SMC binding too. Both build; neither was booted.

## Rebuild

```sh
# tools (macOS host): GNU sed/coreutils/make and LLVM first on PATH
export PATH=/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/make/libexec/gnubin:$PATH

# fresh tree at aurora/integration + the series
git -C /Volumes/linux-cs/linux worktree add --detach /Volumes/linux-cs/wt-j716s 33bec4016c46
cd /Volumes/linux-cs/wt-j716s
git am ~/Work/agents/aurora-series/patches/series/*.patch

# config and build (O= keeps the source tree clean)
mkdir -p /Volumes/linux-cs/wt-j716s-out
make LLVM=1 ARCH=arm64 O=/Volumes/linux-cs/wt-j716s-out defconfig asahi.config j716s.config
make LLVM=1 ARCH=arm64 O=/Volumes/linux-cs/wt-j716s-out -j12 Image.gz dtbs
#   -> arch/arm64/boot/Image.gz, arch/arm64/boot/dts/apple/t6050-j716s.dtb (in the O= dir)

# check the DTB against the booted one
~/Work/agents/aurora-series/tools/compare-dt.sh \
    /Volumes/linux-cs/wt-j716s-out/arch/arm64/boot/dts/apple/t6050-j716s.dtb \
    ~/Work/agents/aurora-kernel/t6050-j716s-typec-fixed8-notun-edp.dtb
```

The payload recipe is unchanged (`contrib/pending/aurora/tools/mk-r3.py` (retired, see git history) layout, R3-V bootargs, m1n1
`pipepark-atc` with 0020/0021); only the kernel tree and the DTB come from here. No `reorder-cpus.py`, no
hand edits.

## What was verified here (Studio only)

- `git am` of all 58 patches on a fresh worktree at `33bec4016c46`: clean; resulting tree
  `31afe855ec00` identical to `j716s-series`.
- `make dtbs` (all arm64) on the result: 1912 DTBs, rc 0, no warnings. Every DT-touching patch builds the
  T6050 DTBs that exist at that point (0002 onwards; 0001 adds J775D sources that 0002 wires up).
- J716s DTB from the series = deliverable 1 (byte-identical); semantic diff to the booted DTB as above.
- `defconfig asahi.config j716s.config` reproduces the booted `.config` (`wt-aurora/.config`) symbol for
  symbol; the only difference is `RUST_IS_AVAILABLE`, which reflects the host toolchain, not a choice.
- Not done: no kernel or module objects were compiled (task rule), so 0051 and 0052 are not compile-tested,
  and nothing was booted. `dtbs_check` was not run (no dt-schema on the Studio).
