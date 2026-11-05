# Licensing

Two licences are used. Their texts are in [`LICENSES/`](LICENSES/):
[`GPL-2.0-only`](LICENSES/GPL-2.0-only.txt) and [`MIT`](LICENSES/MIT.txt).

| What | Licence |
|---|---|
| Linux kernel patches: `patches/linux/**`, `contrib/pending/*/patches/linux/**`, `contrib/pending/cpufreq/linux/`, `contrib/pending/trackpad/000*.patch`, and kernel patches carried inside an omarchy-m5 patch (its `patches/linux/` files) | GPL-2.0-only |
| m1n1 patches: `patches/m1n1/`, `contrib/pending/*/patches/m1n1/`, `contrib/distro/pkg/m1n1-m5pro/` | MIT (m1n1's own licence) |
| Everything else: host scripts (`host/`, `host/macos/`), `scripts/`, tools under `contrib/`, `contrib/distro/`, docs, `dt/`, and the omarchy-m5 patches (`patches/omarchy-m5/`, `contrib/pending/*/patches/omarchy-m5/`, `contrib/pending/*/omarchy-m5/`, `contrib/pending/trackpad/dt-*.patch`, `contrib/distro/pkg/linux-m5pro/*.patch`: device tree, kernel config and build-script changes) | MIT |

Two rules on top of the table:

- **A file's own SPDX header wins.** The device trees (`dt/t6050-j716s.dts`,
  `contrib/pending/*/dt/*.dts[i]`) are `GPL-2.0+ OR MIT`, like the Asahi Linux Apple device
  trees they extend. A few audio userspace files under `contrib/pending/audio/userspace/` carry
  the identifier of the upstream file they were derived from (`GPL-2.0-only`,
  `GPL-2.0-or-later`; the same GPL v2 text applies).
- **A patch hunk takes the licence of the file it modifies** when that file says otherwise (for
  example, kernel patches touching `arch/arm64/boot/dts/apple/` are `GPL-2.0+ OR MIT`).

## Material from other projects (not relicensed)

Nothing below is relicensed by this repository. It keeps its original authorship and terms.

- **omarchy-m5** (github.com/betizzel/omarchy-m5, betim-hodza): m1n1 patches 0001-0006 in
  `patches/m1n1/` and `contrib/distro/pkg/m1n1-m5pro/` are betim-hodza's patches, rebased onto
  upstream m1n1 with authorship kept. omarchy-m5 currently publishes no licence (an MIT LICENSE
  was added and then removed on 2026-10-10). These patches modify MIT-licensed m1n1 and are
  carried here on that basis only; ask their author before reusing them elsewhere. The
  omarchy-m5 patches in this repository contain only changes made here, but their context lines
  and the files they modify are omarchy-m5's.
- **J716s device tree** (`dt/t6050-j716s.dts`): derived from omarchy-m5's J714s device tree,
  which builds on the Asahi Linux Apple device trees. Header and copyright line kept
  (`GPL-2.0+ OR MIT`, "The Asahi Linux Contributors / omarchy-m5 contributors").
- **Linux** (AsahiLinux/linux `asahi-wip-7.2`): the kernel patches are changes to it and are
  GPL-2.0-only, or follow the licence of the file they modify.
- **m1n1** (AsahiLinux/m1n1): MIT. Our m1n1 patches are offered under the same licence.
- **Audio userspace** (`contrib/pending/audio/userspace/`): the speakersafetyd profile is derived
  from AsahiLinux/speakersafetyd `conf/apple/j316.conf`; the WirePlumber fragment and DSP graph
  follow AsahiLinux/asahi-audio; the UCM file follows alsa-ucm-conf's J516 profile
  (alsa-ucm-conf is BSD-3-Clause). Each keeps its upstream terms.

Disk images, firmware, Apple boot objects and ADT dumps are not in this repository and nothing
here licenses them.
