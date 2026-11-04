# macOS installer checklist: "Omarchy on M5 Pro"

What a macOS-side installer (script first, app later) must do, step by step, reusing
omarchy-m5 `scripts/prep-stub.sh` and `scripts/finish-install.sh` (branch `j716s` @ 2c87598) and
the m5pro-linux `host/macos/` tools. Line numbers refer to those files as read on 2026-11-04.

The point of the ordering: **everything except `kmutil` happens from the running macOS**, so the
install needs exactly one 1TR ceremony and no second machine. macOS can write all three targets:
the stub (APFS), the ESP (FAT32, `diskutil mount`), and the Linux root (raw write to
`/dev/rdiskNsM`, which is how asahi-installer installs root images: `src/osinstall.py:146-155`,
size must be a 4 KiB multiple). The tethered paths in use today (`provision-rootfs.sh`,
`mk-esp-install.sh`) exist only because the build host was another machine; they are not needed
by an on-device installer.

## 0. Preflight (refuse, change nothing)

| Check | How | Why |
|---|---|---|
| Model is a supported board | `sysctl -n hw.model` in {`Mac17,8` (J716s), `Mac17,9` (J714s)}; board = `ioreg -rd1 -c IOPlatformExpertDevice` `target-type` lowercased | DTs exist for these two only (`dt/t6050-j714s.dts`, `dt/t6050-j716s.dts`) |
| macOS >= 27.3 beta 1 (build >= 26C5035) | `sw_vers -buildVersion`; compare (major, letter, number) | the stub's stage-2 mBoot comes from this macOS; < 27.3 boots one core (m5pro-linux `docs/smp-t6050-raw-path.md:101-160`) |
| The Preboot restore bundle matches the running build | `plutil -extract ProductBuildVersion raw /System/Volumes/Preboot/$VGID/restore/BuildManifest.plist` == `sw_vers -buildVersion` (`refresh-stub-firmware.sh:45,94` does this comparison) | `prep-stub.sh:335` clones that bundle; a pending/half-applied update would clone the old mBoot |
| No existing stub / ESP / Linux partition, or explicit repair mode | `diskutil apfs list -plist`, `diskutil list -plist disk0` by **type**, never by `disk0sN` | `prep-stub.sh:300,313` pick "the last EFI" / "the last Linux" partition by name: wrong on a Mac that already has an Asahi install |
| Free space | as `prep-stub.sh:116-159` computes | resize is live APFS, ~25 min (m5pro-linux `boot-and-recovery.md:29-31`) |
| AC power, FileVault state recorded, admin user present in `AdminUserRecoveryInfo.plist` | `pmset -g batt`; `fdesetup status`; `finish-install.sh:147-157` | bless/kmutil need a machine-owner admin |
| Payload inputs present and signed | release manifest (sha256 + signature) for: stage-1 source m1n1, stage-2 payload, rescue payload, root image | nothing unverified goes onto the disk |

## 1. Partition and stub (`prep-stub.sh`, parameterised)

Run `prep-stub.sh --linux-size N --yes` with these made parameters instead of constants:

| Today (prep-stub.sh) | Make it |
|---|---|
| `MACOS_PART=disk0s2` (line 35) and the literal `'disk0s2'` inside the Python at lines 66, 83, 107, 131 | `--macos-part`, default = the container holding the booted System volume (`diskutil info /`) |
| `STUB_NAME="Omarchy"` (36), `ProductName "Omarchy Linux (stub)"` (368) | `--stub-name` (finish-install.sh has `--stub`, line 43; the two must agree) |
| `STUB_SIZE="6G"` (37), `EFI_SIZE="500M"` (38) | `--stub-size`, `--efi-size`; 500 MB holds ~6 payloads of 24 MB plus firmware, keep it |
| EFI partition found by `awk '$2=="EFI" \|\| /Microsoft Basic/' \| tail -1` (300, 304) | the partition `addPartition` just created: diff `diskutil list -plist disk0` before/after, then record its `DiskUUID` (`diskutil info -plist`, the field asahi-installer reads, `src/diskutil.py:134`) |
| Linux partition found by `/Linux\|Linux filesystem/ \| tail -1` (313) | same before/after diff; record its `DiskUUID` |
| FAT label `OMARCHY` (305) | keep (Linux mounts by PARTUUID, not label) |
| Header says "this M5 Pro (J714s)" (5) | board from step 0 |
| No version gate | step 0 gates |

