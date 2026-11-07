# Omarchy on the M5 Pro through Omarchy's own tooling: productisation plan

Status: study, 2026-11-07. Written on the Studio; nothing was run on the MacBook and no omacom code was
executed. Board: MacBook Pro 16-inch M5 Pro, Mac17,8, `J716sAP`, T6050.

Sources read (read-only clones):

| Repository | Commit | What was read |
|---|---|---|
| omacom/omarchy-mac-installer | `c07e54c` (2026-11-06) | `README.md`, `scripts/supported-models.json`, `scripts/supported_models.py`, `Engine/README.md`, `Engine/installer_data.json`, `Engine/patches/0001-omarchy-engine-runtime.patch`, `Engine/overlay/src/omarchy_asahi.py`, `omarchy_firmware.py`, `omarchy_execution.py`, `Recovery/README.md`, `image-builder/README.md`, `docs/one-image-m123-neo.md`, `docs/mac-release-pipeline.md`, `evidence/` (listing) |
| omacom/omarchy-mac-pkgs | `3045124` (2026-11-05) | `README.md` (package contract), `omarchy-mac-boot/README.md`, `entrypoints/`, `files/` (initcpio hooks, `update-m1n1` defaults, vendorfw units) |
| omacom/omarchy-pkgs | `ed5bf6d` (2026-11-07) | `README.md`, `release/mac-inventory.txt`, `pkgbuilds/{linux-aurora,m1n1-aurora,uboot-aurora,omarchy-mac-boot,omarchy-aurora-firmware}` |
| omacom/omarchy-mac | `7cb792e` (2026-11-03, `quattro`) | `README.md` (the Asahi Alarm flow) |
| omacom/linux-aurora | `6a08a08e5` (2026-11-06) | `Makefile` (7.2.11), `.github/workflows/kernel-ci-jobs.yml`, `.github/AURORA_ROADMAP.md`, `drivers/base/firmware_loader/main.c`, DT list; releases `aurora-2026.10.11.13` .. `aurora-2026.10.17.20`; PR #404, issue #293 |
| omacom/m1n1 | `121fcbf` (2026-11-04) | `src/stage1_config.c`, `src/payload.c`, `Makefile`, T6050 references; PRs #26, #27 |
| this repo | `9d1a564` | `README.md`, `contrib/validated/aurora/STATE.md`, `series/SERIES.md`, `series/j716s.config`, `tools/ESP-POLICY.md`, `contrib/distro/` (DESIGN, GAPS, CHECKLIST), `contrib/validated/integration/RESULTS.md`, `host/macos/`, the N1 and FTAB notes |

Claims marked **[unverified]** were not confirmed in source or on hardware.

## Summary

- Omarchy's Mac path is already board-table driven: the engine has per-device firmware entries
  (`CHIP_MIN_VER`, `DEVICES`, `IPSW_VERSIONS`), a per-board Stage 1 table (`BOARD_STAGE1`, raw Aurora
  Stage 1 filled in place), a per-board Stage 2 table (`BOARD_STAGE2`), per-board OS firmware pinning
  (`os_firmware`, `supported_fw`) and a `developer` catalog class. The MacBook Neo was added through
  exactly these tables. The M5 Pro fits the same seams; nothing in the installer needs a new concept
  except one firmware step (the N1 FTAB) and one Stage 2 kind (kernel inside the payload).
- The kernel is the long pole. Omarchy builds only `omacom/linux-aurora` (7.2.11). Our 87-patch J716s
  series sits on `aurora-silicon/linux` `integration/aurora` 7.3.0 (`33bec4016c46`), a commit omacom's
  tree does not contain. A T6050 base PR for omacom (#404, J714c) was opened today; the J716s board and
  the rest of our series should ride on it.
- New data point: omacom/m1n1 #26/#27 report a J714c (M5 Max) booting m1n1 -> U-Boot -> Limine ->
  Omarchy login with 18 CPUs. If that reproduces on the J716s, "no U-Boot" stops being a requirement
  and the M5 can join Omarchy's unchanged U-Boot/Limine/LUKS/snapshot chain; only Stage 1, the kernel
  and the firmware stay board-specific. Not reproduced here.
- The 27.3 requirement is about the stub's stage-2 mBoot (raw boot objects get all cores only from
  macOS 27.3 beta 1, 26C5035r). It also pins the GPU and DCP firmware the kernel must speak, because
  iBoot preloads them from the stub's restore bundle. The catalog, the kernel and m1n1 must agree on
  that firmware build.
- **Recommended first step:** open the J716s board PR on omacom/linux-aurora stacked on #404 (draft in
  section 4.2), and in the next loop session on the MacBook boot one test payload that is the standard
  Omarchy Stage 2 (m1n1 + DTB + U-Boot) behind our A/B Stage 1, so a hang falls back to the daily. That
  one boot decides between the two Stage 2 designs below.

## 1. How Omarchy boots a Mac today, and what the M5 Pro needs

### 1.1 Omarchy's chain (M1, M2, M3, MacBook Neo)

1. **macOS app** (`omarchy-mac-installer`): SwiftUI app and a privileged helper. It reads a signed
   channel catalog (Ed25519, `https://mac.omarchy.org/v1/catalog-<channel>.signed.json`), downloads the
   pinned engine and the image zip (`esp/`, `boot.img`, `root.img`) and checks digests.
