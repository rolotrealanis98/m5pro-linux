# Kernel-side N1 training for the J716s (K1/K2) — built 2026-11-07, not booted

Change from the plan: K1 cannot use the plain n1-warm m1n1: its DT step (0022) marks port00 and dart_apcie0
`disabled` whenever the link is down, so without `n1=4` the kernel never sees the port (probe -EINVAL). K1 uses
**n1-dt** = n1-warm + m1n1 0028: a down port with `pwren-gpios` whose DART has `apple,manual-availability` stays
`okay` with its DART, and m1n1 copies the six host tunable lists from the ADT into the DT (image still 0x400000,
8 bytes of rodata window left; three messages shortened; n1-warm rebuilds byte-identical 4c202e9d).

Kernel `7.3.0-g50d99dcea7b4` = series a0f2f30c967b + 0088-0094 (repo linux 0004-0010; branch j716s-series-n1kernel,
worktree /Volumes/linux-cs/wt-n1kernel; 0 warnings). Ed's commits keep his authorship (Co-Authored-By dropped,
Rolando's Signed-off-by added):
- 0088 ed 0f96cc6c00e1 cold train; 0089 ed 17ada56a25c9 host tunables; 0090 ed dbd43f4ff3da DART with
  `apple,manual-availability` waits for its PCIe host (conflict with our J713 display-DART code, both kept);
  0091 ed 3291060c462a pcie-apple makes the adopted port's DART available.
- 0092 ours: power line held low 250 ms to reset a warm N1 (what m1n1 0027 measured); PERST# and pwren taken before
  the first register write; link wait 1 s; shutdown drops pwren after the 0085 park.
- 0093 ours: gpio-macsmc on the J716s uses the J713 template write for gP13 (`0x00800000 | level`, proven by m1n1
  0026) instead of the generic CMD_OUTPUT the J714c uses.
- 0094 ours: J716s DT: phy-shared, phy-common, the four tunable windows (J714c addresses), `pwren-gpios =
  <&smc_gpio 0x13>`, the first SMC GPIO bank, `dart_apcie0` manual-availability, the GP power chain in pmgr1
  (APCIE_GP, FAB6_SOC, APCIE_SYS_GP, APCIE_PHY_SW, APHY_GP_AUS5_A, APHY_GP_AUS5) always-on with auto-PM off on the
  three m1n1 raises; port00 and the DART stay disabled in the DT (the loader decides). Ed's genpd-managed domain
  commits not taken (under 0087 the link stays up through s2idle and genpd would power the domain off).

Facts: his train follows upstream m1n1's controller bring-up (shared PHY clock req/ack, resets, PHY-IP tunables,
common clock, RC run); ours (m1n1 0023) uses Aura's stage S. His kernel pulses gP13 (low 50 ms) through
CMD_OUTPUT; the J716s ADT has the same pKW4("gP13", 0x00800000) descriptor. ANS is irrelevant once Linux trains
(kernel touches GP registers at 0x21x only; storage at 0x28x; nvme-apple restarts ANS itself; one new condition:
ANS boot and the train may overlap). Tunables: the J716s ADT has the same host lists in the same windows but
different PLL values (phy-ip-pll 0x182230, 0x18224c, 0x183004; cio3pllcore +0x4c), so they must come from the
loader (0022 port lists, 0028 host lists); cio3pllcore at pcieclkgen + 0x2200 is ed's convention, unverified here.
Adoption (#937) unchanged: the train runs only when adoption returns -ENOLINK and the port has pwren-gpios. Boot
power state identical to the J714c (APCIE_SYS_GP/APHY_GP_AUS5 0x1000030f, APCIE_PHY_SW 0x1400024f).

Payloads (~/Work/agents/n1-kernel/payloads/private/, mk-n1kernel.py k1|k2, self-test, battery, FTAB initramfs, no
pcie_aspm=off): K1 `n1kernel-k1-20261107-c62b1ca5.bin` (m1n1 n1-dt, no n1 line); K2 `n1kernel-k2-20261107-96afa462.bin`
(n1-warm, n1=4). Modules ~/Work/agents/n1-kernel/modules/modules-7.3.0-g50d99dcea7b4.tar.zst. m1n1
~/Work/agents/n1-kernel/m1n1-build/m1n1-plain-n1-dt.bin.

Pass lines K1: phram `n1: port 0 not up: root port and DART okay`, no `n1: apcie-… not copied`; kernel `port 0:
trained by Linux, the boot loader left it down`; `apple-dart 410000000.iommu: waiting for its client` then bind;
[106b:1900] then 01:00.1 [106b:1902], 01:00.2 [106b:1903]; centauri phase0 ok; wlan0 associates; warm reboot with
wlan0 in use shows `port 0 held for the restart, its endpoint powered off` and the next boot trains again.
Failure signs: `shared PHY: … waiting for`, `apple,tunable-<x>: -22`, probe -110, adoption -ENOLINK after the
train, `gP13 set to … failed`. K2: as the daily plus the DART deferral line, no train line.

If K1 passes: m1n1 training (0023, 0025-0027, n1 modes) becomes optional on the disk-boot path; keep the DT
fill-in (0022 + 0028) in #65 and the omacom series; 0022 alone breaks the kernel train; a loader with no N1 code
(Omarchy's) would need ed's approach (per-machine tunables in the DT, untested). Upstream kernel PR = 0088-0091 +
0092-0094 + apple,pcie.yaml extension (pwren-gpios, reg-names) + ed's DART binding 8805d2777c8b.

Build tooling: bindgen copy at /Volumes/linux-cs/n1kernel-tools/bindgen (the wt-aurora-audio2 copy that
build-next.sh and build-modules.sh point to is gone; update those paths); builds with -j8.
