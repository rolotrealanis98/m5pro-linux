# What the macOS 27.3 pull is for, and the first RE step

Target: the GPU firmware interface of the M5 Pro (J716s, G17S). Aurora's drm/asahi (#1012) knows the
macOS 27.0 (26A428) M5 firmware and writes interface word `0x0c8e_0339_8728_04c0`
(`g17/fw/m5/initdata.rs:1654`, `M5_INITDATA_VERSION_WORD`). Our 27.3 stub's firmware compares root+0 with
`0x0c8e_4339_8728_04c0` (`armfw_g17x.im4p` file offsets 0x25509-0x25521, see
`contrib/pending/gpu/hwdata/ANALYSIS.md` section 1.3). The only difference is `0x0339` -> `0x4339`. The question is
what else moved between the 26A428 InitData graph and 27.3.

Everything the script pulls goes to the private tree (default `~/Work/studio-artifacts/macos-<ver>-<build>/`).
Layout: `fs/<original absolute path>` for copied files, `ioreg/` and `meta/` for text dumps, `MANIFEST.txt`
(sha256 + size). None of it goes in a repo.

## Run it

```
# the MacBook must be booted into macOS and reachable over Tailscale
HOST=rolo@<macbook-tailscale-ip> bash ~/Work/agents/macos-artifacts/pull-macos-27.3.sh --list     # inventory + sizes, copies nothing
HOST=rolo@<macbook-tailscale-ip> bash ~/Work/agents/macos-artifacts/pull-macos-27.3.sh ~/Work/studio-artifacts/macos-27.3/
```

It refuses an output directory inside a repo or under `~/Work/agents`, warns if `sw_vers` is not 27.3, aborts if the
estimate is above 20 GiB (`--yes` / `--max-gb N`), skips anything not readable as `rolo` and never prompts for a password
(ssh BatchMode). Expected size: well under 1 GiB (restore bundle about 65 MiB, kernelcache about 35 MiB, Metal
G17 bundles about 65 MiB, firmware dirs about 20 MiB each, ioreg about 15 MiB).

## What was checked on the Studio (macOS 27.2, 26B123), and what that means for 27.3

I read the Studio's own tree to size and shape the script. The same layout applies on the MacBook; verify on the
first `--list`.

1. **The G17 kexts under `/System/Library/Extensions` are stubs.** `AGXG17X.kext` is `Info.plist` +
   `version.plist` + `_CodeSignature` only (12 KiB), with no `Contents/MacOS` executable. The same holds for
   `AGXG17G`, `AGXG17P` and the `AGXFirmwareKextG17*RTBuddy` kexts. The code lives only in the kernel collection.
   The script copies the stubs anyway: their `Info.plist` gives the bundle IDs (`com.apple.AGXG17X`, class
   `AGXAcceleratorG17X`, provider `AppleARMIODevice`, `AGXArmFirmwareMapper`), the version (`362.5.1` on 27.2) and the
   library dependency list.
2. **`AGXG17X` is the M5 Pro/Max/Ultra GPU kext.** `AGXMetalG17X.bundle/Contents/Resources` carries
   `ds.binary.metallib.g17s-a0` and `...g17d-a0` (g17s = our part, g17d = Ultra). `AGXG17G` and `AGXG17P` are the
   A19-class parts. The Metal bundles are user-space GPU code, not the init-data builders.
3. **The restore bundle on Preboot holds the firmware.** On the Studio:
   `/System/Volumes/Preboot/<UUID>/restore/{BuildManifest.plist,kernelcache.release.<board>,Firmware/agx/armfw_g14d.im4p,Firmware/dcp,Firmware/pmp,Firmware/AOP,Firmware/all_flash,...}`
   and a sibling `restore-staged/` with a (possibly newer) staged copy. On the MacBook the AGX image is
   `Firmware/agx/armfw_g17x.im4p` (and `armfw1_g17x.im4p`), and your earlier read of `Firmware/t2026macG1/Release/`
   comes along because the script copies the whole `restore/` and `restore-staged/` directories.
4. **Two kernelcache flavours exist.** `restore/kernelcache.release.<board>` is a bare IM4P (starts `30 84 .. 16 04 "IM4P"`
   `"krnl"`). The one the machine boots is `boot/<policy hash>/System/Library/Caches/com.apple.kernelcaches/kernelcache`
   (an IMG4 wrapper around the same kind of payload, personalized) plus a `kernelcache.auxkc.<hash>`. `boot/active` and
   the `meta/preboot-boot-active.txt` dump say which policy hash is active. The stub's Preboot subdirectory (the Linux
   stub's own UUID) may carry its own copy of the 27.3 payloads: the script takes every Preboot UUID.
5. **`/System/Library/Kernels/kernel.release.t6050`** is a plain arm64e Mach-O kernel (no kexts inside). It is only
   useful for xnu-side cross-reference (IOKit, `IOGraphics`, mapper). The generic `kernel` is copied too.