2. **Engine**: the pinned Asahi installer (`v0.9.2-omarchy.N`) plus an overlay. It shrinks the macOS
   container and creates: the stub (APFS), an EFI partition (FAT32, 524,288,000 bytes = 500 MiB,
   `OMARCHYESP`), a 2 GiB `Boot` partition (ext4) and the root (btrfs; LUKS is applied at first boot).
   The stub's OS firmware comes from an Apple restore image fetched by authenticated byte ranges from
   `updates.cdn-apple.com`; which build is decided by `supported_fw` (today `13.5`, `14.8.3`, `26.6.2`).
3. **Stage 1**: m1n1 enrolled as a raw boot object (`kmutil configure-boot -c boot.bin --raw
   --entry-point 2048 --lowest-virtual-address 0`, after `bputil -nc`) by the native Recovery app in
   the stub's paired 1TR. Default is Asahi's Stage 1 (appended variables). `BOARD_STAGE1` overrides it
   with Aurora's raw Stage 1 (`m1n1-aurora`'s `m1n1-raw.bin`), whose `AURORA-S1-CFG01` block is filled
   in place with the ESP PARTUUID, the Stage 2 path and a proxy window (`j700ap`; `j613ap` on 26.6.2).
4. **Stage 2**: `ESP:m1n1/boot.bin` = m1n1 stage 2 + every kernel DTB + U-Boot, composed by
   asahi-scripts' `update-m1n1` (pacman hook `95-m1n1-install.hook`), with `chosen.*` lines from
   `/etc/m1n1.conf`. The previous image is kept as `m1n1/boot.bin.old`. `BOARD_STAGE2` lets one image
   carry a board's own prebuilt Stage 2 (`esp/m1n1/boot-j700.bin` for the Neo).
5. **U-Boot** (`uboot-aurora`, EFI with a volatile variable store) -> **Limine**
   (`EFI/BOOT/BOOTAA64.EFI`) -> **UKI** `EFI/Linux/omarchy_linux-aurora.efi` (kernel, mkinitcpio
   initramfs, command line) -> LUKS unlock -> btrfs root.
6. **Firmware**: the engine writes `vendorfw/firmware.tar`, `firmware.cpio` and `manifest.txt` to the
   ESP. In the initramfs the `asahi` and `omarchy-vendorfw` hooks find the ESP through
   `/chosen/asahi,efi-system-partition` and unpack it to `/lib/firmware/vendor`, which is first in
   `linux-aurora`'s firmware search path (`drivers/base/firmware_loader/main.c:474`). Per-machine radio
   files for the Neo come from a pinned 26.6.2 range recipe; `omarchy-aurora-firmware` blacklists the
   radio modules until the files exist and admits them afterwards.
7. **Updates**: pacman from `https://pkgs.omarchy.org/<edge|rc|stable>/aarch64`. A kernel update
   reruns `update-m1n1` and rebuilds the UKI; `omarchy update` runs `update-verify` (a byte-for-byte boot
   check of the next boot) before it offers the reboot. Rollback is the Limine menu and snapper
   snapshots (`limine-snapper-sync`), or `boot.bin.old` copied back from macOS.
8. **Recovery**: the native Recovery app on the stub keeps a per-install baseline (Stage 2 and
   vendorfw) and `aura recover` restores it as one transaction.

`omacom/omarchy-mac` (`quattro`) is the older path: the Asahi Alarm installer (`curl | sh` from macOS),
then a one-command setup in Linux. It is transitional and takes no new boards.

### 1.2 The J716s chain that boots today

| Piece | Omarchy (M1-M3, Neo) | J716s (proven on the machine) |
|---|---|---|
| Stub OS firmware | IPSW 13.5 / 14.8.3 / 26.6.2 by board | **27.3 beta 1 (26C5035r) or later only**: older stage-2 mBoot gives a raw boot object one core (`docs/smp-t6050-raw-path.md`). Our stub was cloned from the running macOS's Preboot restore bundle (`prep-stub.sh`), not from an IPSW |
| Stage 1 | raw m1n1, Asahi vars or Aurora config block, optional proxy window | raw **CHAINLOADING** m1n1, <= 0x430000 padded to 64 KiB, `chainload=<ESP>;m1n1/boot.bin` plus the **A/B** variables of `patches/m1n1-stage1/0016`: `chainload.fallback=<ESP>;m1n1/boot.bin.prev`, `chainload.wdt=150`; reads iBoot's PMU boot-error count, falls back after a failed boot, clears the count |
| Stage 2 | m1n1 + DTBs + U-Boot | **one file**: m1n1 (0x400000) + `chosen.*` lines + `Image.gz` + J716s DTB + gzip initramfs (`tools/mk-daily.py`). No U-Boot, no Limine, no UKI, no EFI |
| m1n1 | omacom/m1n1 `integration/aurora` | AsahiLinux/m1n1 `7cde7d1a` + `patches/m1n1/` (chainload relocation 0013-0015, notch 0017, USB-PD 0018, PIPE park 0020, combo-PHY tunables from the ADT 0021) + N1 training 0022-0027 + GPU/DCP hand-off in test |
| Kernel | `linux-aurora` 7.2.11, modules, mkinitcpio | Aurora 7.3.0 + 87 patches, every needed driver `=y`, no modules loaded |
| Firmware | vendorfw on the ESP, per-board radio recipes | the N1 FTAB with `centauri.j716sap.im4m` stitched into its ticket slot, inside the initramfs (`APPLE_CENTAURI=y` reads it before userspace). GPU and DCP firmware are preloaded by iBoot from the stub's bundle |
| Root | btrfs, LUKS at first boot, `root=UUID` | ext4 on `nvme0n1p5`, `m5.root=`, no encryption |
| Rollback | Limine menu, snapshots, manual `boot.bin.old` | automatic A/B in Stage 1 (it has fired for real), self-reverting test payloads, `host/macos/r1-deploy.sh restore prev|known-good` from macOS |
| ESP | 500 MiB | 500 MB (476 MiB), at most four payloads (`ESP-POLICY.md`) |

