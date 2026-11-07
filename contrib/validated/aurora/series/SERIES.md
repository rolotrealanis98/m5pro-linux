# J716s patch series on Aurora `integration/aurora`

87 patches (58 + 29 added since) on `aurora/integration` = `33bec4016c46` (aurora-silicon PR #1040 merge). They replace
branch `aurora-j716s` (`b790125548c4`, worktree `/Volumes/linux-cs/wt-aurora`) as the kernel source
for the J716s (MacBook Pro 16-inch, M5 Pro). Built from worktree `/Volumes/linux-cs/wt-series`
(branch `j716s-series`, tip `a0f2f30c967b`, 87 patches since 2026-11-07 "next daily" (see "Next daily" below; 0087 added the same day; the 86-patch tip was `3f2bdbc61510`; the previous tip `a83b052e9ffb` with 63 patches is kept as branch `j716s-series-pre-next-daily`). 63-patch state: 0059 SMC sensors, 0060 right Type-C port, 0061 WFI idle override, 0062 PM_DEBUG, 0066 lid-open confirm (lid sleep tested), all hardware-tested, re-authored 2026-11-07 to `Rolando Trevino <rolotrealanis@gmail.com>` with `Signed-off-by` and without assistant trailers; the content is byte-identical to `4f630b11270d`, which is the hash in the booted kernel version string), checked by `git am` in `/Volumes/linux-cs/wt-series-verify`.

- `patches/0001..0087-*.patch`, order in `patches/series` (0066 comes before 0063-0065; 0063-0065 and 0067-0087 were added on 2026-11-07, see "Next daily"). Aurora's patches keep their
  authors and messages; ours are authored and signed off by Rolando Trevino, without assistant trailers.
- `j716s.config`: the config fragment as of the series tip (`arch/arm64/configs/j716s.config`, from 0058 plus 0062-0065, 0083, 0084).
- `dt/t6050-j716s.dts`: the source device tree as of the series tip (0057 + 0059, 0060, 0082); `dt/next-daily-vs-stack.txt` and `dt/next-daily-vs-audio-defer.txt` are its comparisons (below); `dt/t6050-j716s.dtb` built from the
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
| 0059 | Rolando Trevino | arm64: dts: apple: j716s: Enable the SMC sensors | B | with the J716s DT PR |
| 0060 | Rolando Trevino | arm64: dts: apple: j716s: Enable the right Type-C port (ATC2) | B | with the J716s DT PR |
| 0061 | Rolando Trevino | arm64: idle: T6050 idles in WFI even with idle=nop | B | linux #1152 |
| 0062 | Rolando Trevino | arm64: configs: j716s: Enable PM_DEBUG for s2idle testing | B | ours |
| 0066 | Rolando Trevino | Input: macsmc-input - confirm a lid-open report during system sleep | B | new PR to integration |
| 0063 | Rolando Trevino | arm64: configs: j716s: Build in the MTP haptic driver | B | ours |
| 0064 | Rolando Trevino | arm64: configs: j716s: Build in netfilter, policy routing and container support | B | ours |
| 0065 | Rolando Trevino | arm64: configs: j716s: kernel crypto for iwd and wpa_supplicant | B | ours |
| 0067 | ed | ASoC: apple: macaudio: per-machine speaker volume ceiling | A (Ed's) | edimoldovan `t6050-j714c` |
| 0068 | Rolando Trevino | soc: apple: rtkit: let a client leave placed buffers unacknowledged | B | with the AOP port |
| 0069 | ed | soc: apple: aop: T6050 setup port and firmware DMA window | A (Ed's) | edimoldovan `t6050-j714c` |
| 0070 | ed | ASoC: apple: aop_t8140: T6050 variant | A (Ed's) | edimoldovan `t6050-j714c` |
| 0071 | ed | ASoC: apple: aop_t8140: T6050 speaker service has no output mute | A (Ed's) | edimoldovan `t6050-j714c` |
| 0072 | ed | ASoC: apple: t8140_aop_audio: re-align the J714c V/I sense words | A (Ed's) | edimoldovan `t6050-j714c` |
| 0073 | ed | ASoC: apple: t8140_aop_audio: run the J714c speakers only while the sense drains | A (Ed's) | edimoldovan `t6050-j714c` |
| 0074 | ed | ASoC: apple: t8140_aop_audio: J714c microphone array on the LEAP-S ADMAC | A (Ed's) | edimoldovan `t6050-j714c` |
| 0075 | ed | ASoC: apple: t8140_aop_audio: J714c microphone setup of the T604x flow | A (Ed's) | edimoldovan `t6050-j714c` |
| 0076 | ed | ASoC: apple: t8140_aop_audio: drain the J714c sense RX for the whole speaker run | A (Ed's) | edimoldovan `t6050-j714c` |
| 0077 | Rolando Trevino | ASoC: apple: macaudio: Add the J716 (MacBook Pro 16" M5 Pro/Max) | B | with the AOP port |
| 0078 | ed | ASoC: apple: t8140_aop_audio: align Left Woofer 1's sense voltage with its current | A (Ed's) | edimoldovan `83d711c3a909` (tdm 0001) |
| 0079 | Rolando Trevino | ASoC: apple: aop_t8140: stop the T6050 speaker serializer after the amps mute | B | tdm 0002; offer to edimoldovan |
| 0080 | Rolando Trevino | ASoC: apple: aop_t8140: check the T6050 speaker service's power state | B | tdm 0003 |
| 0081 | Rolando Trevino | ASoC: apple: macaudio: run the J716 speakers in the J616s frame | B | tdm 0004 (B6, unchanged) |
| 0082 | Rolando Trevino | arm64: dts: apple: j716s: Add the audio hardware | B | with the J716s DT PR |
| 0083 | Rolando Trevino | arm64: configs: j716s: Build in the AOP audio stack | B | ours |
| 0084 | Rolando Trevino | arm64: configs: j716s: Build in netconsole and ramoops | B | ours (no ramoops node in the DT) |
| 0085 | ed | PCI: apple: T6050 adopted ports: no ASPM, and a shutdown that holds the port | A (Ed's) | edimoldovan `ab24d156868e`; W4 (the W4 kernel booted with it) |
| 0086 | ed | wifi: apple: centauri: leave an N1 that never booted alone at remove and shutdown | A (Ed's) | edimoldovan `3a1bae4f8550`; W4 (the W4 kernel booted with it) |
| 0087 | Rolando Trevino | PCI: apple: T6050 adopted ports: keep the link up through suspend-to-idle | B | `j716s-n1shut` `85c770faad4b`; hardware-validated 2026-11-07 (two lid-close sleeps, Wi-Fi back after resume) |

Patches 0001-0044 are the commits of `aurora-j716s` cherry-picked unchanged in this order (PR #945 linearised
instead of merged). 0045-0050 are `aurora-j716s`'s own commits with rewritten messages (the rtkit one gained
a body); 0049 is Dj's and unchanged. 0051-0058 are new and replace
`6a6d7dfdc307` (the J716s DT that was not what we boot) and the hand-edited DTB.

## Next daily (2026-11-07): 0063-0065, 0067-0087

Appended to `a83b052e9ffb` (the 63-patch tip) in this order, one commit per patch; all apply as plain
cherry-picks or `git am` except where noted. `git apply` of the 86 files in `patches/series` on `33bec4016c46`
gives the tree of `3f2bdbc61510` (`63fec9cee9d4`); with 0087 the tip is `a0f2f30c967b` (tree `29128c1c5008`).

- **0063-0065** (haptic, netfilter/routing/WireGuard, iwd crypto): `j716s-daily-next` `595c6158`/`80bbf87e`/
  `24e777af` cherry-picked; tree identical to the full2 kernel plus 0066. The "Not booted" sentences now state the
  bisect A-D and full2 results.
- **0067-0081** (AOP audio, 11 ported + tdm 0001-0004): the 15 commits of `j716s-series-audio` `c963af7d14b9`,
  cherry-picked without conflicts; every audio file is byte-identical to `c963af7d14b9` and B5/B6's `e5a4712a3f0d`,
  so 0081 (J616s link format: normal BCLK, inverted FSYNC, 250-bit frame) is unchanged.
- **0082** (audio DT, new): the "defer DTB" (`audio-spk-notun-edp`, sha256 `9783ccb6`, B5/B6) rewritten in source
  form in the board file: i2c3 and its power state, the AOP setup port and the LEAP-S ADMAC as new board nodes
  (candidates for `t6050-die0.dtsi`), the amps with `apple,speaker-config` (level 10) and `apple,deferred-shutdown`,
  the jack codec, the AOP/dart-aop/ADMAC enables, the five audio pins, the sound card.
- **0083** (audio config, new): `RUST=y` (was `=n`), `APPLE_PMP` and `DRM_ASAHI` off, and the options of
  `contrib/pending/audio/aurora/audio.config` incl. `I2C_CHARDEV` and `DYNAMIC_DEBUG` as in the audio candidate.
- **0084** (crash log, config only): `contrib/pending/crashlog/patches/0002`, reworded: netconsole, `PANIC_TIMEOUT=10`,
  and `PSTORE_RAM`/`CONSOLE`/`PMSG` built in for a loader-supplied node. The ramoops DT node (crashlog 0001) is **not**
  in the series: iBoot zeroes the ECC DRAM and clears `/pram` at every boot (CRASHLOG-PRAM in `RESULTS.md`), and a DT
  node would block m1n1 0028's own node. Its hunk conflicted only on context (0064 rewrote the `# Userspace` block);
  the block sits after `PM_DEBUG`.
- **0085-0086** (W4 pcie-apple adopted-port ASPM strip and shutdown park, centauri never-booted remove): edimoldovan's
  commits from `contrib/pending/wireless/patches/linux`, author kept, Signed-off-by Rolando Trevino; they applied
  cleanly. The same two patches are in the W4 kernel (`7.3.0-gff289b9ce8ec`, three warm restarts with the N1 in use);
  on a payload whose m1n1 does not train port 0 they are inert (port00 stays disabled).
- **0087** (N1 sleep fix, ours): `j716s-n1shut` `85c770faad4b` cherry-picked onto `3f2bdbc61510` without conflicts, author and
  Signed-off-by Rolando Trevino. `apple_pcie_suspend_noirq()` no longer refuses suspend-to-idle on an `adopt_link` host: the
  adopted link stays in L0 (every function and the root port must be in D0, else the sleep is refused as before) and on resume a
  kept link must be up with no link-down latched, otherwise the hierarchy behind it is marked disconnected. Hosts that are not
  `adopt_link` are unchanged. Validated on hardware 2026-11-07: two lid-close sleeps (`adopted link kept through
  suspend-to-idle`), Wi-Fi back after resume. Also saved as `contrib/pending/wireless/patches/linux/0003-*`.

**Config:** `defconfig asahi.config j716s.config` sets every fragment symbol as written. Against the full2 kernel's
config the differences are the audio stack with Rust and its selects, the crash-log options (with `NETPOLL`,
`REED_SOLOMON`, `PRINTK_EXECUTION_CTX`), and the 0065 crypto (missing from full2's saved `config.resolved`);
against the audio candidate's config: 0062-0065 and the crash-log options.

**DT:** `t6050-j716s.dtb` from the tip against the stack DTB (`~/Work/agents/dt-prep/build/stack-right-port+hwmon.dtb`,
sha256 `594f2a9f`, = the 63-patch tip's DTB) with `tools/compare-dt.sh`: the only differences are the audio nodes and
properties of 0082 (`dt/next-daily-vs-stack.txt`); right port, SMC sensors, the empty `/reserved-memory` and
everything else are unchanged; there is no ramoops node. Against the defer DTB the audio nodes match property for property; the
remaining differences are the right port, hwmon, the four rows of the table below, the explicit
`status = "okay"` the defer DTB carries on its three new nodes, and child order (`dt/next-daily-vs-audio-defer.txt`).

**Build:** Rust needs Aurora's bindgen, so the kernel is built in the Fedora 43 container (clang 21, rustc 1.99.1)
with `BINDGEN=<tree>/tools/aurora-bindgen/build/bin/bindgen` on the make line, into `/Volumes/linux-cs/wt-series-out`
(cleaned with `mrproper` first: its host tools were macOS binaries, so `wt-series-out/scripts/dtc/dtc` is now a Linux
binary). Release string, hashes and payloads: `~/Work/agents/next-daily/REPORT.md`.

**Revert:** `git -C /Volumes/linux-cs/wt-series reset --hard a83b052e9ffb` (or `j716s-series-pre-next-daily`), and
drop 0063-0065 and 0067-0087 from `patches/series`.

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