6. **`kmutil inspect` works without root** on the IMG4 file directly (checked on the Studio):
   `kmutil inspect -z --no-variant-extension -B <kernelcache> --no-header` lists bundle ID, version and path of every
   kext in the collection. Useful flags: `--show-fileset-entries`, `--show-kext-load-addresses`, `--show-kext-uuids`,
   `--show-mach-header`, `--json`. `kmutil` has no extract subcommand (subcommands: create, rebuild, load, unload, log,
   libraries, dumpstate, inspect, clear-staging, configure-boot, find, showloaded, trigger-panic-medic). `kmutil create`
   builds collections and needs the kexts' executables, which only exist inside the collection, so it does not help.
   Use `ipsw` or `pyimg4` to extract.
7. **The Studio is not a baseline for G17X.** I checked: the Studio's BootKC (and its `restore/kernelcache.release.mac14j`)
   carries only its own SoC's GPU kext (`com.apple.AGXG14X`, `AGXFirmwareKextG14XRTBuddy`, `AppleMobileDispT602X-DCP`),
   although `/System/Library/Extensions` has stubs for every generation. So `AGXG17X` code exists only in a kernelcache built
   for a T6050/T6041-class machine: the MacBook's pull is the only local source. A 27.0 or 27.2 baseline would have to come
   from Apple's IPSW for the same board via `ipsw download` (partial download of just the kernelcache; check
   `ipsw download ipsw --help` for the exact flags, not run here).

## What each artifact is for

| Artifact (under `fs/` unless noted) | Holds | Use |
|---|---|---|
| `System/Volumes/Preboot/<UUID>/boot/<hash>/System/Library/Caches/com.apple.kernelcaches/kernelcache` | The BootKC (fileset Mach-O in IMG4/IM4P, LZFSE). Contains the real `com.apple.AGXG17X` kext: `__TEXT` code with the InitData builders, `__DATA` with the tables, `__TEXT_EXEC`, and the strings that name the structs | **Primary RE target.** Carve `com.apple.AGXG17X` (class `AGXAcceleratorG17X`, `AGXArmFirmwareMapper`) out of it |
| `.../restore/kernelcache.release.<board>` | Same kernel collection as a bare IM4P (what an IPSW would contain) | Easiest input for `ipsw`: no IMG4 wrapper |
| `.../restore/Firmware/agx/armfw_g17x.im4p`, `armfw1_g17x.im4p` | The GPU coprocessor firmware, an `rkosftab` with three variants (a010 = g17s, a000 = g17c, a020 = g17d). The init code compares root+0 with `0x0c8e_4339_8728_04c0` at file 0x25509-0x25521 | The **firmware side** of the interface. Pair every field the kext writes with what the firmware reads. `contrib/pending/gpu/hwdata/fw-layout.py` already splits the rkosftab and Mach-Os |
| `.../restore/Firmware/{dcp,pmp,AOP,ane,ave,scodec,all_flash,...}` and `Firmware/t2026macG1/Release/` | DCP, PMP, AOP, ISP, ANE, SEP, iBoot, DeviceTree im4p files and the restore trustcaches | Cross-reference for DCP/PMP work (PMP-J716S.md) and for the iBoot device tree. Not needed for the GPU init data |
| `.../restore/BuildManifest.plist`, `restore/SystemVersion.plist`, `fs/System/Library/CoreServices/SystemVersion.plist`, `meta/VERSION.txt` | Exact bundle/build identity (27.3 26C5035r, iBoot `mBoot-20457.60.65.0.1`) | Pin every finding to a build; compare with the stub's `12-firmware.txt` |
| `.../boot/<hash>/usr/standalone/firmware/{iBoot.img4,devicetree.img4,FUD,...}` | The booted iBoot, the device tree as IMG4, the FUD firmware set | Cross-check the ADT m1n1 sees against the one iBoot ships |
| `fs/System/Library/Extensions/AGXG17*.kext`, `AGXFirmwareKextG17*`, `AGXMetalG17*.bundle`, `AppleDCP*`, `IOMobileGraphicsFamily*`, `AppleMobileDispT605X-DCP.kext` | `Info.plist` stubs (kexts) and Metal libraries (bundles) | Bundle IDs, versions, dependency graph, personalities. Not code |
| `fs/System/Library/Kernels/kernel.release.t6050`, `kernel` | Plain xnu | Symbol cross-reference only |
| `ioreg/ioreg-l-w0.txt`, `ioreg/ioreg-IODeviceTree-l-w0.txt` | The device tree and IORegistry as macOS sees them, including `AGXAccelerator*` properties (the driver publishes `gpu-core-count`, `gpu-var`, perf-state tables, `core_mask_list`...) | What macOS derived at runtime: compare with the m1n1 ADT dump and with `t6050-pro-draft.rs` values. **Contains serials.** |
| `meta/kmutil-showloaded.txt`, `meta/kmutil-inspect-installed.txt` | Loaded kexts and the bundle list of the installed collections | Exact bundle IDs to feed `ipsw kernel extract` |
| `meta/nvram-*.txt`, `meta/diskutil-*.txt`, `meta/system-profiler-displays.txt` | Boot-selector variables (names only plus `boot-volume` etc.), APFS volume UUIDs, GPU summary | ASAHI-BLESS.md follow-up; sanity check of GPU core count |
| `MANIFEST.txt` | sha256 + size of everything | Reproducibility. Private dir only |