### 1.3 The U-Boot data point

omacom/m1n1 #26 (T6050 CPU release, NVMe window, MTP DAPF, cpufreq) and #27 (a Stage 1 that carries
its own next stage takes only the proxy window from the config block) report, for a J714c (M5 Max,
Mac17,7): "m1n1 -> U-Boot -> Limine -> Omarchy login, no cable: EFI, 18 CPUs: pass". U-Boot was
appended to Stage 1 itself, not chainloaded from the ESP. Which stub firmware that machine runs is not
stated (the PR text gives system firmware 20457.60.65.0.1, which is the 27.3 beta 1 LLB, next to
"macOS 27.2"). Which U-Boot tree and patches gave NVMe on T6050 is not stated either. **[unverified]**

Consequence: two Stage 2 designs are open for the M5 Pro.

| | A. Direct kernel (ours) | B. Converge on U-Boot/Limine |
|---|---|---|
| Proven on J716s | yes, daily since 2026-11-05 | no |
| `omarchy-mac-boot` changes | a board mode: Stage 2 composer, boot check, no Limine activation, gzip initramfs | none |
| Kernel updates | rebuild `boot.bin`; A/B Stage 1 rolls back a bad kernel automatically | UKI rebuild; rollback through the Limine menu (needs a person at the keyboard) |
| Snapshots, `bootctl`, boot menu | not available | Omarchy's, unchanged |
| LUKS | works (mkinitcpio unlock inside the payload) | Omarchy's, unchanged |
| Extra dependencies | none | U-Boot with T6050 NVMe, keyboard, framebuffer; Stage 2 size with U-Boot |

### 1.4 The smallest change to Omarchy's flow

Common to A and B (installer engine overlay and data, `omarchy-mac-installer`):

1. `Engine/patches/0001-omarchy-engine-runtime.patch`, as the Neo was added:
   `CHIP_MIN_VER[0x6050] = "27.3"`; `DEVICES["j716sap"] = Device("27.3", False)`; an
   `IPSW("27.3", "27.0", "mBoot-20457.60.65.0.1", <sfr>, False, ["j716sap"], <26C5035r restore URL>)`
   entry (field order as the Neo's: version, minimum macOS, minimum iBoot, minimum SFR, expert-only,
   devices, URL). The `min_iboot` check then refuses a Mac whose system firmware is older, with
   `FirmwareRequirementError` naming macOS 27.3.
2. `BOARD_STAGE1["j716sap"] = BoardStage1("esp/aurora/stage1-j716s.bin", 0, "27.3", "a 16-inch M5 Pro
   MacBook Pro on macOS 27.3")`, the image staging that Stage 1 from `m1n1-aurora`. The Stage 1 must be
   a T6050-capable CHAINLOADING build within the measured envelope (<= 0x430000 after padding) and carry
   the A/B fallback and watchdog. Window 0: no proxy window on a user's machine.
3. `installer_data.json`: add `"27.3"` to `supported_fw`.
4. A firmware step for the N1 FTAB (section 2.6).
5. `scripts/supported-models.json`: `apple,j716s` under `developer` first (section 3.1);
   `MacModelNames.swift`: the model name.
6. The Recovery app needs no change: it accepts raw mode and `m1n1/boot.bin` only, which both designs
   use; `aura recover` restores whatever Stage 2 the baseline holds.

Only for A:

7. `BOARD_STAGE2["j716sap"] = "esp/m1n1/boot-j716s.bin"`, built by the image builder with the A
   composer. The image's partition UUIDs are fixed at build time (`build-mac-image` passes `-U`), so the
   first payload's command line is known before install.
8. `omarchy-mac-boot`: a "direct" board mode selected from the live device tree (`apple,t6050` plus
   `apple,j716s`), in the same selector seam the Neo design used (`/etc/default/update-m1n1` sources a
   board file): compose `m1n1 stage 2 | chosen.* | Image.gz | t6050-j716s.dtb | initramfs.gz`,
   rotate `boot.bin.prev` only from a primary-slot boot that reached `boot-complete.target`, write with
   an unmount/remount and re-hash before reboot (section 5, row 2), make `update-verify` rebuild and
   compare it, skip Limine activation in `setup-boot`, and force `COMPRESSION="gzip"` (m1n1 parses gzip
   and xz, not zstd) for this board only. Our prototypes: `contrib/distro/pkg/m5pro-boot/`,
   `contrib/validated/aurora/tools/mk-daily.py`, `contrib/pending/boot-ab/prototypes/rootfs/m5-boot-slot`.

Only for B:

7. U-Boot T6050 support in `uboot-aurora`, and either an ESP Stage 2 small enough for the chainload
   or #27's "U-Boot inside Stage 1" layout. `omarchy-mac-boot` unchanged. Our A/B Stage 1 still points
   at `m1n1/boot.bin`, with `m1n1/boot.bin.old` (which `update-m1n1` already keeps) as the fallback.

Recommendation: ship A on the developer catalog, because it is what boots, and run the B test boot
early (section 4.1, phase 0). If B boots and holds NVMe, keyboard and the panel, move the M5 to B before
it leaves `developer`, and keep A as the board's fallback payload.

