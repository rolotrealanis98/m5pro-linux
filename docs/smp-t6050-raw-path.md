# T6050 SMP on the raw-image boot path: what was tested on 2026-10-20

Machine: 16-inch M5 Pro (J716s, T6050, 18 cores), macOS 27.2 boot objects, iBoot
`mBoot-20457.41.2`, stub policy `bputil -nc` (`kernel-ctrr-to-be-enabled = 0` in `/chosen`).
Host: Studio over USB, installed stage-1 m1n1 `m5-t6050` @ 549ec7c1. Every hardware step ran with
the WD1 watchdog armed (`wdt-arm.py`), so a hang reboots into stage-1 by itself.

## Short version

- A released secondary powers up (PMGR ps 0x100 -> 0x1f0, impl status `...d800 -> ...d102`)
  but executes nothing: not at its locked RVBAR (m1n1 base), not at the start of any CTXR slice
  of iBoot's 48 KiB WFI sled. A watchdog arm inside the stub never fired either, so this is not
  a cache artefact.
- The macOS side does nothing more than m1n1 does. `AppleARMCPU::startCPU` calls the device-tree
  platform function `function-enable_core` = `ApplePMGRFunctionEnableCPUCore` =
  `ApplePMGR::configMiscCores(mask, true)`, whose only hardware effect is the two PMGR writes
  (`CPU_START+0x4 |= die bits`, `+0x8+4*cluster = core bits`) through
  `AppleT6050PMGR::writeACCReg32`. Cluster enable (`configCPUComplexPowerState`) only clears
  `CLUSTER_PSTATE_M2_APSC_DIS` (bit 23 of DVFS block + 0x20020), which is already clear on all
  three clusters here. Five release-order variants (stop-bit W1C first, PMGR ps on first,
  cluster bit first, poking +0x10/+0x14) changed nothing.
- The one structural difference between this boot and a macOS boot is in
  `/chosen/memory-map`: the raw image is recorded as a boot kernel collection with an **empty
  executable region** (`BootKC-rx` size 0, the whole image in `BootKC-rw`, no SPTM/TXM). CTRR-A
  and CTRR-B are therefore locked around the dummy sled instead of around kernel text. On a
  kernelcache boot `BootKC-rx` is the kernel text and SPTM's entry sits inside it.
  SPTM's per-core init (`sptm-ctrr-check.txt`) verifies on every secondary that CTRR-A/B and
  CTXR-A..D match values stashed from the boot core, i.e. iBoot programs them per core before
  release. Whether the ROM/LLB reset handler refuses a vector outside CTRR-A is **not proven**;
  M4 and M4 Pro reportedly start secondaries on the same raw path (Yureka, 2026-10-02), so if
  this is the gate it is T6050- or firmware-generation-specific.

## Next test (needs the 1TR ceremony, i.e. a person at the Mac)

Register m1n1 as a Mach-O instead of a raw image, so iBoot gets a text segment:

1. On the Studio: `~/Work/m1n1/build-plain/m1n1.macho` (plain, no CHAINLOADING, same source as the
   installed stage-1). Copy it to the Mac.
2. In macOS: `sudo scripts/finish-install.sh --m1n1 m1n1.macho --macho` (omarchy-m5 with
   `patches/omarchy-m5/0002`), then the usual power-hold -> Omarchy -> step2 ceremony.
   step2 runs `kmutil configure-boot -c boot.bin -v <stub>` without `--raw`.