## Extracting a kext from a kernel collection (no root)

`kmutil` cannot extract (see above). Use these on the Studio (macOS, arm64) or any Linux box.

### Install

- **ipsw** (blacktop/ipsw): `brew install ipsw` (core formula, bottled, stable 3.1.743 as checked 2026-11-07). The
  maintainer's tap (`brew install blacktop/tap/ipsw`) needs `brew tap blacktop/tap` first. On Linux use the release
  tarballs from the project page. **Nothing is installed by the pull script.**
- **pyimg4** (only if you want the raw payload yourself): `pipx install pyimg4` (0.8.9 on PyPI). Not in Homebrew.
- **A disassembler:** Ghidra (a recent release; check that its Mach-O loader handles `MH_FILESET`) or `ipsw macho disass`; or IDA/Binary Ninja. Not in the pull.

### Steps

```
K=~/Work/studio-artifacts/macos-27.3/fs/System/Volumes/Preboot/<UUID>/restore/kernelcache.release.<board>   # bare IM4P
# or the booted one (IMG4): .../boot/<hash>/System/Library/Caches/com.apple.kernelcaches/kernelcache

# 1. what is in it (works on both flavours, no root)
kmutil inspect -z --no-variant-extension -B "$K" --no-header | grep -iE 'AGX|DCP|G17'
ipsw kernel kexts "$K" | grep -iE 'AGX|G17'

# 2. carve the kexts (full bundle ID). ipsw reads the IM4P/IMG4, decompresses and splits the fileset entry
mkdir -p ~/Work/studio-artifacts/macos-27.3/kexts
ipsw kernel extract "$K" com.apple.AGXG17X                -o ~/Work/studio-artifacts/macos-27.3/kexts
ipsw kernel extract "$K" com.apple.AGXFirmwareKextG17XRTBuddy -o ~/Work/studio-artifacts/macos-27.3/kexts
ipsw kernel extract "$K" com.apple.AGXFirmwareKextRTBuddy64   -o ~/Work/studio-artifacts/macos-27.3/kexts
# the Metal side is not in the kernelcache; the DCP side:
ipsw kernel extract "$K" com.apple.driver.AppleDCP        -o ~/Work/studio-artifacts/macos-27.3/kexts   # check the ID with step 1
```

If `ipsw` refuses an IMG4-wrapped file, give it the `restore/kernelcache.release.<board>` flavour, or unwrap first
(`pyimg4 im4p extract -i <file> -o kernelcache.raw` for IM4P, `pyimg4 img4 extract -i <file> -p kernelcache.im4p` for IMG4;
verify the subcommand names with `pyimg4 --help`, I have not run pyimg4). Both flavours carry the same kernel collection.
`ipsw kernel dec` (decompress) also exists in `ipsw kernel --help`, which I have not run either: check there for the exact
verbs before scripting it.

The kernel collection is a Mach-O fileset (`MH_FILESET`); each kext is a fileset entry named by its bundle ID.
`kmutil inspect --show-fileset-entries` prints them. A fileset entry carries its own `__TEXT`, `__TEXT_EXEC`,
`__DATA_CONST`, `__DATA` and `__LINKEDIT` segments; the carved kext keeps its segment load addresses, so pointers
in `__DATA_CONST` (vtables, chained fixups) are only valid with the collection's `__LINKEDIT` rebased. Load the whole
fileset in Ghidra instead of the carved piece when you need resolved vtables.

## The first RE step

Goal: find, in the 27.3 `com.apple.AGXG17X`, the code that builds the firmware's initialization graph, and diff the
field offsets against Aurora's version-gated structs.

1. **Locate the builders in the kext.**
   - Start from the interface word: search the kext's `__TEXT_EXEC` for the `movz/movk` sequence that materializes
     `0x0c8e43398728_04c0` (immediates `0x04c0`, `0x8728`, `0x4339`, `0x0c8e`). Aurora's 26A428 value has `0x0339` in
     the third halfword, so a search for `0x0339` finds nothing in 27.3 and a search for `0x4339` finds the 27.3 writer.
     The firmware compares it at root+0, so the kext stores it at root+0 of the init root.
   - Other anchors: strings with `Host and FW Interface is mismatched` (firmware side) and `InitData`/`initdata` in the
     kext, the `AGXArmFirmwareMapper` class (it maps the firmware segments, ties to `fw-text`/`fw-data` regions in the
     draft DT), and `AGXAcceleratorG17X` methods that allocate the shared/private cluster regions.
   - The ioreg dump names what the kext publishes: use it to tie property names to the code that fills them.