## 2. Kernel packaging

### 2.1 How `linux-aurora` is built and shipped

- Recipe: `omarchy-pkgs/pkgbuilds/linux-aurora/PKGBUILD` pins one `omacom/linux-aurora` commit on
  `integration/aurora` (today `b798f2b0`, `7.2.11.aurora15`). Every bump is a PR that moves `_commit`.
- Config: the package's `config`, then the kernel's own `arch/arm64/configs/asahi.config` merged on top
  (`configure.sh`: "Production uses the defaults owned by the pinned kernel, not a package-maintained
  driver list"); `validate-config.py` rejects options Kconfig silently dropped; `CONFIG_RUST=y` is
  required; LLVM 18; 16K pages; the release must end in `-ARCH` (DTB discovery by `update-m1n1` and
  `omarchy-mac-boot`). DTBs install to `/usr/lib/modules/$kver/dtbs/`.
- CI: every kernel PR runs `kernel-ci-jobs.yml`: compile at every commit with `W=1`, `dt-check.py` on
  touched DTs and bindings, KUnit, and a `package` job that builds the real package with
  `omarchy-pkgs bin/build --mirror edge --arch aarch64 --package linux-aurora` and compares it with the
  target branch's.
- Channels: published to `pkgs.omarchy.org/edge/aarch64` first. `release/mac-inventory.txt` lists the
  qualified version of every Mac package for rc and stable; `bin/check-mac-set` holds promotions to it.
  The recipe states that rc/stable need cold-boot qualification on M1 and M2.
- Out of band: GitHub releases of linux-aurora also ship packages, recipes and
  `install-aurora-sep.sh` for testers (latest `aurora-2026.10.17.20`, kernel 7.1.12).

### 2.2 Where our series has to go

`omacom/linux-aurora` and `aurora-silicon/linux` are different trees. Our series (`series/SERIES.md`,
tip `a0f2f30c967b`) is on `aurora-silicon` 7.3.0; omacom is 7.2.11 and has no T6050 device trees.
omacom #404 ("Add the T6050 (M5 Max) and the 14-inch MacBook Pro (J714c)", depends on omacom/m1n1 #26)
brings SART v4, T6050 cpufreq, the RTKit boot-loader handoff, NVMe ANS2, the MTP early wake, our
macsmc-power fix, simpledrm eDP, and `t6050*.dtsi` plus `t6050-j714c.dts`. It leaves out Wi-Fi, sound,
USB, GPU and DCP.

| Group in our series | Patches (series numbering) | Path into omacom |
|---|---|---|
| T6050 base, J775D/J716c DTs, NVMe, SART | 0001-0017 (Aurora authors) | covered by #404 in omacom's own form; drop ours |
| J716s board DT | 0057, 0059, 0060, 0082 | **new PR on top of #404**, rewritten against #404's `t6050-*.dtsi` split |
| Type-C / USB host (combo PHY, dwc3, PIPE park, tps6598x, sn201202x, right port) | 0018-0029 area, 0060 | separate PR after #404; Aurora's authors kept |
| RTKit 10 s handshake (aurora-silicon #1082), dockchannel settle (#1083), hwmon fan keys (#1084) | ours | check against #404's RTKit change; resend the two that still apply |
| WFI idle override for T6050 MIDRs | 0061 (aurora-silicon #1152) | small PR; needed for battery life |
| Lid-open confirm, battery work items | 0066, 0045+ | PR with the SMC input set |
| N1: pcie-apple adoption, centauri Wi-Fi/BT, ASPM off and shutdown park on adopted ports, never-booted N1 | 16 N1 patches, 0085-0087 | after USB; Aurora's authors kept; needs the m1n1 N1 hand-off |
| Audio (AOP mic, TDM format for the J716 amps) | audio kernel, `contrib/pending/audio/aurora/tdm/` | after the base; speakers stay attended until the burst is gone |
| GPU (27.2+ InitData port, M5 Pro G17S) and DCP (27.3 method table) | test kernels | last; pinned to the stub firmware (2.6) |
| Debug: PM_DEBUG, netconsole and ramoops built in | 0062, 0084 | config only; see 2.4 |

### 2.3 Turning the series into the package

No new package. Once the J716s DT and drivers are in `omacom/linux-aurora`, the ordinary recipe bump
ships them for every Mac: one kernel, one image. What the board needs from the recipe is only that the
J716s DTB is built (`arch/arm64/boot/dts/apple/Makefile`) and that `validate-config.py` passes.

### 2.4 Config fragment

`series/j716s.config` (226 lines) is written for a kernel that loads no modules. In the package the
options go into the kernel's `asahi.config` (production defaults are kernel-owned), mostly as modules:

| Keep built in (boot path, or needed before the LUKS prompt) | Module | Drop from production |
|---|---|---|
| `NVME_APPLE`, `APPLE_SART`, `APPLE_RTKIT_HELPER`, `PINCTRL_APPLE_GPIO`, `GPIO_MACSMC`, `POWER_RESET_MACSMC`; the DockChannel keyboard (`APPLE_DOCKCHANNEL`, `HID_DOCKCHANNEL`, `HID_APPLE`) unless `92-omarchy-mac-hid.conf` adds them to the initramfs | `APPLE_CENTAURI`, `APPLE_CENTAURI_WIFI`, `BT_HCICENTAURI` (so vendorfw is in place before probe), `HID_MAGICMOUSE` (the R3-R trackpad failure was `=m` with no module loading; with modules it is fine), `SENSORS_MACSMC_HWMON`, `MACSMC_POWER`, Type-C/PHY/dwc3, AOP audio, USB network adapters | `PM_DEBUG`, `DRM_APPLE=n` override, `idle=`-related test switches; netconsole and ramoops stay available (module and pstore) for support |

Everything else in the fragment (crypto for iwd, `CFG80211`, `RFKILL`, `BT`) is already in Omarchy's
`config` or comes in with the drivers. Verify with the CI `package` job, not by hand.

### 2.5 Initramfs hooks (`omarchy-mac-boot`)

- `asahi` + `omarchy-vendorfw`: need `/chosen/asahi,efi-system-partition`. Aurora's config-block
  Stage 1 adds it automatically (`src/payload.c`); our vars-based Stage 1 does not yet
  (`contrib/distro/GAPS.md` item 8). The board Stage 1 must set it.
- `92-omarchy-mac-hid.conf`: add the T6050 DockChannel HID modules if they are modules, so the keyboard
  works at the passphrase prompt.
- `omarchy-mac-encrypt`, Plymouth, vconsole: unchanged.
- Design A only: gzip compression for this board, and a size check (section 5, row 3).

### 2.6 Firmware

**N1 FTAB (Wi-Fi/Bluetooth).** The restore bundle's `ftab.bin` has no ticket and the N1 ROM refuses it
(`phase0: -5`). With the board's `centauri.j716sap.im4m` stitched into the ticket slot (header
`0x10`/`0x14` = ticket offset and length, IM4M appended after the last entry) the ROM accepts it. The
manifest has no ECID and no nonce, so the file is **per board and per macOS build, not per unit**.
(Older notes in this repo say "personalised per unit"; the stitching result supersedes them.)
It is Apple firmware: extract on the Mac, never ship it.

- Inputs: `Firmware/t2026macG1/Release/ftab.bin` and `restore/centauri/centauri.j716sap.im4m`, taken
  from the **same** build. Whether the public restore image carries the `centauri.*.im4m` manifests is
  **[unverified]**; they are in the Preboot restore bundle of an installed macOS. The FTAB is loaded by
  Linux, not by iBoot, so it does not have to match the stub's build, only its own manifest.
- Engine step (new, beside the MT7932 recipe): read both (range reader on the restore image, else the
  running macOS's Preboot `restore/` bundle), check `rkosftab` at 0x20, chip 0x2026, board 0x841 and
  that every image digest matches the manifest (`mk-ftab-w3.py` checks exactly this), stitch, and add
  `apple/centauri/j716s-ftab.bin` to `vendorfw/firmware.{tar,cpio}` and `manifest.txt`. The Recovery
  baseline then carries it too.
- Kernel side: m1n1's N1 hand-off writes `firmware-name = "apple/centauri/<target-type>-ftab.bin"`;
  the driver finds it under `/lib/firmware/vendor`. `omarchy-aurora-firmware` blacklists the centauri
  modules until the file exists and loads them after vendorfw, as it does for the Neo's MT7932.
- m1n1 must train apcie0 port 0 (`chosen.asahi,t6050-n1=4`), and every payload must carry the
  warm-N1-aware loader (0027): a loader without it hangs once on a warm N1. Either m1n1 arms this by
  default on `apple,j716s` (as `m1n1-aurora` 21 arms the M3 Air display), or a `setup-boot` leaf writes
  the line to `/etc/m1n1.conf` (as `setup/m1n1-display.sh` does for the M3 Air).

**Trackpad (MTP) firmware**: the existing `asahi_firmware` multitouch extraction, with the `j716sap`
device class (our `extract-tpmtfw.py --device-class j716sap`).

**GPU and DCP firmware are not extracted.** iBoot preloads the GFX/GFX1 and DCP firmware from the
stub's restore bundle; m1n1 hands them to Linux (`chosen.m5pro,gpu`, `chosen.m5,t6050-display`). The
kernel must speak exactly that firmware: GPU InitData for 26C5035r G17S (booted, Vulkan passes, GL via
zink), DCP `firmware-compat` 27.3.0 (hand-off passes; scanout needs the panel's `apple,bw-scratch`).
So the dependency is a triangle that the release must keep closed:
stub firmware build (catalog `supported_fw`) <-> kernel firmware tables <-> m1n1 hand-off gate. m1n1
should hand over the GPU and DCP only on a firmware build it identifies, as `m1n1-aurora` does for the
M3 Air GPU (14.8.3 only). The Mesa side (`mesa-aurora` with M5 Pro on zink) is a separate package.

### 2.7 What must be in `omacom/linux-aurora` first

In order; each step is usable on its own:

1. #404 merged (T6050 base).
2. J716s board DT: boots, NVMe root, 18 CPUs, keyboard, trackpad, battery, SMC sensors.
3. Type-C/USB host: without it and without Wi-Fi the installed system has no network at all.
4. N1 Wi-Fi/Bluetooth (with the m1n1 hand-off in omacom/m1n1).
5. WFI idle override (idle power 16.4 W -> 9 W on the charger).
6. Audio; then GPU and DCP.

Steps 1-4 are the minimum for a developer-catalog install a person can use.

## 3. Catalog entry, the 27.3 requirement, recovery and updates

### 3.1 Catalog entry for Mac17,8 (J716s)

The catalog keys on the board (`apple,j716s`, from `hw.targettype` `J716sAP`), not on `Mac17,8`.

```json
"developer": {
  "apple,j716s": "MacBook Pro 16-inch (M5 Pro, 2026): developer builds only; needs macOS 27.3 beta 1 (26C5035r) or later firmware"
}
```

`developer` boards appear only in a developer build's sealed catalog, with their own image; channel
catalogs reject them (`scripts/supported_models.py`). That is the right first class: it keeps the
"one image for every supported Mac" rule intact while the kernel support lives outside the release.
Later steps: `supported` plus an `untested` note on edge once the J716s is in the one image, then drop
the note after edge qualification. `apple,j614s` (M4 Pro) stays refused; the engine's
`UNSUPPORTED_DEVICES` names only that board, and the J716s needs its own `DEVICES` entry anyway.

`MacModelNames.swift`: `"apple,j716s": mac("MacBook Pro 16-inch (M5 Pro, 2026)", "MacBook Pro", "M5")`.

### 3.2 The 27.3 beta requirement

- **Why**: Apple's 27.3 beta 1 release notes (mBoot, resolved, 182898702): "Only a single core is
  available when you boot Linux or other third-party operating systems from a custom raw boot object on
  Mac computers with M5 Pro, M5 Max, and M5 Ultra chips." The fix is in the stub's stage-2 mBoot; a
  27.2 stub on a 27.3 machine still boots one core (measured).
- **What a user must have**: macOS 27.3 beta 1 or later installed, so the system firmware (LLB) is at
  least `mBoot-20457.60.65.0.1` (the engine's `min_iboot` check enforces it), and a stub built from the
  26C5035r restore image.
- **Apple signing**: the stub's boot objects are personalised for the Mac when the ceremony creates its
  LocalPolicy. Whether a seed build can still be personalised after the final release is Apple's
  decision **[unverified]**. Installed stubs are not affected: a macOS update does not touch the stub's
  bundle, and its policy is already on disk.
- **When 27.3 ships final**:
  1. add the final build's `IPSW(...)` entry and put it in `supported_fw` and `os_firmware`;
  2. on the machine: a stub built from the final image gives 18 CPUs; m1n1 identifies the final GPU and
     DCP firmware; if the builds differ from 26C5035r, the kernel gets the matching InitData and
     `firmware-compat` entries and m1n1 the identification **before** the catalog switches;
  3. new installs use the final build only; the seed entry stays for repairs of seed-stub installs
     while Apple still personalises it;
  4. pin exact versions, never ">= 27.3": a later mBoot can change the raw-object path again.
- **Open question**: omacom/m1n1 #26 releases T6050 secondaries "one bit per CPU index, as on T8142".
  If that gives 18 CPUs on a 27.2 stub, the beta requirement relaxes. Ask its author which stub
  firmware the J714c ran before relying on it either way.

### 3.3 Recovery path

| Failure | Ours today | Omarchy equivalent | Change needed |
|---|---|---|---|
| New kernel or payload does not boot | A/B Stage 1 falls back to `boot.bin.prev` on the next power-on (PMU boot-error count, 150 s watchdog) | Limine menu or snapshot (Design B); nothing automatic for Stage 2 | keep the A/B Stage 1 in `BOARD_STAGE1`; in A it covers the kernel too |
| `boot.bin` missing or unreadable | Stage 1 tries the other slot, then the USB proxy | USB proxy | none beyond A/B |
| Restore from macOS | `r1-deploy.sh status`, `restore prev|b2|known-good`, `logs` (mount the ESP, verify sha256, copy) | Recovery app `aura recover` (restores the Stage 2 and vendorfw baseline as one transaction); the Mac manual's `diskutil mount` steps | baseline = the install-time payload (A) or Stage 2 (B); add a status view (names and hashes of every `m1n1/boot.bin*`) and a log pull from the ESP |
| Stage 1 broken | 1TR, `kmutil configure-boot` with `known-good.bin` from the stub volume; boot macOS first to clear iBoot's failure count | Recovery app "Repair startup" in the paired 1TR | the repair must re-enrol the board Stage 1, not Asahi's |
| iBoot "needs to be reinstalled" after repeated failed boots | Linux's reboot path and the A/B Stage 1 clear the boot-error count | not handled | Stage 1 must clear the count (0016's default) |
| macOS updated | nothing; stub keeps its bundle | same | none |
| Stub refresh to a newer mBoot | `refresh-stub-firmware.sh recreate`, firmware re-extract, ceremony | not offered; reinstall only | a Recovery-app "refresh" that checks the kernel's supported-firmware list first (2.6) |
| Remove | `finish-install.sh --undo`, partitions by type | "Remove Omarchy..." | none: same layout |

### 3.4 Updates: A/B payloads versus Limine

| | Omarchy (U-Boot/Limine) | J716s Design A | J716s Design B |
|---|---|---|---|
| Kernel update writes | UKI on the ESP, Stage 2 rebuilt for new DTBs | `boot.bin` (kernel + DTB + initramfs inside) | as Omarchy |
| Before reboot | `update-verify` byte-for-byte check | same check, of the payload | as Omarchy |
| Bad kernel | pick the old entry in Limine, or a snapshot | automatic: Stage 1 boots `boot.bin.prev` | Limine menu |
| Bad Stage 2 | macOS copy of `boot.bin.old` | automatic (same file) | automatic: A/B Stage 1 falls back to `boot.bin.old` |
| Promotion of "known good" | none | only from a primary-slot boot past `boot-complete.target`; never from a fallback boot | for Stage 2, same rule |
| Stage 1 update | Recovery operation, never by pacman | same | same |
| Snapshot boot | yes | no (needs Limine) | yes |

The A/B Stage 1 is worth keeping in either design: Omarchy's chain has no automatic rollback below
Limine, and on the M5 the failures seen so far were below Limine's level (loader, firmware, N1 state).

## 4. Phased checklist, owners, and the first PRs and issues

"Us" = this project. "Maintainers" = omacom reviewers and release owners (linux-aurora CODEOWNERS:
maralcbr, chriskearney, scottjones; the installer's signing, notarisation and catalog publication are
theirs). No phase merges anything on our side; we open PRs and run hardware tests.

### 4.1 Phases

| Phase | Work | Owner | Exit |
|---|---|---|---|
| 0. Align (now, no hardware) | This plan. Offer J716s testing on #404; ask about the U-Boot tree and stub firmware behind m1n1 #26/#27. | us | answers on #404 / m1n1 #26 |
| 0b. Decide A vs B (one loop boot) | Test payload = omacom m1n1 stage 2 + J716s DTB + `uboot-aurora` behind our A/B Stage 1, daily as fallback. Record NVMe, keyboard, panel, CPUs. | us | B boots to Limine, or a recorded failure |
| 1. Kernel | J716s DT PR on #404; then Type-C/USB, N1, WFI, SMC input, audio; config into `asahi.config`; CI green (compile, `dt-check`, package). | us (PRs), maintainers (review, merge) | J716s DTB in a `linux-aurora` edge package |
| 2. m1n1 | Port to omacom/m1n1 `integration/aurora` on top of #26: chainload relocation (0013-0015) or #27's layout, notch, USB-PD, PIPE park, ATC tunables, N1 training and warm N1 (0022-0027), GPU/DCP hand-off gated on identified firmware; Stage 1 A/B as config-block version 2 (fallback path, watchdog seconds, PMU clear). | us (PRs), maintainers (review, `build-qualification.json`) | `m1n1-aurora` edge package with T6050 Stage 1 and Stage 2 |
| 3. Packages | `omarchy-mac-boot`: J716s board mode (A) or nothing (B); HID drop-in. `omarchy-aurora-firmware`: N1 admission. `release/mac-inventory.txt`: entries stay `none` until qualified. | us (PRs to omarchy-mac-pkgs, omarchy-pkgs), maintainers | packages on edge, `test/all` green |
| 4. Installer | Engine tables (27.3 IPSW, `DEVICES`, `CHIP_MIN_VER`, `BOARD_STAGE1`, `BOARD_STAGE2` for A), FTAB step with tests, `supported_fw`, `developer` catalog entry, model name, image builder staging the J716s Stage 1 (and A's Stage 2). | us (PRs), maintainers (engine lock bump, signing, notarisation, developer catalog) | a developer build that inspects and plans a J716s |
| 5. Qualification | Fresh install from the developer catalog on the J716s with a current backup: the ceremony, first boot, LUKS, Wi-Fi, a kernel update with A/B, `aura recover`, removal. Evidence in the installer's `evidence/` format. Then the edge image with `untested`. | us (hardware), maintainers (catalog) | edge `supported` + `untested`, then qualified |
| 6. Final firmware | 27.3 final: section 3.2's four steps. | us + maintainers | catalog on the final build |

### 4.2 First three PRs and issues

**1. omacom/linux-aurora, PR (stacked on #404)**

Title: `arm64: dts: apple: Add the 16-inch MacBook Pro (M5 Pro, J716s)`

> This adds the J716s (MacBook Pro 16-inch, M5 Pro, Mac17,8, T6050) on top of #404's T6050 base: the
> board DT, its compatible in the bindings, and the build entry. It describes the CPUs, PMGR, NVMe, the
> DockChannel keyboard and trackpad with the trackpad's AFE reset on SMC GPIO `gp1c`, the keyboard
> backlight, the SMC (battery, charger, lid, power button, RTC, sensors with both fans) and the panel
> framebuffer, and it carries no per-unit values: the combo-PHY tunables come from the ADT through
> m1n1. USB, Wi-Fi/Bluetooth, sound, GPU and display controller nodes follow in later PRs. Tested on a
> J716s: the same board description on Aurora 7.3 boots from the internal SSD with 18 CPUs, keyboard,
> trackpad, battery and 60+ SMC sensors, untethered from the ESP; this branch itself is compile-checked
> and `dt-check`-clean, and will be booted once #404's m1n1 side is in a J716s payload. Evidence:
> https://github.com/rolotrealanis98/m5pro-linux (`contrib/validated/integration/RESULTS.md`).

**2. omacom/omarchy-mac-installer, issue**

Title: `Support the 16-inch MacBook Pro M5 Pro (J716s) on a developer catalog`

> The J716s (Mac17,8, T6050) boots Omarchy's desktop untethered with the Aurora kernel, and this issue
> proposes how it enters the installer without changing the one-image rule: a `developer` catalog entry
> for `apple,j716s`; engine entries as for the MacBook Neo (`CHIP_MIN_VER` 0x6050 and a `DEVICES` entry
> at 27.3, and an `IPSW_VERSIONS` entry for the 27.3 beta 1 restore image, 26C5035r, limited to
> `j716sap`), because only that stage-2 mBoot starts the secondary cores from a raw boot object (Apple
> 182898702); a `BOARD_STAGE1` entry pinned to that firmware, using a T6050 CHAINLOADING Stage 1 with an
> A/B fallback and watchdog; and one new firmware step that builds the N1 Wi-Fi firmware on the Mac by
> stitching the board's `centauri.j716sap.im4m` into the restore bundle's FTAB ticket slot (per board
> and per macOS build, no per-unit data, never redistributed). Open question for the maintainers:
> whether the M5's Stage 2 should be the direct kernel payload that boots today (needs a
> `BOARD_STAGE2` entry and a board mode in omarchy-mac-boot) or U-Boot/Limine as on the J714c in
> omacom/m1n1 #26/#27. Hardware results and recipes:
> https://github.com/rolotrealanis98/m5pro-linux.

**3. omacom/m1n1, PR**

Title: `stage1: an A/B fallback target and a watchdog in the Stage 1 config`

> A raw Stage 1 that chainloads `m1n1/boot.bin` has no way back when that file boots a kernel that
> hangs: every power-on loads the same file. This adds a version 2 of the `AURORA-S1-CFG01` block with
> a fallback Stage 2 path and an optional watchdog. Before it chainloads, Stage 1 reads iBoot's PMU
> boot-error count (non-zero when the previous boot did not end in a clean restart or shutdown), boots
> the fallback path after a failed boot, tries the other path if one cannot be read, and clears the
> count so repeated failures never send iBoot into its "needs to be reinstalled" recovery. The slot it
> chose is passed on as `chosen.*` so Linux can report it. Version 1 blocks behave as before, and the
> engine's fill function gains the two fields. Tested on a J716s (M5 Pro) since 2026-11-05 as a
> variables-based Stage 1 on our m1n1 lineage: the fallback fired on real failed boots and the machine
> came back on the previous payload each time; this port to `integration/aurora` is build-tested and
> will be booted on the J716s before review.

Next in line: the omacom/m1n1 N1 PR (port of aurora-silicon/m1n1 #65 onto #26), an omarchy-mac-pkgs
issue for the J716s board mode (Design A) once 0b is decided, and the `omarchy-aurora-firmware` N1
admission.

## 5. Gaps that would hurt a non-expert

| # | Gap | What the person sees | Fix | Owner |
|---|---|---|---|---|
| 1 | **Attended boots.** Every new kernel here is first booted as a self-reverting test with a USB Ethernet adapter attached; speakers and the display stage C are attended only. The daily has no self-revert: once Linux feeds the watchdog, a kernel that hangs later (or comes up without input) stays up. | a black or frozen screen after an update; holding the power button is the only way out | promote only after `boot-complete.target`; a userspace check that stops feeding the Stage 1 watchdog if boot-complete is not reached in time, so the next power-on falls back; nothing attended-only in a release | us |
| 2 | **First boot of a freshly written payload falls back once** (5 of about 16 new files on 2026-11-07, also a re-written copy of a known-good file; every retry booted). Unmount and remount of the ESP by device plus a re-hash before the reboot gave a primary boot twice in a row. Cause unknown. | after an update the Mac silently boots the previous kernel, then the new one next time; a naive fallback handler would mark the good payload bad | find the cause (FAT caching on the write side vs m1n1's reader); keep remount + re-hash in the composer; treat a fallback on the first boot of a new file as "retry once", never as "demote" | us |
| 3 | **476 MiB ESP** (500 MB decimal; Omarchy's engine makes 500 MiB). A payload is about 25 MB with today's module-less initramfs; a mkinitcpio initramfs with Plymouth and LUKS will be larger **[unmeasured]**. Four payloads, two in flight, vendorfw and a failed-boot copy per self-revert filled the ESP once. | an update fails with "no space", or a half-written payload | measure the distro payload; keep at most `boot.bin`, `boot.bin.prev`, `known-good`; never store failed payloads on the ESP; size the J716s ESP at 1 GiB if the measurement says so | us + maintainers (partition template) |
| 4 | **No netconsole for users.** Here netconsole needs a second machine on the USB link (double NAT); a user has none. Until DCP scanout lands, the panel is simpledrm and a crash before it shows nothing. | "it doesn't boot" with no log | ramoops/pstore built in (0084); a unit that copies pstore and the failed boot's journal to the ESP; the Recovery app's report and a macOS-side log pull (as `r1-deploy.sh logs`) | us |
| 5 | **Beta macOS first.** Until 27.3 final, the install requires enrolling macOS in the beta and updating, and the 1TR ceremony. | an "update macOS" refusal, or a stub that boots one core if built by hand from an older bundle | the engine's `min_iboot` refusal names the version; switch to the final build promptly (3.2) | maintainers + us |
| 6 | **Stub refresh** to a newer mBoot is a recreate plus a ceremony, and can break GPU/DCP if the kernel does not know the new firmware. | none until they try it; then a broken desktop | do not offer refresh except through a checked Recovery action (3.3) | us + maintainers |
| 7 | **Hardware still missing in the daily**: GPU and DCP work only in test payloads; speakers attended; the N1 needs the warm-N1 loader in every payload. | software-rendered desktop, short battery life, no sound | section 2.7 order; m1n1 arms N1 by default on `apple,j716s` | us |
| 8 | **Getting back to macOS** is a power-button hold at every boot (the stub is the default volume); `asahi-bless` is untested on the M5. | "where did macOS go" | test `asahi-bless` read-only, then document the switch | us |

Not in this plan on purpose: publishing any Apple firmware, the FTAB, ADT dumps or per-unit values;
an M4 path; the 14-inch J714s and the Max boards (same tables, separate qualification).
