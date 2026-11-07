# Aurora kernel on the J716s: tools

Helpers used in Round R3 (2026-11-06, see `../../integration/RESULTS.md`) to run Aurora Silicon's
`integration/aurora` kernel on this machine. Read-only on the kernel tree; they produce a device
tree, a payload and a test initramfs. They do not touch the machine.

Per-unit values (the combo-PHY tunables, dmesg, serials) are not in this folder or this repository.
`../atc-tunables/gen-atc-tunables.py` regenerates the tunables from your own ADT.

## The pipeline

1. **Decompile Aurora's DTB.** Build `t6050-j716s.dtb` (the J716s device tree derived from J716c,
   see `../ANALYSIS.md` section 1.2) with the worktree's `scripts/dtc/dtc`, then decompile it
   (`dtc -I dtb -O dts`). Work on the decompiled DTS from here on.
2. **Reorder the CPU nodes** with `reorder-cpus.py IN.dts OUT.dts`. Aurora's `t6050-max.dtsi`
   appends the sixth core of each cluster after the first fifteen, and m1n1 matches CPU nodes by
   index, so the boot stopped at `DT CPU 5 MPIDR mismatch 0x40100 != 0x40005`. The script puts the
   18 nodes into the ADT order (hard-coded for this SoC: 40000-40005, 40100-40105, 10200-10205).
3. **Fallbacks and fixes (by hand on the DTS).** Each one was a node whose compatible has no driver
   in `integration/aurora`, or a property the driver reads from another place:
   - `smc`: add the `apple,t8103-smc` fallback; `cluster-cpufreq`: `apple,t8112` fallback;
   - `cio` reset: `apple,t8142` fallback and the node enabled;
   - `apple,smc-pcio-gpio` has no driver, so the keyboard and trackpad deferred on the AFE reset
     line. Fix: an `apple,smc-low-gpio` child on the SMC and `apple,afe-reset-gpios = <low-gpio 28
     ACTIVE_LOW>` on the **parent** `input@8000` node (Aurora's driver reads it there);
   - NVMe: with Aurora's own driver it first needs `resets` and `power-domains` (an ANS
     `power-controller@140`); with PR #936 (T6050 NVMe/SART v4) both must be absent, because the
     driver adopts the running ANS and does not reset it through PMGR;
   - left-front Type-C chain: `hpm1` `usb-pd@a` (`sn201202x`) on SPMI plus the connector graph;
   - `TYPEC_SN201202X` must be `=y` in the kernel config.
4. **Tunables.** The T6050 combo PHY needs 14 `apple,tunable-*` lists that no public loader fills.
   Generate them from the ADT with `../atc-tunables/gen-atc-tunables.py` and paste them into the
   `phy@2ab000000` node (report: `../atc-tunables/REPORT.md`). Keep that DTS out of git.
5. **Dependency check, before every boot.** `dt-depcheck.py DTS KERNEL_TREE` greps the tree for
   every `"apple,..."` string and lists (a) enabled Apple nodes whose compatible matches no driver
   source, and (b) enabled nodes whose reset/phy/power-domain/iommu/mailbox/gpio provider is disabled
   or driverless. It reads source only, so a driver that is `=m` or not selected still passes: also
   check the `.config` for every driver on the boot path (`=y`, not `=m`; there are no modules on
   the root). The rule since R3-K: no boot until this check is clean and all required drivers are
   `=y`.
6. **Payload.** Use `mk-daily.py` (named ingredients, pins, daily and test modes, a printed deploy plan; the ESP rules are
   in `ESP-POLICY.md`). `mk-r3.py` is the older hard-coded script, which shows the layout: m1n1-plain (exactly 0x400000 bytes) + `chosen.bootargs=...`
   + `chosen.asahi,show-notch=1` + `Image.gz` + DTB + initramfs, written as one file with a
   `SHA256SUMS` line. Paths are hard-coded to the Studio; edit them. Only the first two payloads
   were made by this script; the rest used the same recipe with other kernel, DTB and initramfs.
7. **Selftest loop.** `mk-selftest-initramfs.sh` builds the initramfs. Add `m5.selftest=1` to the
   bootargs and keep the last known-good payload as `boot.bin.prev` on the ESP. A test payload that
   reaches the root but not the network within 90 s saves its logs to `/boot/r1-logs/selftest-*/`,
   restores `boot.bin.prev` and reboots, so a failed test costs no manual visit. A payload that
   never mounts the root is not covered; the DIAG block printed on the panel is the evidence there.

## Files

| File | What |
|---|---|
| `reorder-cpus.py` | `reorder-cpus.py IN.dts OUT.dts`: CPU nodes into ADT order |
| `dt-depcheck.py` | `dt-depcheck.py DTS KERNEL_TREE`: offline compatible / provider check |
| `mk-daily.py` | builds the daily and test payloads from the `INGREDIENTS` table, writes the recipe and a `SHA256SUMS` line, `--deploy-plan` prints the ESP swap |
| `ESP-POLICY.md` | what lives on the ESP, the four-payload rule, the self-revert contract, selftest versus the daily |
| `mk-r3.py` | the original hard-coded payload assembly (superseded by `mk-daily.py`) |
| `mk-selftest-initramfs.sh` | debug initramfs with the DIAG block and the self-revert service (macOS) |

Lineage of the initramfs: `host/macos/mk-debug-initramfs.sh` (60 s root wait, dropbear, nvme rebind)
-> the "diag" variant used on R3-F to R3-L (adds the DIAG block on the panel; not copied here, it is
the first part of the selftest script) -> `mk-selftest-initramfs.sh` (adds the self-revert).

## Build notes (macOS host)

- BSD `sed` breaks `arch/arm64/tools/gen-kernel-hwcaps.sh` (`\+`): put gnu-sed and the coreutils
  `gnubin` directories first on `PATH`.
- Config: `make defconfig asahi.config` (16K pages; the first build used 4K by mistake), `RUST` off,
  and the boot-path drivers `=y`: NVME_APPLE, APPLE_RTKIT_HELPER, SART, DART, MAILBOX, DOCKCHANNEL,
  HID_DOCKCHANNEL, MFD_MACSMC, POWER_RESET_MACSMC, NVMEM_APPLE_SPMI, SPMI_APPLE, GPIO/INPUT/HWMON/RTC
  macsmc, DRM_SIMPLEDRM, PWM_APPLE, LEDS_PWM, USB_DWC3_APPLE, PHY_APPLE_ATC, PHY_APPLE_T6040_USB2,
  PHY_APPLE_T6050_DP, TYPEC_TPS6598X, TYPEC_SN201202X, RESET_APPLE_CIO, USB_RTL8152, USB_STORAGE,
  ARM_APPLE_CPUIDLE, ARM_APPLE_SOC_CPUFREQ, PCIE_APPLE, APPLE_PMP, ZRAM, NF_TABLES, DEVMEM.