2. **Recover the root struct and its sub-objects.** Aurora models it as a root of `M5_ROOT_SIZE = 0xc8` bytes
   (region A, region C, per-instance main config, the hardware-data bundle, status blocks in the private cluster) with 24
   allocations sized by `ABI_ALLOCATION_SIZES_26A428_M5`. In the kext, find the 24 allocation size constants and the
   root writes. Compare each against the table below.
3. **Diff against Aurora's structs.** The 26A428 graph and the V25G83 graph are both in #1012. Files, on
   `refs/remotes/aurora-ro/pr1012-latest` of `/Volumes/linux-cs/linux` (use `git show refs/remotes/aurora-ro/pr1012-latest:<path>`;
   in zsh write `"${R}:path"` with braces, `$R:a` is a history modifier):

   | File (under `drivers/gpu/drm/asahi/`) | What it pins |
   |---|---|
   | `g17/fw/m5/initdata.rs` | The 26A428 M5 graph: `M5_INITDATA_VERSION_WORD` (:1654), `M5_ROOT_SIZE` 0xc8 (:1656), `ABI_ALLOCATION_SIZES_26A428_M5` (:1658, 24 sizes), shared/private cluster layouts, `RootProfile` enum with `J714G17S26A428` (:36), `COMMON26_HW_DATA_BANDS` (:1391), `encode_m5_hw_data` (:2232-2316), the `Board` perf/AON/register-window tables (:1757 onward) |
   | `g17/initdata/m5.rs` | The builder that fills those objects (`RootProfile::J714G17S26A428` at :210, root write at :221) |
   | `g17/fw/initdata.rs` and `g17/fw/initdata/v25g83.rs`, `g17/initdata/v25g83.rs` | The other graph (25G83, one instance with both roles) and its `INTERFACE_VERSION` `[0x04c0, 0x0396, 0xa322, 0x0c8a]` (`g17/fw/initdata.rs`). Shows how Aurora gates by firmware build |
   | `g17/fw/variant.rs` | `Variant`: `InitGraph::{G17P, V25G83}`, `InitAck::{Message, Status}`, queue pointer layouts, QID floor. The place a 27.3 variant would be added |
   | `fwid.rs`, `hw/t6050.rs` | Firmware identity (SHA-256 of fw-text with entropy/boot-filled ranges zeroed), per-board `Build` records. The 27.3 G17S identity goes here |
   | `g17/mod.rs` (`Gpu::new` :1451, `firmware_variant` :1668, `identify_image` :1701) | The order of checks: identity before any GPU write |

   For each struct: take the field offsets the 27.3 kext writes (store widths and immediates in the builder functions) and
   compare with the `unk_<offset>` / named fields of the Aurora type. Record differences as a table
   `(object, offset, aurora value, 27.3 value, kext function)`. The first differences to look for are the ones that
   change *size*: the 24 allocation sizes, `M5_ROOT_SIZE`, the HW-data size (`ABI_ALLOCATION_SIZES_26A428_M5[ALLOC_HW_DATA]`).
   A size change means the whole layout moved; a same-size table means only constants changed.
4. **Cross-check against the firmware.** For every offset the kext writes, find the firmware read in `armfw_g17x.im4p`
   (g17s variant a010; `fw-layout.py` gives the Mach-O). The gate at 0x25509 reads root+0; the code right after it walks
   the roots, so the next reads are the root layout.
5. **Bound the change.** edimoldovan saw `0x4339` on mBoot 41.3 and 60.65 (ANALYSIS.md), so it predates 27.3. If an older
   build's kernelcache for the same board is obtainable (IPSW via `ipsw download`), repeat steps 1-3 on it: 27.0 (Aurora) ->
   27.x (middle) -> 27.3 narrows which release moved the word and which layout fields moved with it.

Hypothesis, not a finding: `0x0339 -> 0x4339` changes one bit of the third halfword. If that field is a flag or a
sub-version rather than a hash, the graph may be unchanged apart from one added feature. The kext decides: look at how
the halfword is composed (constant, or `ORR` of a feature bit) before assuming a layout break.

## Do not

- Put anything the script fetched in a repo, a PR, a gist or a message. ioreg holds serials, the manifest holds hashes,
  and the kernelcache and firmware are Apple's.
- Run the pull while the MacBook is in Linux: it detects `uname -s` != Darwin and stops.
