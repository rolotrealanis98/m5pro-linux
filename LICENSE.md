# Licensing

Three licences are used. Their texts are in [`LICENSES/`](LICENSES/):
[`GPL-2.0-only`](LICENSES/GPL-2.0-only.txt), [`GPL-2.0-or-later`](LICENSES/GPL-2.0-or-later.txt)
(the same GPL v2 text; the identifier records the "or any later version" option) and [`MIT`](LICENSES/MIT.txt).

| What | Licence |
|---|---|
| Linux kernel patches: `patches/linux/**`, `contrib/pending/*/patches/linux/**`, `contrib/validated/legacy-7.2/cpufreq/linux/`, `contrib/validated/legacy-7.2/trackpad/000*.patch`, and kernel patches carried inside an omarchy-m5 patch (its `patches/linux/` files) | GPL-2.0-only |
| m1n1 patches: `patches/m1n1/`, `contrib/pending/*/patches/m1n1/`, `contrib/distro/pkg/m1n1-m5pro/` | GPL-2.0-or-later (m1n1's own licence since its relicensing on 2026-09-30, commit `ce2b8a43ce`; the m1n1 base these patches apply to, `459a3af2` and later, is after it. Patches written before that date against MIT-era m1n1 are carried here as GPL-2.0-or-later derivatives, with authorship kept) |
| Everything else: host scripts (`host/`, `host/macos/`), `scripts/`, tools under `contrib/`, `contrib/distro/`, docs, `dt/`, and the omarchy-m5 patches (`patches/omarchy-m5/`, `contrib/pending/*/patches/omarchy-m5/`, `contrib/pending/*/omarchy-m5/`, `contrib/validated/legacy-7.2/trackpad/dt-*.patch`, `contrib/distro/pkg/linux-m5pro/*.patch`: device tree, kernel config and build-script changes) | MIT |

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
  was added and then removed on 2026-10-10). These patches were written against MIT-era m1n1 and
  are carried here rebased onto the GPL-2.0-or-later m1n1, so the carried versions are
  GPL-2.0-or-later derivatives; ask their author before reusing them elsewhere. The
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

## Carrying Asahi Linux code (2026-11-08)

Asahi Linux relicensed its repositories from MIT to GPL-2.0-or-later (m1n1 on 2026-09-30,
speakersafetyd and asahi-audio on 2026-09-13), citing permissively licensed work taken without
attribution, sometimes after LLM rewriting. This repository carries Asahi code only as patches
on top of their trees or as unmodified files with their headers: author lines, copyright lines
and SPDX tags are kept, nothing of theirs is rewritten or renamed, and derived files name the
upstream file and commit they come from. Tools under `contrib/` that import m1n1's `proxyclient`
run against the user's own m1n1 checkout and are licensed as listed above.
See `contrib/community/ASAHI-7.3-REPORT-CHECK.md` for the inventory.
