# What blocks a non-expert install today

Ordered by what stops someone first, from "cannot install" to "installed but not usable" to
"usable but fragile". Effort for one person who knows this tree: **S** <= 2 days, **M** <= 2
weeks, **L** <= 2 months, **XL** = new driver or upstream work with no date. "Ceremony" = needs a
1TR round on real hardware.

## A. Cannot install without being the author

| # | Gap | Evidence | Fix | Effort |
|---|---|---|---|---|
| 1 | No installer: the path is two reviewed-by-hand sudo scripts plus a tether host and per-desk tools (`m5.sh`, `1tr-stage1.sh` serving from the Studio's LAN address (`$STUDIO_IP`), `stage1-install.sh` reading `~/Work/m1n1/stage1`) | `boot-and-recovery.md:18-31,93-121,183-199`; `installer/CHECKLIST.md` "Other ... assumptions" | macOS installer script per `installer/CHECKLIST.md`: parameterised `prep-stub.sh`/`finish-install.sh`, raw root write, ESP population, stage-1 from `mk-stage1.py`, one ceremony | M (script); L (signed app with UI) |
| 2 | `prep-stub.sh` picks partitions by name with `tail -1` and hard-codes `disk0s2`; unsafe on a Mac with an earlier Asahi/Omarchy install | `prep-stub.sh:35,66,83,107,131,300,313` | identify by before/after diff and record DiskUUIDs; refuse when unsure | S |
| 3 | `finish-install.sh` still enforces the *old* rule (stage-1 must be CHAINLOADING=0) and keeps no rescue images | `finish-install.sh:132-138`; `prep-stub.sh:377` | invert the check (`mk-stage1.py inspect`), copy `known-good.bin`/`proxy.bin`/`rescue.sh`/`SHA256SUMS` to the stub | S |
| 4 | No version gate: a stub built on macOS < 27.3 beta 1 boots one core, silently | `smp-t6050-raw-path.md:139-160` | preflight: build >= 26C5035 and Preboot restore bundle == running build | S |
| 5 | No release artifacts: no package repo, no signed root image, no prebuilt payloads; everything is built on the Studio from working trees | `SOURCES.md` | CI (native aarch64: the Studio or an aarch64 runner) building the PKGBUILDs in `pkg/` (the four boot packages, plus `avd-fw`, `speakerguardd-v2`, `aurora-speaker-upgrade`), a signed `[m5pro]` repo, the root image, `boot.bin`/`rescue.bin`, a signed release manifest the installer verifies | M |
| 6 | Root image bakes in the builder's SSH keys and locks every password; console login is impossible, SSH works only from a Linux host over the gadget | `mkrootfs-image.py:90-93`; `boot-and-recovery.md:63,216-218` | image without keys; first-boot prompts on tty1 (`m5pro-firstboot.service`, DESIGN.md section 7) | S |
| 7 | The initramfs is the Alpine bring-up `/init` (custom `m5.root=`, `/dev/mem` framebuffer bands with J714s constants) | `mkinitramfs.py:28-95,42-50` | mkinitcpio initramfs (gzip, `pkg/m5pro-boot/m5pro-mkinitcpio.conf`), `root=PARTUUID=`; move `usb-gadget-net.sh` to a rootfs systemd unit; one tethered boot to prove it | S + 1 tethered test |
| 8 | Installed stage-1 has no `chosen.asahi,efi-system-partition`, so Linux cannot find its ESP from the DT | `chain-esp-small.bin` vars (only `chainload=`; `tools/test-mk-stage1.sh` step 1) | `mk-stage1.py` adds it by default; until reinstalled, `ESP_PARTUUID` in `/etc/m5pro/boot.conf` | S (+ the next ceremony) |
| 9 | Kernel package does not exist; kernel is built by hand with debug patches and dev cmdline (`0001-t6050-early-fb-markers`, `loglevel=8 keep_bootcon`) | omarchy-m5 `patches/linux/`; `m5.sh:94` | `pkg/linux-m5pro/PKGBUILD`; decide which bring-up patches stay; quiet default cmdline | S-M |
| 10 | `m1n1-m5pro` needs the `aarch64-unknown-none-softfloat` Rust target, which Arch's `rust` lacks; the PKGBUILD fetches it with `rustup` in `prepare()`, which a no-network clean-chroot build forbids | `pkg/m1n1-m5pro/PKGBUILD` | prebuilt toolchain package or vendored target in the build container | S |

## B. Installed, but not usable as a laptop

| # | Gap | Evidence | Fix | Effort |
|---|---|---|---|---|
| 11 | No network of its own: no Wi-Fi/BT driver (N1); the USB gadget needs another computer, and macOS has no CDC-EEM driver, so a Mac cannot be that computer | `README.md:22`; `boot-and-recovery.md:89-91`; `usb-gadget-net.sh:2-14` | XL for N1. Interim: (a) find out whether USB host mode works (USB Ethernet dongle) - M investigation; (b) offline updates: the macOS installer downloads packages into `ESP/m5pro/updates/` and a boot unit runs `pacman -U` - M | XL / M |
| 12 | Omarchy cannot be layered as is: `aarch64-apple` pulls `omarchy-mac-boot` (U-Boot/Limine/LUKS) and lifecycle dispatch requires its entrypoints | basecamp/omarchy `docs/lifecycle-dispatch.md`, `install/omarchy-aarch64-apple.packages` | `omarchy-m5pro-boot` entrypoints (DESIGN.md section 7), image build with `/var/lib/omarchy/image/target`, settle provides vs repo-precedence, vet `omarchy-mac` services; then propose upstream | M |
| 13 | Display is simpledrm on m1n1's framebuffer only: no GPU, no DCP (no brightness, no external display, no modesetting); Hyprland would run software-rendered | `README.md:22`; omarchy-m5 `docs/PLAN.md:53-56` | measure Hyprland on simpledrm/pixman first (M); real fix is DCP + GPU drivers | M / XL |
| 14 | Trackpad: firmware ships, driver start times out (`dockchannel-hid: input iface multitouch start timed out`) | `README.md:21` | debug from the Arch root (dmesg), then it rides the vendorfw path | M |
| 15 | Audio, suspend/resume, battery/charge control, keyboard backlight, camera: not started | `README.md:22` | per-driver work | L-XL each |
| 16 | Root is ext4; Omarchy's Mac path assumes btrfs snapshots + LUKS encryption at first boot | `mkrootfs-image.py:142`; omarchy-mac-boot README | btrfs root + snapper is M; LUKS needs the initramfs unlock prompt with the built-in keyboard working in the initramfs (it does today) and `omarchy-m5pro-boot` provision entrypoints | M / M |

## C. Usable, but fragile

| # | Gap | Evidence | Fix | Effort |
|---|---|---|---|---|
| 17 | No automatic fallback: one `chainload=` path, read-only FAT in m1n1, a failed load ends in the USB proxy; a hanging kernel loops | `src/chainload.c:136-153`; `rust/src/nvme.rs:75-82`; `src/main.c:116-133` | ship option A (manual slots, `m5pro-update-payload`), then stage-1.5 (test double chainload: 1 tethered session), then proposed m1n1 patch 0015 (ordered path list) | S / S / S-M |
| 18 | The 1TR-only rescue (Options Terminal -> arm -> step2) has never been shown to work: every probe that used the `arm` shortcut failed, attributed to iBoot's uncleared failed-boot count | `boot-and-recovery.md:137-142` | one deliberate test: boot macOS (clears the count), arm `known-good` from Options Terminal, ceremony; document the result in `stub-rescue.sh` | S + ceremony |
| 19 | Which of size (0x4F0000 -> 0x430000) or 64 KiB alignment fixed stage-1 is not separated; both rules are kept, so any future stage-1 growth is a guess | `boot-and-recovery.md:179-181` | keep `mk-stage1.py`'s 0x430000 warning and `m1n1-m5pro` `check()`; separate the two only if stage-1 must grow | S + 2 ceremonies (optional) |
| 20 | Stub refresh after macOS updates is manual and needs `recreate` + ceremony; firmware must be re-extracted to stay paired | `refresh-stub-firmware.sh:17-22`; `extract-tpmtfw.py:29-30` | installer "Refresh" action chaining recreate -> firmware -> known-good stage-1 -> ceremony; parameterise its size guards (lines 57, 79, 142) | S |
| 21 | No backup of the M5 exists; the installer's resize is live APFS | `boot-and-recovery.md:244`, `:29-31` | installer requires an acknowledged backup (as omarchy-mac-installer does) | S |
| 22 | Startup-disk switching from Linux (`asahi-bless`) and NVRAM access untested on M5; the stub stays the default boot volume, macOS only via power-hold | `bringup.md:157-159` | test `asahi-bless` read-only first | S |
| 23 | J714s (14-inch) is untested on this chain; several tools default to J714s, the J716s work is the only hardware proof | `CHECKLIST.md` table | a J714s tester; board taken from the DT everywhere (`m5pro-update-payload` already does) | S + hardware |
| 24 | Packages, scripts and the hook were not run under `makepkg`/pacman (no aarch64 Arch here); only `bash -n`, `shellcheck`, and the payload builder against real artifacts in a fake ESP | this folder | `makepkg` + `namcap` in an aarch64 Arch container, then one install on the M5 over the tether | S |

## D. Userspace pieces brought from upstream (2026-11-15)

Nothing in this section was built under `makepkg` or run on the MacBook. Pins are in each file's header or README.

| # | Piece | Where | Source and pin | State | Effort |
|---|---|---|---|---|---|
| 25 | Video decoder firmware | `pkg/avd-fw` (new); `linux-m5pro` optdepends it | aurora-silicon/avd-fw `6062e8516c0a` via alarm-aurora `packages/avd-fw` (`27109d22`), source sha256 `49a631c8...` | `apple/avd-fw-v5-t2.bin`, the image our T6050 AVD driver names, is one of the eight. Upstream builds v5-t2 for T6040/T6041: **untested on T6050** (its queue-mode SRAM aperture must equal the SoC's DT `sram` offset, +0x94000 on T6040). `check()` needs clang/llvm/lld 22: LLVM 23 changes image bytes, so it could not be run on macOS. Make it a `depends` once the AVD patches are in `linux-m5pro` | S (+ a decode test) |
| 26 | Speaker protection | `contrib/validated/desktop/audio/speakerguardd-v2/`, `pkg/speakerguardd-v2`, `pkg/aurora-speaker-upgrade` | aurora-silicon/speakerguardd `v2` `04169c44`; recipes alarm-aurora `282881f37c86`; boot-time switch and card wait from betizzel/omarchy-m5 j714s12 | Replaces speakersafetyd (held off: panics at `main.rs:298`). Needs the dual-interface kernel; under v2 the -30 dB `max_vol` ceiling no longer applies (the lease runs the amps at a fixed gain), so the first grant is the first time this tree can drive the speakers above -30 dB. `spk_fixed_ceiling` (`8360c9788f29`) is ceiling-only and disables v2. May refuse on macOS 27.3 (no `parity.json` block; AID41 is in the 25G83 reference table), on a missing speaker ID, or on a missing ADT. Never run | M + listening test |
| 27 | Mesa with the M5 Pro admission | `pkg/mesa-aurora/README.md` (no package) | aurora-silicon/mesa `d4ad4a4dce6d` (alarm-aurora `mesa-aurora`, `27109d22`); admission is `a967585a` (squash of `67ac6c3e`, `9a71d48f`), already an ancestor | Use alarm-aurora's package. Matches `integration/aurora`'s DRM uAPI: useful with `j716s-next`, not with the packaged `linux-m5pro` (no GPU driver, item 13) | S |
| 28 | Ambient light calibration | `pkg/m5pro-firmware/m5pro-als-cal` (macOS side), `installer/CHECKLIST.md` step 2 | betizzel/omarchy-m5 `tools/als-calibration/save-als-cal.py` `68aafa3d0d76` (MIT, with aurora-installer `als.py` MIT); `LICENSE.als-cal` | Writes `apple/aop-als-cal.bin` from the user's own macOS into the firmware tree or `firmware.tar`; tested here on a synthetic `ioreg` plist and the tar/checksum round trip. The consuming driver (Aurora's Rust `aop_als`) is not in `linux-m5pro`, and `m5pro-vendorfw` timing against its probe is unchecked | S |
| 29 | Boot guard | `pkg/m5pro-boot/m5pro-boot-guard`, `00-m5pro-boot-guard.hook`, `00-m5pro-boot-guard-remove.hook`, `BOOT_REPOS` in `boot.conf`, `tools/test-boot-guard.sh` | betizzel/omarchy-m5 `m5-boot-guard`/`00-omarchy-m5-boot-guard.hook` (j714s13, `6a4947185a92`, MIT) | Closes a real gap: `95-`/`96-` run PostTransaction and cannot refuse, so an Omarchy channel switch that rewrites `pacman.conf` could put another repo's kernel, m1n1 or `omarchy-mac-boot` in place. 17 cases pass against a fake pacman; not run under real pacman. The ESP-space check of the upstream guard (K114s only) is not brought: `m5pro-update-payload` already checks free space and fails before touching `boot.bin` | S (one pacman run) |
| 30 | Power profiles (optional) | nothing shipped | alarm-aurora `docs/power-profiles.md` and `packages/power-profiles-daemon` (0.30-1.1, patch `0001-platform-profile-use-the-class-interface-without-acpi`, sha256 `84237970...`), docs last changed in `69ef37fedc69` | On T6050 the kernel's CLPC driver registers an `apple-clpc` platform profile (aurora-silicon/linux #1655, #1656, both in `integration/aurora`; low-power holds the package at 15 W). Stock power-profiles-daemon reads only `/sys/firmware/acpi/platform_profile`, so on a device-tree boot it needs the patched 0.30 build (drives the first `/sys/class/platform-profile` device). **Our kernel does not enable CLPC** (`j716s-next` HANDOFF item 6: `APPLE_CLPC=y` plus the link, and the two idle parameters, none ported), so there is nothing for it to drive today. Add it after CLPC; `aurora-power-budget` (aurora-platform#16) stands aside once the kernel handler exists | S after CLPC |

## Shortest path to "someone else can install it"

1, 2, 3, 4, 6, 7, 8 (installer + image that boots to a login) -> 5 (artifacts) -> 12 (Omarchy
in the image) -> 11b (offline updates). About 4-6 weeks of focused work before items in B that
depend on drivers. Items 13-15 decide whether the result is a laptop or a demo, and are not
schedulable from here.
