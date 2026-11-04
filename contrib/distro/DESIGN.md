# Omarchy on M5 Pro: install and update design

Status: design + prototypes, 2026-11-04. Nothing here has run on the MacBook. Sources read:
m5pro-linux (`README.md`, `SOURCES.md`, `docs/boot-and-recovery.md`, `docs/smp-t6050-raw-path.md`,
`host/macos/*.sh`, `patches/`), omarchy-m5 branch `j716s` @ 2c87598 (`scripts/`, `docs/`), m1n1
`m5-t6050` @ f8c3f941 (`src/payload.c`, `src/chainload.c`, `src/main.c`, `rust/src/chainload.rs`,
`rust/src/nvme.rs`), asahi-installer @ e93743d (`src/m1n1.py`, `src/osinstall.py`, `src/main.py`,
`src/diskutil.py`), asahi-scripts `update-m1n1` (online), basecamp/omarchy branch `quattro`
(`docs/lifecycle-dispatch.md`, `bin/omarchy-hw-platform`, `install/helpers/image-target.sh`,
`install/omarchy-aarch64-apple.packages`), omacom/omarchy-mac-pkgs (`README.md`,
`omarchy-mac-boot/README.md`), omacom/omarchy-mac-installer (`README.md`). Claims marked
**[assumption]** were not confirmed in source or docs.

## 1. What the design has to respect

| Fact | Source |
|---|---|
| The stub's stage-2 mBoot comes from the stub's own Preboot restore bundle, cloned from the running macOS at install time; only macOS >= 27.3 beta 1 (26C5035r) carries the multi-core fix. | `smp-t6050-raw-path.md:101-160`, `prep-stub.sh:72-73,335` |
| An existing Permissive LocalPolicy can only be rewritten from 1TR; refreshing the stub to a new restore bundle means recreating the volume group, then a ceremony. | `refresh-stub-firmware.sh:17-22`, `smp-t6050-raw-path.md:141-145` |
| `kmutil configure-boot` works only from the stub's *paired* recoveryOS; from the "Options" recovery it fails with "code pairing". | `boot-and-recovery.md:186-190`, `finish-install.sh:228-261` |
| Stage-1 raw object: a CHAINLOADING build is needed; measured envelope: 0x430000 (padded, CHAINLOADING) boots, 0x4D0000 (plain) boots, 0x4E0000-0x4F0000 loop. The installed object including its variables is padded to a 64 KiB multiple. | `boot-and-recovery.md:123-181`, m1n1 patch 0014 |
| m1n1 takes **one** `chainload=<PARTUUID>;<path>` and keeps the last one it sees. | `src/payload.c` `check_var` (`chainload_spec = val`), `rust/src/chainload.rs:37-40` |
| If the chainload fails (partition/file not found, FAT error), `payload_run` returns -1 and m1n1 falls back to the **USB proxy**: it needs a second machine to do anything. | `src/chainload.c:136-153`, `src/main.c:116-133` |
| m1n1's NVMe/FAT access is read-only (`fatfs::Write` returns `Err`); `nvme.h` exports only `nvme_read`. m1n1 cannot keep a boot counter on disk. | `rust/src/nvme.rs:75-82`, `src/nvme.h:12` |
| Stage-1 passes its `chosen.*` variables to the next stage, appended after the loaded file plus a 4-byte terminator. | `src/payload.c` `payload_run` -> `chainload_load(spec, chosen, chosen_cnt)`, `src/chainload.c:87-98` |
| Stage-2 = plain m1n1 `| chosen.bootargs= | Image.gz | dtb | initramfs`; m1n1 parses gzip, xz, fdt, kernel, variables; not zstd, not uncompressed cpio in a chain scan. | `mkpayload.sh:84-90`, `src/payload.c` `load_one_payload`, `load_cpio` |
| Variable limits: name <= 64, value <= 1024, <= 16 `chosen.*`. | `src/payload.c` `MAX_VAR_NAME`, `MAX_VAR_SIZE`, `MAX_CHOSEN_VARS` |
| macOS can write the ESP (FAT) and a raw partition; asahi-installer writes root images raw from macOS. | `osinstall.py:146-155` |
| No Wi-Fi driver; the only network is the USB gadget to another computer. | m5pro-linux `README.md:18,22` |
| Official Omarchy already models Apple Silicon: platform `aarch64-apple`, detected from the device tree root `apple,*`, whose boot chain operations are delegated to `omarchy-mac-boot` (m1n1 -> U-Boot -> Limine, LUKS). Image builds are supported through a manifest that defers hardware setup to first boot. | `docs/lifecycle-dispatch.md`, `bin/omarchy-hw-platform`, `install/helpers/image-target.sh` |
| The official Omarchy Mac installer blocks M4 and later. | omarchy-mac-installer `README.md` "Supported Macs" |