Outputs to record in `install.json` (kept by the installer, copied to the ESP as `m5pro/install.conf`):
stub VGID (`prep-stub.sh:296-298`), ESP PARTUUID, Linux PARTUUID, board, macOS build.

## 2. Firmware (from the stub's own restore bundle)

```
scripts/extract-tpmtfw.py --installer <asahi-installer checkout> \
    --bundle /Volumes/Preboot/<stub VGID>/restore --device-class <board>ap --out <tmp>/fw
```

- `--device-class` defaults to `j714sap` (`extract-tpmtfw.py:103`): pass the board from step 0.
- Use the **stub's** bundle (just cloned), so the blobs pair with the stub's stage-2
  (`extract-tpmtfw.py:29-30`). A Preboot bundle carries the Update identity: pass
  `--behavior Update --variant "macOS Customer Software Update"` (m5pro-linux `boot-and-recovery.md:207-210`).
- The installer vendors asahi-installer's `asahi_firmware` package (pinned commit) instead of
  needing a checkout.
- Write `vendorfw/firmware.tar` (+ `.sha256`, `source.txt` = stub build) to the ESP (step 4) and
  also into the root image (step 3) so the first boot has the trackpad even before
  `m5pro-vendorfw.service` runs.

## 3. Root filesystem (raw write from macOS)

- Download the release root image (built off-device, DESIGN.md "Root image"), verify, then
  `gunzip -c m5root.img.gz | dd of=/dev/rdisk0sN bs=4m` to the Linux partition **by the PARTUUID
  recorded in step 1**, with the same guards `provision-rootfs.sh:27-35` applies (geometry
  matches, partition empty unless repairing). `dd` from macOS needs the partition unmounted; it
  has no filesystem macOS knows, so it is.
- Before writing, inject per-machine files into the image is NOT possible from macOS (no ext4
  write support). So per-machine data goes on the ESP (`m5pro/install.conf`) and a first-boot unit
  reads it (DESIGN.md "First boot").
- The image's `fstab` uses `LABEL=m5root` (`mkrootfs-image.py:26`) and grows on first boot
  (`x-systemd.growfs`); keep both.

## 4. ESP contents (FAT, `diskutil mount <ESP>`)

```
m1n1/boot.bin           stage-2 payload (release build, cmdline root=LABEL=m5root rw ...;
                        first boot rewrites it with root=PARTUUID=<linux>, see DESIGN.md)
m1n1/fallback.bin       same file at install time
m1n1/rescue.bin         rescue payload (initramfs shell + usb-gadget-net + provision tools)
vendorfw/firmware.tar   step 2 (+ .sha256, source.txt)
m5pro/install.conf      board, ESP/Linux PARTUUIDs, stub VGID, macOS build, installer version
m5pro/stage1/           the stage-1 image installed in step 5 (+ .sha256), for reference
```

`boot.bin` is built on the release host by the same code as the pacman hook
(`pkg/m5pro-boot/m5pro-update-payload build --root <image root> --esp <dir>`), so the first boot
and every later kernel update produce the same format. The kernel command line must not carry
`maxcpus=1`: `mkpayload.sh:40` still defaults to it (pre-27.3); the payload hook does not.

## 5. Stage-1 and the ceremony (`finish-install.sh`, parameterised)

