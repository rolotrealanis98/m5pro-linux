# What blocks a non-expert install today

Ordered by what stops someone first, from "cannot install" to "installed but not usable" to
"usable but fragile". Effort for one person who knows this tree: **S** <= 2 days, **M** <= 2
weeks, **L** <= 2 months, **XL** = new driver or upstream work with no date. "Ceremony" = needs a
1TR round on real hardware.

## A. Cannot install without being the author

| # | Gap | Evidence | Fix | Effort |
|---|---|---|---|---|
| 1 | No installer: the path is two reviewed-by-hand sudo scripts plus a tether host and per-desk tools (`m5.sh`, `1tr-stage1.sh` serving from `<studio-ip>`, `stage1-install.sh` reading `~/Work/m1n1/stage1`) | `boot-and-recovery.md:18-31,93-121,183-199`; `installer/CHECKLIST.md` "Other ... assumptions" | macOS installer script per `installer/CHECKLIST.md`: parameterised `prep-stub.sh`/`finish-install.sh`, raw root write, ESP population, stage-1 from `mk-stage1.py`, one ceremony | M (script); L (signed app with UI) |
| 2 | `prep-stub.sh` picks partitions by name with `tail -1` and hard-codes `disk0s2`; unsafe on a Mac with an earlier Asahi/Omarchy install | `prep-stub.sh:35,66,83,107,131,300,313` | identify by before/after diff and record DiskUUIDs; refuse when unsure | S |
| 3 | `finish-install.sh` still enforces the *old* rule (stage-1 must be CHAINLOADING=0) and keeps no rescue images | `finish-install.sh:132-138`; `prep-stub.sh:377` | invert the check (`mk-stage1.py inspect`), copy `known-good.bin`/`proxy.bin`/`rescue.sh`/`SHA256SUMS` to the stub | S |
| 4 | No version gate: a stub built on macOS < 27.3 beta 1 boots one core, silently | `smp-t6050-raw-path.md:139-160` | preflight: build >= 26C5035 and Preboot restore bundle == running build | S |
| 5 | No release artifacts: no package repo, no signed root image, no prebuilt payloads; everything is built on the Studio from working trees | `SOURCES.md` | CI (native aarch64: the Studio or an aarch64 runner) building the four PKGBUILDs in `pkg/`, a signed `[m5pro]` repo, the root image, `boot.bin`/`rescue.bin`, a signed release manifest the installer verifies | M |
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

## Shortest path to "someone else can install it"

1, 2, 3, 4, 6, 7, 8 (installer + image that boots to a login) -> 5 (artifacts) -> 12 (Omarchy
in the image) -> 11b (offline updates). About 4-6 weeks of focused work before items in B that
depend on drivers. Items 13-15 decide whether the result is a laptop or a demo, and are not
schedulable from here.