3. Expected outcomes: kmutil rejects the image (the m1n1 README says the Mach-O path only
   worked before macOS 12.1; m1n1's Mach-O is an `MH_FILESET` with segments `TEXT/RODA/DATA/PYLD`,
   not Apple's `__TEXT_EXEC` names) -> fall back to `--raw`, nothing lost; or it boots -> run
   `scripts/probes/release-variants.py` on the fresh stage-1. If a crumb appears, SMP is a
   bootloader-packaging problem, not a chip problem.
4. If kmutil refuses, the next rung is antiapplefox/m5-linux's `pack-bootkc.py` layout
   (`__TEXT_EXEC`/`__DATA_CONST`/`__TEXT_BOOT_EXEC`/`__DATA` + `LC_FILESET_ENTRY`), which may make
   iBoot take the kernelcache path and load SPTM; then the XNU-shim work applies.

## Mach-O attempt (2026-10-20, later)

`finish-install.sh --m1n1 m1n1.macho --macho` + the 1TR ceremony: **kmutil refused the Mach-O**
(error text to be added). The raw image was re-registered from the 1TR shell with
`sh <(curl -s 192.168.1.4:8000/go.sh)` served from the Studio (`~/Work/m1n1/build-plain/go.sh`,
raw kmutil + install-media cleanup + reboot). Back on the raw stage-1 the RVBAR crumb probe with
the five release variants was negative again (`BootKC-rx` size 0 as before).

Staged for the next ceremony: `~/Work/m1n1/build-plain/m1n1.bootkc.macho`, made with
antiapplefox/m5-linux `scripts/pack-bootkc.py` from our plain `m1n1.macho`: segments renamed to
`__TEXT`/`__TEXT_EXEC`/`__DATA_CONST`/`__DATA`, `PYLD` zeroed, `__DATA_SPTM` (0x54000) added,
`LC_UUID`/`LC_BUILD_VERSION`/empty `LC_DYLD_CHAINED_FIXUPS` added, `LC_UNIXTHREAD.pc` kept at
`_start` (`__TEXT_EXEC + 0x800`). No `LC_FILESET_ENTRY` (the packer does not add one). If iBoot
takes the kernelcache path for it, SPTM will be loaded first and m1n1 is not SPTM-aware yet; expect
a black screen and recover with the raw `go.sh` flow.

Result (same day): **kmutil refused the BootKC image as well** (registered via
`finish-install.sh --m1n1 m1n1.bootkc.macho --macho`, step2 in the stub's 1TR). Raw restored with
`go.sh` at 10:46. So the gate is kmutil in 1TR, before iBoot ever sees the file; packaging tricks
on the m1n1 side cannot pass it without knowing what kmutil checks. Next: capture the exact kmutil
error text, read `kmutil configure-boot --help` on macOS 27.2 for any flag that declares an
executable range for `--raw` images, and ask upstream whether any M4+ custom kernel was ever
registered without `--raw`.

Checked on macOS 27.2 afterwards: `kmutil configure-boot` has only `--raw`, `--entry-point`,
`--lowest-virtual-address` and `--compress`; there is no way to declare an executable range for a
raw object. `kmutil inspect --show-mach-boot-properties` shows the properties a real kernel
collection gets (ro/SPTM/boot-exec/rw/linkedit regions + entry); a raw object gets only entry and
lowest address. The stub's boot-object directory holds the kernelcache and trust caches only, no
SPTM/TXM. The signed artifacts kmutil writes are out of scope: the supported path is kmutil's own
custom-boot-object mechanism, and the question of what shape of Mach-O it accepts on M4+ goes to
upstream (Asahi / m1n1 developers).

## Dead ends (do not repeat)

- Hypervisor trace of macOS (omarchy-m5 rounds 1-9): XNU spins in `wfe` long before any CPU
  start; `CPUSTART unknown for this SoC` in the hv proxyclient; SPTM must be emulated anyway.
- RVBAR crumb, sled `bl`-chain crumb, sled slice-start crumb, RVBAR crumb with in-stub watchdog.
- APSC enable before release (bit already clear). PMGR release-order variants.
- Reading `cpm-impl-reg + 0x20020` (0x210e60020) hangs the bus; the DVFS block is
  `cpm-impl-reg - 0x40000` (0x210e00000), as the earlier cpufreq generator already used.

## Numbers worth keeping

| What | Value |
|---|---|
| PMGR CPU_START block | `pmgr reg0 + 0x88000`; `+0x0`/`+0x4` read 0x3fffe at rest, each release clears BIT(cpu-id) in both |
| cpu-impl-reg | `0x21X050000 + 0x100000*core`, size 0x9018; `+0x100` status |
| cpm-impl-reg / acc-impl-reg | `0x21Xe40000` (0xc020) / `0x21Xf00000` (0x40088) per cluster |
| DVFS block | `0x21Xe00000`; PSTATE `+0x20020` = 0x400106 / 0x400102 (bit 22 set, bit 23 clear) |
| SMP-RO window | `[top_of_kernel_data - 0xc000, top)`; CTRR-A = CTRR-B = window; CTXR-A/B/C = 3 x 0x4000 slices; CTXR-D = iBoot runtime just below m1n1 |
| `/chosen/memory-map` | `BootKC-rx` size 0, `BootKC-rw` = whole image (0x4d0000), `BootKC-entry` = base + 0x800 |
| kernelcache | `configMiscCores` body 0xfffffe0009883b94 (ApplePMGR vtable +0xd28); `enableCPUComplex` +0xd38; `enableCPUCluster` +0x898; T6050 `writeACCReg32` 0xfffffe0009cf0d5c (+0x1068) |
| SPTM | `sptm_register_cpu` 0xfffffff0270cd934; per-cpu init + CTRR/CTXR validation 0xfffffff0270cff20; `sptm_resume_cpu` 0xfffffff0270d1b64 |

Tools: `scripts/kc/` (kernelcache/SPTM helpers), `scripts/probes/` (hardware probes),
`scripts/wait-m1n1.sh` (wait for the M5 to come back after a watchdog reset), `docs/re/`.