1. Build the stage-1 from the release's bare CHAINLOADING m1n1 and the ESP PARTUUID:
   `mk-stage1.py stage1 --m1n1 m1n1-stage1-chain.bin --esp-partuuid <ESP> -o stage1.bin`
   (vars + `\0\0\0\0` + 64 KiB padding; refuses > 0x4D0000; `tools/test-mk-stage1.sh` proves it
   rebuilds today's working `chain-esp-small.bin` byte for byte).
2. `finish-install.sh --m1n1 stage1.bin --stub <name>`. Changes it needs:

   | Today (finish-install.sh) | Make it |
   |---|---|
   | Preflight refuses CHAINLOADING vendor builds (`134-138`); its usage text says the stage-1 must be CHAINLOADING=0 (`prep-stub.sh:377`, `finish-install.sh:136`) | invert: the untethered stage-1 IS a CHAINLOADING build; check with `mk-stage1.py inspect` (build type, 64 KiB multiple, `chainload=` present) |
   | `STUB_NAME`/`DISTRO` constants (32-33) | `--stub` exists; add `--distro` for the step2 banner |
   | `VENDOR_M1N1` default (34) | no default in installer mode: `--m1n1` required |
   | Nothing keeps rescue images on the stub | do what `stage1-install.sh:18-27` does, plus `stub-rescue.sh`, `SHA256SUMS`, `README.txt`: copy `known-good.bin` (= the stage-1 being installed), `proxy.bin` (plain m1n1, padded, `mk-stage1.py stage1 --allow-plain`) to `/Volumes/<stub>/m1n1/` |
   | step2 ends "reboot into m1n1" (`299`) | "reboot into Omarchy" |

3. Ceremony, unchanged from `finish-install.sh:384-393`: `shutdown -h now`, hold power until
   "Loading startup options", pick the stub, step2.sh checks Paired + 1TR, `bputil -nc` (password
   twice), `kmutil configure-boot -c boot.bin --raw --entry-point 2048 --lowest-virtual-address 0`,
   disables the install-media marker, reboots. Next power-on: stage-1 -> `m1n1/boot.bin` -> Linux.

## 6. First boot (DESIGN.md "First boot")

`m5pro-firstboot.service` (in the image) reads `ESP/m5pro/install.conf`, writes
`/etc/m5pro/boot.conf` (`ESP_PARTUUID`), runs `systemd-firstboot --prompt` equivalents on tty1
(user, password, keymap, timezone: there is no network yet), then hands over to Omarchy's deferred
hardware setup (`omarchy-provision-hardware.service`, armed by the image manifest).

## Repair / update boot loader (later runs of the installer)

- **Stage-1 update** (rare; only when `m5pro/stage1/pending.bin` exists on the ESP, staged by
  `m5pro-update-payload stage1` after an `m1n1-m5pro` upgrade): verify its sha256, copy it to the
  stub as `pending.bin`, `finish-install.sh --m1n1 pending.bin`, ceremony; after the next good
  boot it becomes `known-good.bin`.
- **Stub refresh after a macOS update**: `host/macos/refresh-stub-firmware.sh` `check`/`recreate`
  (its size guard `STUB_BYTES < 8000000000`, line 57/142, and the October stage-1 size check,
  line 79, become parameters), then step 2 again (firmware must follow the new stub), then the
  ceremony with `known-good.bin`.
- **ESP rollback from macOS** (no ceremony): mount the ESP, `mv m1n1/boot.bin m1n1/bad.bin;
  cp m1n1/fallback.bin m1n1/boot.bin`.

## Other J714s / this-desk assumptions to remove before anyone else runs these

| File:line | Assumption |
|---|---|
| omarchy-m5 `scripts/mkpayload.sh:26` | `BOARD="j714s"`; DTB derived from the vendor tree (`:60`), which is why `mk-esp-install.sh:22-26` copies its DTB into the kernel tree under a fake board name. Needs `--dtb`. |
| omarchy-m5 `scripts/mkpayload.sh:40` | default bootargs `maxcpus=1` |
| omarchy-m5 `scripts/mkinitramfs.py:42-43,49-50` | J714s framebuffer address and stride hard-coded; the guard only checks `apple,t6050`, so on a J716s `band()` writes `/dev/mem` at the J714s address and stride (whether the J716s framebuffer is at the same address was not checked; 12096 = 3024 x 4 is the 14-inch panel's stride). Distribution initramfs = mkinitcpio, not this. |
| omarchy-m5 `scripts/usb-gadget-net.sh:59` | gadget product string "MBP14 M5 Pro j714s" (m5pro-linux `boot-and-recovery.md:245`) |
| omarchy-m5 `scripts/extract-tpmtfw.py:103` | `--device-class j714sap` default |
| omarchy-m5 `scripts/mkrootfs-image.py:24,90-93` | hostname `m5pro`; root's `authorized_keys` = the builder's `~/.ssh/*.pub`, required (exits without one) |
| omarchy-m5 `scripts/provision-rootfs.sh:21-22` | `nvme0n1p5`: GPT entry numbers depend on the disk's history |
| m5pro-linux `host/macos/mk-esp-install.sh:36-45`, `m5.sh:94` | `/dev/nvme0n1p4`, `/dev/nvme0n1p5`, `m5.root=/dev/nvme0n1p5` |
| m5pro-linux `host/macos/stage1-install.sh:12-14` | images from `~/Work/m1n1/stage1` |
| m5pro-linux `host/macos/1tr-stage1.sh:8` | images served from `<studio-ip>:8000` |
| m5pro-linux `host/macos/refresh-stub-firmware.sh:79` | expects the 5,046,272-byte October stage-1 |
