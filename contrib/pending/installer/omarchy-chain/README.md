# Omarchy's boot chain on the J716s: test B1

Status: built on the Studio 2026-11-07, **not booted**. Nothing here touched the MacBook.

This is the one test boot that `../PLAN.md` asks for (phase 0b, "A: direct kernel" vs "B: Omarchy's
U-Boot/Limine chain"). Our A/B stage 1 stays as it is. It chainloads `m1n1/boot.bin`, which this test makes a
standard Omarchy stage 2 (m1n1 + DTBs + U-Boot). U-Boot then loads Limine from the ESP, and Limine boots the
87-patch daily kernel (`7.3.0-ga0f2f30c967b`) as an EFI image:

```
iBoot -> stage 1 (ours, A/B, 150 s watchdog) -> ESP m1n1/boot.bin = m1n1 stage 2 -> U-Boot -> ESP EFI/BOOT/BOOTAA64.EFI = Limine
      -> ESP m5chain/Image (EFI stub) + m5chain/initramfs-ftab.cpio.gz -> root on nvme0n1p5
```

The design follows edimoldovan's J714c disk boot: omacom/linux-aurora #293, m1n1 `5bb6965d99b1` on
`edimoldovan/m1n1 j714c/m1n1`, U-Boot `70e990818a` on `edimoldovan/u-boot j714c/t6050`.

## What was built

| Piece | Source | Build | Output (sha256) |
|---|---|---|---|
| m1n1 stage 2 | `j714c/m1n1` `5bb6965d99b1` + `patches/m1n1/0001-0004` (local branch `j716s/omarchy-chain` = `772ffa5e9619`) | m1n1-aurora's PKGBUILD flags: `EXTRA_CFLAGS=-Os RELEASE=1 CHAINLOADING=1 ESP_STAGE2=1 USE_CLANG=1`, rustc 1.89.0, **plus `-DT6050_NO_HOST_PREP`** | `m1n1-test.bin`, 4,259,840 B (0x410000, the same size as m1n1-aurora 1.6.1.aurora22's), `e3c2374f...` |
| U-Boot | `j714c/t6050` `70e990818a` | `apple_m1_defconfig` + `EFI_RT_VOLATILE_STORE` (uboot-aurora's one functional option), console on the panel (no silent console), **`WATCHDOG_AUTOSTART=n`**, `-DDEBUG` for `nvme_apple.c` and `board.c` | `u-boot-test-nodtb.bin`, 716,960 B, `8036ff2e...` |
| stage 2 payload | asahi-scripts 20261023-1 `update-m1n1`, unmodified, `LC_ALL=C` as omarchy-mac-boot sets it | `m1n1.bin` + 116 DTBs (linux-aurora 7.2.11.aurora15's 115 + our `t6050-j716s.dtb` `659af884`, glob order) + `gzip -c u-boot-nodtb.bin` + the `chosen.*` line of `m1n1.conf` (`chosen.m5pro,stage2=omarchy-chain-boot-b1`) | `boot-b1.bin`, 10,264,914 B, `2591da1f...` |
| Limine | Arch Linux ARM `extra` `limine-12.9.6-1` (what Omarchy's Apple images install; Omarchy's own repository ships no Limine). Package sha256 `09d6f6bc...` matches the repository database | none (the package's `BOOTAA64.EFI`) | 335,872 B, `11288bad...` |
| kernel | `Image-7.3.0-ga0f2f30c967b.gz` (`0f302e9a`, the daily's) | decompressed: `CONFIG_EFI_STUB=y`, no `EFI_ZBOOT`, so the EFI stub is the uncompressed PE | `m5chain/Image`, 49,875,456 B, `01c202b7...` |
| initramfs | the daily-wifi FTAB initramfs (`cffbbaf1`), unchanged | none; **private, never in this repository** | `m5chain/initramfs-ftab.cpio.gz`, 16,779,326 B |

Reference builds, not for deployment: `m1n1-ref.bin` (m1n1-aurora's exact flags, Ed's USB host prep on,
`7b7e7f39...`), `u-boot-omarchy-nodtb.bin` (uboot-aurora's exact recipe: quiet-console.patch, silent console,
no logo, watchdog autostart, `39558141...`, 707,992 B), and `boot-ref.bin` composed from both (`0b0cc9b4...`).
All six outputs reproduced byte for byte in a second, separate container run (U-Boot with `SOURCE_DATE_EPOCH`).
Full hashes: `SHA256SUMS`.

Toolchain: Fedora 43 arm64 in Apple `container`; clang/lld 21.1.8, rustc 1.89.0 (m1n1); gcc 15.3.1, binutils
2.45.1, dtc 1.7.2 (U-Boot, native aarch64, no cross prefix). Fedora needs `openssl-devel-engine` for U-Boot's
host tools (Arch carries `openssl-no-engine.patch` instead).

### The m1n1 changes (patches/m1n1)

Checked against the J716s list of what our lineage needs:

| Need | In Ed's tree? | Here |
|---|---|---|
| CPU_START one bit per core | yes (`smp: T6050 releases one CPU per bit`) | his |
| `/arm-io/i2c` limit 16 | yes | his |
| NVMe split BAR / 0x30000 aperture | yes (same addresses on J716s and J714c) | his |
| notch (`chosen.asahi,show-notch`) | yes (integration/aurora) | his; **not set** in this payload, so U-Boot's and Limine's text is not under the notch |
| RVBAR relay for a stage 2 placed above the CTRR window | no | `0001` (= omacom/t6050-bringup `da96fed`) |
| keep the stage-1 watchdog (`m1n1.wdt=keep`) | no | `0002` (= `omacom/wdt-keep-standalone`) |
| Type-C: PIPE park, combo-PHY tunables from the ADT | no | `0003` (our 0020), `0004` (our 0021): our DTB carries no tunables, the kernel's PHY driver needs them |
| USB-PD HPM power-up | yes (our 0018 was ported from it) | his |
| USB 2.0 host prep | his only | built out (`-DT6050_NO_HOST_PREP`): our kernel drives the combo PHY and dwc3 itself, and our daily stage 2 never ran a host prep |
| N1 hand-off | no | **not included**: our kernel adopts a port m1n1 trained but does not train it (Ed's kernel-side training, 0f96cc6c00e1 + 17ada56a25c9, is not in the 87-patch series). So no Wi-Fi in this test: SSH over the USB Ethernet adapter. The omacom N1 port does not cherry-pick onto Ed's tree (`kboot.c` conflict) |
| GPU / display hand-offs | no | not needed for this test (simple framebuffer) |

### The NVMe hand-over with our stage 1

Ed's chain marks a live ANS session for U-Boot: his stage 1 leaves the RTKit session running and passes
`nvme.adopt=live-rtkit-v1`; his stage 2 (`5bb6965d99b1`) turns that into `/chosen/asahi,nvme-adopt`, and U-Boot
(`70e990818a`) then adopts instead of starting a handshake. **Our stage 1 does not do this.** It stops ANS
(RTKit sleep, CPU stop, PMGR reset request) and passes no `nvme.adopt`, so B1's stage 2 sets no marker and U-Boot's
T6050 driver takes its other path: set `CPU_CTRL.RUN` and run a fresh RTKit boot handshake on the stopped
coprocessor. That is what our kernel does on every daily boot after the same stage 1 ("post-M4 firmware handoff:
restarting stopped ANS without reset" in `drivers/nvme/host/apple.c`), but U-Boot has not done it on T6050 hardware
yet (Ed's working path is the adopt path). After U-Boot, the kernel adopts the session U-Boot leaves enabled
(`apple_nvme_can_adopt_rtkit()`: RUN, boot status OK, CC.EN and CSTS.RDY), and U-Boot reserves its RTKit buffers as
`/reserved-memory/ans-rtkit@*`.

### Watchdog and fallback

- Stage 1 arms the SoC watchdog for 150 s and appends `m1n1.wdt=keep`; B1's stage 2 leaves it armed (`0002`).
- The test U-Boot is built with `WATCHDOG_AUTOSTART=n`: it prints `WDT: Not starting watchdog@28836c000` and neither
  re-arms nor feeds it. (Omarchy's U-Boot re-arms it for 60 s and feeds it from every polling loop, so a U-Boot that
  cannot boot and sits at "Nothing could be booted" would never be reset.)
- Limine does not touch it. The kernel's `apple_wdt` finds it running and keeps it fed.
- So **any hang between stage 1 and the kernel's watchdog probe resets the SoC 150 s after stage 1's hand-over**,
  iBoot counts a failed boot, and stage 1 boots `boot.bin.prev` (the daily) by itself. That is the only automatic
  fallback: this payload has no Linux inside, so there is no `m5.selftest` self-revert (and the kernel command line in
  `limine.conf` carries none, as asked). A kernel that comes up but without network stays up: power-button hold
  (10 s), and the next power-on falls back.
- Neither U-Boot nor Limine gets a keyboard on T6050 (U-Boot leaves the MTP to Linux and does not start USB), so the
  Limine menu cannot be used; the default entry boots after 5 s. To try the second entry, set `default_entry: 3`
  in `/boot/limine.conf` before the boot.

## ESP contents and space

| ESP path | Size | Public |
|---|---|---|
| `m1n1/boot.bin` | 10,264,914 B (B1; was the daily, which moves to `boot.bin.prev`) | yes |
| `EFI/BOOT/BOOTAA64.EFI` | 335,872 B (Limine 12.9.6) | yes |
| `limine.conf` | 1,993 B (generated by `mk-esp.py`, BLAKE2B hashes on every path, `hash_mismatch_panic: yes`) | yes |
| `m5chain/Image` | 49,875,456 B | yes |
| `m5chain/initramfs-ftab.cpio.gz` | 16,779,326 B | **no** (FTAB) |

`limine.conf` has two entries under `/+Omarchy chain test`, as omarchy-mac-boot lays out its menu:

1. default (`default_entry: 2`): `protocol: efi`, `path: boot():/m5chain/Image`, `cmdline: initrd=/m5chain/initramfs-ftab.cpio.gz m5.chain=limine-efi <bootargs>`. Limine starts the kernel's EFI stub with `LoadImage`/`StartImage`; the stub loads the initramfs from the ESP (`initrd=` is built into 7.3's stub), takes the device tree from U-Boot's EFI table and exits boot services itself. This is Omarchy's path (`protocol: efi`), except that Omarchy wraps kernel, initramfs and command line in a UKI (systemd-stub hands the initramfs over by LoadFile2 instead of `initrd=`).
2. `protocol: linux`: Limine loads the same Image and initramfs, writes `/chosen` and the UEFI memory map itself and exits boot services; `m5.chain=limine-linux`.

Neither entry has `dtb_path`: the device tree is m1n1's prepared J716s tree, which U-Boot uses as its own control tree
and passes on (`bootefi ${kernel_addr_r} ${fdtcontroladdr}`); U-Boot adds its fixups (reserved memory, ESP) to it.

`<bootargs>` = the daily's (`daily-wifi-20261107-4feff24c`): `earlycon=efifb keep_bootcon console=tty0 loglevel=8
pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5
kvm-arm.wfi_trap_policy=trap pcie_aspm=off`, plus `root=/dev/nvme0n1p5`. The initramfs mounts `m5.root=`; the kernel
ignores `root=` while `/init` exists. `pcie_aspm=off` is the N1 line on the kernel side; the m1n1 side
(`chosen.m5pro,n1=4`) has no code in this stage 2. No `m5.selftest`.

Space: the five files are 73.7 MiB; the net change is about +38 MB (B1 replaces a 39 MB daily in `boot.bin`, the
daily replaces the old `boot.bin.prev`). From about 140 MB used of 476 MB that is about 180 MB; the deploy checks for
the files plus 64 MB of free space (the `.new` copies). A full Omarchy stage 2 with all 115 linux-aurora DTBs is
10.3 MB, so the 116 DTBs in B1 also test that size against stage 1's placement (it may land above the CTRR window;
`0001` covers that).

## Deploy (coordinator)

Run from the Studio, with the machine on the **daily, primary slot** (not a test, not a fallback boot):

```sh
cd ~/Work/agents/omarchy-chain                  # build.sh and mk-esp.py have run (out/, private/)
HOST=root@<macbook-ip> bash deploy-OMARCHY-CHAIN-B1.sh
```

It checks the state (no `m5.selftest`, `m5pro,boot-slot` = primary, no existing `EFI/BOOT/BOOTAA64.EFI`,
`limine.conf` or `m5chain/`, at most four payloads, free space), copies every file to a `.new` name, checks each
sha256, moves them into place, makes `boot.bin.prev` = the running daily and `boot.bin` = B1 (both verified),
unmounts and remounts `/dev/nvme0n1p4` and hashes everything again, and records the before/after hashes in
`deploy-state.txt`. It does not reboot.

Then an **attended cold start**: `systemctl poweroff`, wait 15 s, press the power button, watch the panel. A warm
restart is not enough: B1's stage 2 has no warm-N1 entry (our 0027), and a loader without it hangs once after a
restart with the N1 in use (RUN-W4, 2026-11-07); that would read as a B1 failure.

## What the panel should show, hop by hop

| Hop | Expected | Bad sign |
|---|---|---|
| stage 1 (ours) | `chainload: PMU boot_stage ..., boot errors 0`, `chainload: slot primary: <ESP>;m1n1/boot.bin`, `chainload: Total image size: 0x...` (about 0x9d0000 plus SEPFW), possibly `... would cover the secondary-only CTRR range ..., relocating to 0x...`, `Primary WDT armed: reset in 150 s ...` | `slot primary failed` (the file did not read: the first-boot-of-a-new-file case, see below) |
| stage 2 (B1's m1n1 `v1.6.1-404-g772ffa5`) | banner, `Primary WDT left armed (m1n1.wdt=keep)`, `Found variable chosen.m5pro,stage2=omarchy-chain-boot-b1`, `Devicetree compatible value: apple,j716s`, `Found a devicetree for apple,j716s at ...`, `Found a gzip compressed payload at ...`, `Found a kernel at ...` (that is U-Boot), possibly `SMP: installed RVBAR relay at ...`, `T6050 host prep skipped`, `FDT prepared at ...`, `Preparing to boot kernel at ...` | `ERROR: Kernel found but no devicetree`, `Primary WDT disabled` |
| U-Boot 2026.07 (Nov 07 2026 - 00:00:00 +0000) | banner and logo, `Model: Apple MacBook Pro (16-inch, M5 Pro, 2026)`, `DRAM: 48 GiB`, `WDT: Not starting watchdog@28836c000`, `nvme@45dcc0000: starting the RTKit session of the ANS (CC 0x... CSTS 0x...)`, then a byte count for `BOOTAA64.EFI` and the screen changes | `ANS RTKit handshake failed (-N)`, `ANS did not report ready after the handshake`, `AURORA_UBOOT_BOOT: fallback`, `AURORA_UBOOT_BOOT_FAIL: no bootable entry`, `Nothing could be booted.` |
| Limine 12.9.6 | "Omarchy Bootloader (J716s chain test)", directory "Omarchy chain test" with the two J716s entries, a 5 s countdown; then (verbose) the Image load and, from the EFI stub, `EFI stub: Loaded initrd from command line option`, `EFI stub: Exiting boot services...` | a Limine panic (`hash mismatch`, `Failed to open image`), `LoadImage failure` |
| kernel | the usual daily console from `earlycon=efifb` on: `Machine model: Apple MacBook Pro (16-inch, M5 Pro, 2026)`, `efi: EFI v2.x by Das U-Boot`, then the initramfs `cmdline: ...` line, `m5.root` mount, login | nothing after `Exiting boot services` (handled by the 150 s watchdog) |

## Reading the result

```sh
HOST=root@<macbook-ip> bash check-OMARCHY-CHAIN-B1.sh | tee check-$(date +%Y%m%d-%H%M).log
```

PASS = SSH up (over the USB Ethernet adapter: no Wi-Fi in this test) on the daily kernel, and:

- `/proc/cmdline` has `m5.chain=limine-efi` (or `-linux` for entry 2);
- `/proc/device-tree/chosen/m5pro,stage2` = `omarchy-chain-boot-b1`, `m5pro,boot-slot` = `primary`;
- `/proc/device-tree/chosen/` shows the loaders: `linux,uefi-system-table`, `linux,uefi-mmap-*` (EFI boot),
  `u-boot,version`; `asahi,nvme-adopt` absent (expected with our stage 1);
- `dmesg`: `efi: EFI v2.x by Das U-Boot`, `EFI stub: Loaded initrd from command line option`;
  `/sys/firmware/efi/efivars/LoaderInfo-*` = `Limine 12.9.6`;
- `nproc` 18, `/` = `/dev/nvme0n1p5`, `/reserved-memory/ans-rtkit@*` present (U-Boot started the ANS session).

FALLBACK = the daily answers with `m5pro,boot-slot` = `fallback-after-failure`. Read the panel notes to see which hop
stopped. If nothing stopped visibly (stage 1 printed `slot primary failed`, or the boot just restarted), it may be
the known first-boot-of-a-new-file fallback (RESULTS.md, about 1 in 4 new files today): `boot.bin` is still B1, so
cold-start once more before calling it a failure.

## Cleanup

From whichever boot answers (B1 through Limine, or the daily after a fallback):

```sh
HOST=root@<macbook-ip> bash cleanup-OMARCHY-CHAIN-B1.sh
```

It restores `boot.bin` from `boot.bin.prev` (checked against the daily's hash in `deploy-state.txt`), deletes
`EFI/BOOT/BOOTAA64.EFI`, `limine.conf` and `m5chain/`, remounts and re-hashes. `boot.bin.prev` stays the daily; the
pre-test prev's hash is printed if it should be copied back. From macOS: `host/macos/r1-deploy.sh restore prev`, then
delete the three entries on `/Volumes/OMARCHY` by hand.

## Risks

1. **NVMe hand-over.** U-Boot runs a fresh RTKit handshake on the ANS our stage 1 stopped; that U-Boot path has
   not run on T6050 hardware (Ed's runs the adopt path). If it fails, U-Boot prints the handshake error, finds no ESP
   and sits; the watchdog brings back the daily. Next step then: port Ed's stage-1 hand-over (keep the session live,
   pass `nvme.adopt=live-rtkit-v1`) into our A/B stage 1, which is a stage-1 ceremony.
2. **ESP space**: about 180 of 476 MB after the deploy, fine for the test. A real install with a UKI per kernel,
   `boot.bin.old` and vendorfw needs the measurement `../PLAN.md` section 5 row 3 asks for.
3. **U-Boot's DT is ours.** U-Boot has no J716s tree; it runs on m1n1's prepared J716s tree (from the 87-patch
   series, not #404's J714c tree). The drivers it binds there were checked by compatible: `apple,t6050-nvme-ans2`
   (T6050 profile), `apple,t6050-sart`, `apple,asc-mailbox-v4`, `apple,t8103-wdt`, simple-framebuffer, pinctrl,
   pmgr; our `apple,t6050-pcie` matches no U-Boot driver (not touched), and the T6050 MTP is left to Linux. Our DT has
   no ANS power domain, which U-Boot does not need. U-Boot uses the T6040 memory map for T6050 (Ed's J714c values;
   the J716s ADT has the same NVMe and NVMMU addresses). Limine and the kernel get the same tree plus U-Boot's fixups.
4. **No Linux-side self-test.** Only stage 1's watchdog protects this boot, and only until `apple_wdt` probes. A
   kernel that boots without network needs a person (power-button hold) or macOS.
5. **No Wi-Fi, warm N1.** No N1 code in B1's stage 2: SSH needs the USB Ethernet adapter, and the boot must be a cold
   start.
6. **Not quite Omarchy's binaries.** U-Boot: console on the panel, no watchdog autostart, two files with `DEBUG`;
   m1n1: host prep built out, four J716s commits. Layout, Limine, `update-m1n1` and the EFI path are Omarchy's.
   Entry 1 boots the bare EFI-stub Image, not a UKI.
7. **First boot of a new file** may fall back once (open issue); the deploy remounts and re-hashes, and a fallback
   with no visible hang gets one retry.

## Files

- `build.sh` - container build: both m1n1s, both U-Boots, both payloads through `update-m1n1`.
- `mk-esp.py` - stages `out/esp/` (public) and `private/esp/` (the FTAB initramfs) and writes `limine.conf`.
- `deploy-OMARCHY-CHAIN-B1.sh`, `check-OMARCHY-CHAIN-B1.sh`, `cleanup-OMARCHY-CHAIN-B1.sh` - coordinator steps.
- `patches/m1n1/` - the four J716s commits on top of `j714c/m1n1` (`git am` reproduces tree `9ed978b3`).
- `SHA256SUMS` - pinned inputs and the built outputs.

The scripts expect the work directory `~/Work/agents/omarchy-chain` (override with `OMARCHY_CHAIN_WORK`): `u-boot/`
(blobless clone of edimoldovan/u-boot at `70e990818a`), `inputs/` (the verified packages, `update-m1n1`,
`functions.sh`, the 116 DTBs, uboot-aurora's `quiet-console.patch`), `out/`, `private/`.