## 2. Boot chain shipped

```
iBoot (LLB, machine-wide)
  -> stub stage-2 mBoot (from the stub's restore bundle; must be >= 27.3b1)
    -> STAGE-1: CHAINLOADING m1n1, the stub's custom raw boot object (kmutil, 1TR, rare)
         vars: chosen.asahi,efi-system-partition=<ESP>, chainload=<ESP>;m1n1/boot.bin
         padded to 64 KiB, <= 0x430000
      -> ESP:m1n1/boot.bin  (a file; replaced by pacman, no ceremony)
           STAGE-2: plain m1n1 | chosen.bootargs | chosen.m5pro,payload-id | Image.gz | dtb | initramfs.gz
        -> Linux (mkinitcpio initramfs) -> Arch root (ext4, LABEL=m5root / PARTUUID)
```

This is the chain that boots untethered today (`boot-and-recovery.md:174-181`) with two additions:
the `chosen.asahi,efi-system-partition` variable (asahi-installer's name, `osinstall.py:188-189`;
lets Linux find its ESP from `/proc/device-tree/chosen`) and a `payload-id` variable (lets Linux
know which payload it booted). Both are plain `chosen.*` variables m1n1 already forwards.

No U-Boot and no Limine: nobody has ported U-Boot to T6050 that I found **[assumption: not
searched exhaustively]**, and the direct kernel payload already works. Converging on Omarchy's
U-Boot/Limine chain is a later option (section 8).

## 3. Install, end to end

Detailed, with file:line changes, in [`installer/CHECKLIST.md`](installer/CHECKLIST.md). Shape:

1. **Preflight** on macOS: model (Mac17,8/17,9), macOS build >= 26C5035, Preboot restore bundle ==
   running build, no partial install, space, power.
2. **Stub + partitions**: `prep-stub.sh` (parameterised: macOS container, names, sizes, and
   partitions identified by before/after diff, not by `tail -1` of a name match).
3. **Firmware**: `extract-tpmtfw.py` against the stub's own restore bundle -> `vendorfw/firmware.tar`.
4. **Root**: verified prebuilt image written raw to the Linux partition from macOS. No tether, no
   provisioning initramfs.
5. **ESP**: `m1n1/boot.bin`, `fallback.bin`, `rescue.bin`, `vendorfw/`, `m5pro/install.conf`.
6. **Stage-1**: `tools/mk-stage1.py stage1` with the ESP PARTUUID -> `finish-install.sh --m1n1`;
   rescue images + `stub-rescue.sh` copied to `/Volumes/<stub>/m1n1/`.
7. **The one ceremony**: power-hold -> stub -> step2 (`bputil -nc`, `kmutil --raw`).
8. **First boot** straight into Linux: first-boot unit reads `ESP/m5pro/install.conf`, asks for
   user/password/keymap on the console, rebuilds the payload with `root=PARTUUID=`, hands over to
   Omarchy's deferred hardware setup.

Steps 2-6 all run before the ceremony, so the ceremony installs a stage-1 whose `boot.bin` is
already in place. That is what makes it a single ceremony.

## 4. ESP layout and how stage-1 picks a payload

```
ESP (FAT32, 500 MB, label OMARCHY)
  m1n1/boot.bin              the only file stage-1 reads
  m1n1/boot.prev.bin         boot.bin before the last change          (manual rollback)
  m1n1/fallback.bin          last payload that reached boot-complete  (manual fallback)
  m1n1/rescue.bin            initramfs-only rescue payload            (manual)
  m5pro/payloads/<kver>-<hash12>.bin   versioned store (FAT has no symlinks: slots are copies)
  m5pro/payloads.log         one line per build
  m5pro/stage1/pending.bin   stage-1 staged by Linux for the macOS side to install
  m5pro/install.conf         installer hand-off
  vendorfw/firmware.tar(.sha256), source.txt
```

Size: a payload is ~24 MB (measured: 24,470,986 bytes with the October kernel/initramfs), so
three slots + rescue + four stored payloads is ~200 MB of 500 MB.

### The one-path constraint and the options

`chainload=` names one file, the loader cannot write, and a failed load ends in the USB proxy.
So "automatic A/B with fallback on failure" in the systemd-boot sense is **not possible without
m1n1 changes**, and even with them only load failures (file missing/unreadable) can be caught:
once stage-2 has jumped to a kernel that hangs, nothing in m1n1 runs again until a reset, and a
reset loads the same file.

| Option | Changes | Catches | Verdict |
|---|---|---|---|
| A. Fixed name, slots are copies | none (works with today's stage-1) | nothing automatically; recovery by renaming files from Linux, from macOS (`diskutil mount` the ESP), or from a 1TR Terminal | **ship this first** |
| B. Stage-1.5 on the ESP | none in m1n1; `m1n1/boot.bin` becomes a CHAINLOADING m1n1 with `chainload=<ESP>;m1n1/slot-x.bin` (`mk-stage1.py esp`: no terminator, no padding, so stage-1's variables still reach it) | same as A, but m1n1 logic (and the slot pointer) can change with a file copy instead of a ceremony | adopt once a double chainload is tested **[untested: two relocations through patch 0013]** |
| C. Ordered path list in stage-1.5 | small m1n1 patch (proposed 0015): `chainload=<uuid>;a.bin;b.bin` tries each path in `load_image` until one reads | missing or unreadable payload; a gzip/DT error caught by stage-2 still lands in stage-2's proxy | worth it, low risk, shipped in the stage-1.5 so no ceremony is needed to adopt it |
| D. Boot counting | needs persistent state m1n1 can write or read before choosing: FAT writes (new NVMe write path in m1n1), or a reset-surviving register **[assumption: none identified; iBoot's own failure counter in the PMU scratchpad, `boot-and-recovery.md:139-142`, must not be reused]** | hanging kernels | not now |

Why A's manual recovery is acceptable: macOS stays one power-hold away (the picker), and macOS
can fix the ESP with `mv`/`cp`. That is the same recovery Asahi users have, and
`m5pro-update-payload` keeps `boot.prev.bin` and `fallback.bin` filled so there is always
something to copy back.

### Marking good

The payload carries `chosen.m5pro,payload-id=<kver>-<hash>`; m1n1 sets it in `/chosen`
(`kboot_set_chosen`, as it does for `chosen.bootargs`). `m5pro-boot-ok.service` runs after
`boot-complete.target` (gated by `systemd-boot-check-no-failures.service`) and copies `boot.bin`
to `fallback.bin` when the running id equals `boot.bin`'s. A payload booted over the tether has no
id and is never promoted.

## 5. Packages

Prototypes in `pkg/` (all `bash -n` clean, `shellcheck -S warning` clean for the scripts; no
`makepkg` run: not available here and the targets are aarch64).

| Package | Ships | Built from |
|---|---|---|
| `linux-m5pro` (`pkg/linux-m5pro/PKGBUILD`) | `/usr/lib/modules/$kver/{vmlinuz,Image.gz,dtbs/apple/t6050-j71{4,6}s.dtb,pkgbase}`, modules, `/etc/mkinitcpio.d/linux-m5pro.preset` (default image only) | AsahiLinux/linux `asahi-wip-7.2` @ 236788cd + omarchy-m5 `patches/linux/0001-0009` + `dt/` + config fragments, exactly `build-kernel.sh:50-78`, plus `m5pro-distro.config` (modules, vfat, `-m5pro`) |
| `m1n1-m5pro` (`pkg/m1n1-m5pro/PKGBUILD`) | `/usr/lib/m1n1-m5pro/m1n1-stage2.bin` (CHAINLOADING=0), `m1n1-stage1-chain.bin` (CHAINLOADING=1, bare) | m1n1 @ 7cde7d1a + `patches/m1n1/0001-0014`, two tree copies (build_cfg.h trap, `build-m1n1.sh:37-48`); `check()` refuses a stage-1 that would pad past 0x430000 |
| `m5pro-boot` (`pkg/m5pro-boot/`) | `m5pro-update-payload`, `m5pro-mk-stage1`, `95-m5pro-payload.hook`, `96-m5pro-stage1.hook`, `m5pro-boot-ok.service`, `/etc/mkinitcpio.conf.d/m5pro.conf` (`COMPRESSION="gzip"`), `/etc/m5pro/boot.conf` | this repo |
| `m5pro-firmware` (`pkg/m5pro-firmware/`) | `m5pro-vendorfw` + unit: unpacks `ESP/vendorfw/firmware.tar` to `/run/m5pro/vendorfw` and sets `/sys/module/firmware_class/parameters/path` | this repo; ships **no** Apple blobs |

### The pacman hook

`95-m5pro-payload.hook` (PostTransaction; after `90-mkinitcpio-install.hook` by name order)
triggers on the kernel image, DTBs, the stage-2 m1n1, initcpio files, the gzip drop-in, and
upgrades of `m5pro-boot`/`mkinitcpio`. It runs `m5pro-update-payload build`, which:

1. finds the ESP from `/proc/device-tree/chosen/asahi,efi-system-partition`, else `ESP_PARTUUID`
   in `/etc/m5pro/boot.conf` (today's installed stage-1 lacks the chosen variable), mounts it if
   needed;
2. assembles `m1n1-stage2.bin | chosen.bootargs=$CMDLINE | chosen.m5pro,payload-id | Image.gz |
   t6050-<board>.dtb | /boot/initramfs-linux-m5pro.img` (board from the DT root `compatible`);
   refuses a non-gzip initramfs and a cmdline >= 1000 bytes;
3. walks the chain the way m1n1 does (port of `mkpayload.sh:94-147`) and requires
   var, var, kernel, dtb, initramfs;
4. stores it as `m5pro/payloads/<id>.bin`, writes `boot.bin.new`, syncs, moves the old
   `boot.bin` to `boot.prev.bin`, renames; fills `fallback.bin` if empty; prunes the store.

Other verbs: `verify` (rebuild and compare: this is what an Omarchy `update-verify` entrypoint
calls), `rollback`, `select <id>`, `select-file rescue.bin`, `mark-good`, `stage1`, `status`.

Tested here against the real October artifacts (`~/Work/studio-artifacts`: Image.gz, J716s DTB,
initramfs; `m1n1-linuxbuild/m1n1-plain.bin`) in a fake root and fake ESP: build, idempotent
rebuild, verify (match), verify after a cmdline change (stale, exit 1), second build (prev slot
filled), status, rollback, zstd initramfs refused. Not tested: the ESP mount path, `mark-good`
with a live `/chosen`.

Kernel command line: `/etc/m5pro/boot.conf` `CMDLINE`, or `/etc/m5pro/cmdline` if present. Same
role as asahi-scripts' `/etc/m1n1.conf` (`update-m1n1` copies only `chosen.`, `display=`,
`mitigations=` lines into `boot.bin`); a later convergence can read that file instead.

### Stage-1 updates

Linux cannot install a stage-1. `96-m5pro-stage1.hook` runs `m5pro-update-payload stage1` after an
`m1n1-m5pro` upgrade: if the package's stage-1 version differs from
`/chosen/asahi,m1n1-stage1-version` (set by every CHAINLOADING build, `src/payload.c`), it builds
`m5pro/stage1/pending.bin` with `m5pro-mk-stage1` and tells the user to run the installer's
"Update boot loader" from macOS (one ceremony). With option B (stage-1.5) in place, stage-1 stops
needing updates at all: it only ever loads `m1n1/boot.bin`.

### `tools/mk-stage1.py`

Builds `stage1` (vars + `\0\0\0\0` + 64 KiB pad, refuse > 0x4D0000, warn > 0x430000) and `esp`
(stage-1.5: vars only) objects, and `inspect`s any object (build type by marker strings, variables
after `STACKBOT`, terminator, padding). Refuses plain builds for chainload stages, already-varred
inputs, bad UUIDs, absolute or `;` paths, unknown variable names, duplicate `chainload=`,
too many `chosen.*`. `tools/test-mk-stage1.sh` rebuilds the stage-1 that boots the M5 today
(`~/Work/stage1-serve/chain-esp-small.bin`, 0x430000) **byte for byte** from its bare m1n1 and
the ESP UUID, and checks the refusals. (It first matched against the 17:12 build in
`~/Work/m1n1-linuxbuild/m1n1-chain.bin`; that file was rebuilt in place at 17:59 with different
bytes, so the test now cuts the bare m1n1 out of the reference image at `STACKBOT`.)

## 6. Firmware

Apple firmware is extracted, never shipped. The macOS installer runs `extract-tpmtfw.py` on the
**stub's** restore bundle (the blob must pair with the stub's stage-2, `extract-tpmtfw.py:29-30`)
and writes `vendorfw/firmware.tar` to the ESP, the directory name asahi-installer uses
(`osinstall.py:163-167`, `main.py:491-560` for its "rebuild vendor firmware" action). Linux reads
it at every boot (`m5pro-vendorfw.service`), so a stub refresh from macOS that rewrites
`vendorfw/` is picked up without a package change. The root image also carries a copy for the
first boot. Today that is one file, `apple/tpmtfw-j716s.bin`; Wi-Fi/BT, GPU, DCP firmware will
join the same tar when drivers exist.

## 7. Root image and first boot

Built off-device (the Studio is aarch64, so natively, no QEMU), from the Arch Linux ARM tarball as
`mkrootfs-image.py` does today, plus:

- the four packages above from a `[m5pro]` repo, `mkinitcpio` with the gzip drop-in;
- no SSH keys of the builder (`mkrootfs-image.py:90-93` requires them today), no locked-only root:
  `systemd-firstboot` style prompts on tty1 instead, because console login is the only login a
  non-expert has (`boot-and-recovery.md:216-218`);
- `m5pro-firstboot.service` **[to write]**: reads `ESP/m5pro/install.conf`, writes `ESP_PARTUUID`
  and `root=PARTUUID=<linux>` into `/etc/m5pro/`, runs `m5pro-update-payload build`, enables the
  USB gadget network unit;
- Omarchy preinstalled (below), since the device has no network of its own.

### Layering Omarchy

Omarchy supports exactly this: an image built away from the machine, declared by
`/var/lib/omarchy/image/target` (`format=1`, `platform=aarch64-apple`), with hardware leaves
queued and run by `omarchy-provision-hardware.service` on the first boot
(`install/helpers/image-target.sh`). `omarchy-hw-platform` will call the M5 `aarch64-apple`
because its DT root is `apple,j716s`. That brings two things we must handle:

1. `install/omarchy-aarch64-apple.packages` pulls `omarchy-mac-boot` and `omarchy-mac`.
   `omarchy-mac-boot` assumes m1n1 -> U-Boot -> Limine, `update-m1n1`, LUKS with a staged key
   (its README), none of which exist here. It must not be installed as is.
2. `omarchy-lifecycle-dispatch` *requires* `/usr/lib/omarchy/mac-boot/<op>` entrypoints on
   `aarch64-apple` (provision-*, reset-*, update-verify, update-takeover, luks-slots, setup-boot)
   and fails closed without them.

Plan: an `omarchy-m5pro-boot` package that installs those entrypoints for this chain and takes
`omarchy-mac-boot`'s place: `update-verify` = `m5pro-update-payload verify`; `setup-boot` =
`m5pro-update-payload build` (or create `/var/lib/omarchy/image/boot-rebuild` with
`image-first-boot`); `update-takeover` refuses `/efi`, `/boot`, `/usr/lib/m1n1-m5pro`;
`provision-*`/`luks-slots`/`reset-*` implement the "no encryption" case (verify = nothing staged)
until LUKS is supported. How it takes the place: either `provides=/conflicts=` (whether Omarchy's
installer accepts a provider for a name in its package list is **[assumption, unverified]**), or
a package literally named `omarchy-mac-boot` in a `[m5pro]` repo listed before Omarchy's in
`pacman.conf` (pacman takes a package from the first repo that has it). `omarchy-mac` (runtime
services: Wi-Fi backend, speakers, notch) mostly targets hardware that has no driver here yet;
install it only after checking each service tolerates missing devices **[unverified]**.
`asahi-bless` (in the same list) writes Apple NVRAM; untested on M5, leave it out.

Longer term the clean home for this is upstream: a "direct-kernel" variant in
omacom/omarchy-mac-pkgs, or U-Boot on T6050 so the M5 joins the existing Limine chain.

## 8. Recovery paths

| Failure | What you see | Fix | Needs |
|---|---|---|---|
| New kernel/initramfs boots badly | panic/hang after the logo | power-hold -> Macintosh HD; `diskutil mount` the ESP; `cp m1n1/fallback.bin m1n1/boot.bin` (or `boot.prev.bin`). From Linux, if it boots enough: `m5pro-update-payload rollback`. | macOS |
| `m1n1/boot.bin` missing/unreadable | stage-1 falls into the USB proxy (black screen with m1n1 log) | same copy from macOS; or with a second machine, `chainload.py` (`boot-and-recovery.md:42-61`) | macOS or tether |
| Need a shell without the root | | `cp m1n1/rescue.bin m1n1/boot.bin` from macOS (rescue = initramfs with `usb-gadget-net`, `provision-rootfs`) | macOS |
| Bad stage-1 (after a stage-1 update) | boot loop into "needs to be reinstalled" recovery | macOS route first (clears iBoot's failed-boot count, `boot-and-recovery.md:137-142`): boot macOS, installer "Repair" = `finish-install.sh --m1n1 known-good.bin` + ceremony | macOS + ceremony |
| Bad stage-1 and macOS does not boot | | Options -> Terminal: `sh /Volumes/<stub>/m1n1/rescue.sh install known-good` copies the checksummed image into `Finish Installation.app/Contents/Resources/boot.bin` and re-arms the install-media markers (kmutil itself refuses outside the paired recovery); then power-hold -> stub -> step2 runs `kmutil`. Caveat: the evening probes that used this shortcut all failed, attributed to the uncleared failure count (`boot-and-recovery.md:137-142`). | 1TR |
| macOS update leaves the stub on old mBoot | still boots (stub keeps its bundle) | nothing required; `refresh-stub-firmware.sh recreate` + firmware re-extract + ceremony only when a newer mBoot fix is wanted | macOS + ceremony |
| Remove Linux | | `finish-install.sh --undo`, delete partitions by type (`bringup.md:72-110`) | macOS |

What stays on the stub volume (`/Volumes/<stub>/m1n1/`, written by the installer):
`known-good.bin` (the stage-1 last installed and booted), `proxy.bin` (plain m1n1, padded: lands
in the USB proxy for tethered work), `pending.bin` (only during a stage-1 update), `SHA256SUMS`,
`rescue.sh` (`installer/stub-rescue.sh`), `README.txt`. The one-line kmutil restore, valid only
inside the stub's paired 1TR (step2's shell):

```
kmutil configure-boot -c /Volumes/Omarchy/m1n1/known-good.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v /Volumes/Omarchy
```

## 9. Assumptions and unconfirmed points

- Double chainload (stage-1 -> stage-1.5 -> stage-2), each relocating per patch 0013: untested.
- `firmware_class.path` set at runtime through sysfs before the trackpad's first open: the
  parameter exists (writable module parameter); timing relative to the driver's first request is
  from `mkrootfs-image.py:81-82` ("loads it on every open"), not re-checked in the driver.
- mkinitcpio with this kernel (all needed storage drivers `=y`, `build-kernel.sh:74-78`) producing
  a working initramfs: untested; today's initramfs is the Alpine one from `mkinitramfs.py`.
- USB host mode (USB Ethernet, keyboards on USB-C) under Linux: not established; patch 0005 skips
  the USB-PD HPM probe in m1n1 and Linux has only gadget mode demonstrated.
- Omarchy accepting a substitute for `omarchy-mac-boot`; `omarchy-mac` services on hardware
  without drivers.
- No public U-Boot for T6050 (not searched exhaustively).
