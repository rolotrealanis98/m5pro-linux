# Boot, provision, recover

The M5 (`ssh mbp` when in macOS) and the Studio (`ssh omarchy`) are joined by a USB-C cable on a
CalDigit TS5 Plus USB-C data port. Under m1n1 the Mac is USB device `1209:316d` (`/dev/m1n1`,
`/dev/m1n1-sec`); under Linux it is a CDC EEM gadget (`1d6b:0104`, M5 = `10.55.0.2`).

## Disk layout on the M5 (GPT entry numbers; macOS names differ)

| GPT | Size | What |
|---|---|---|
| p1 | 0.6 GB | iBootSystemContainer — never touch |
| p2 | 813.0 GB | macOS container (Macintosh HD) |
| p3 | 6.0 GB | "Omarchy" stub (Data, System, Preboot, Recovery); m1n1 is its boot object |
| p4 | 0.5 GB | EFI (FAT32, label OMARCHY) |
| p5 | 175.0 GB | Linux root, ext4 label `m5root` = `/dev/nvme0n1p5` (macOS calls it disk0s7) |
| p6 | 5.4 GB | RecoveryOSContainer — never touch |

## One-time install (done 2026-10-20)

On macOS, from the omarchy-m5 checkout (scripts reviewed before running):

```bash
sudo scripts/prep-stub.sh --linux-size 175G
```
```bash
sudo scripts/finish-install.sh --m1n1 ./m1n1.bin
```

`m1n1.bin` is the plain (no `CHAINLOADING`) build. Then: shut down, hold power until "Loading
startup options", pick Omarchy, enter the password twice. The stub becomes the default startup
disk. The live macOS container resize took ~25 min (APFS live mode); do not interrupt it.

## Studio host setup (done)

```bash
sudo install -m 644 host/70-m1n1-uaccess.rules host/81-m5-gadget.rules /etc/udev/rules.d/ && sudo udevadm control --reload
```

`80-m1n1.rules` (m1n1's own, creates `/dev/m1n1`) is also installed. NAT for the M5, until the
Studio reboots: `sudo bash host/m5-nat.sh`.

## Every boot (tethered, until the stage-1 ceremony below)

1. Power on the M5: it starts in m1n1 and waits.
2. Chainload the working-tree m1n1 (SEPFW dropped so the image clears the M5's CTRR window):

```bash
cd ~/Work/m1n1/proxyclient && M1N1DEVICE=/dev/m1n1 PYTHONPATH=. ../.venv/bin/python tools/chainload.py -r -n ../build/m1n1-chain.bin
```

3. Boot Linux (run it in a terminal: `linux.py` ends in an interactive console):

```bash
cd ~/Work/m1n1/proxyclient && L=~/Work/omarchy-m5/vendor/linux && M1N1DEVICE=/dev/m1n1 PYTHONPATH=. ../.venv/bin/python tools/linux.py $L/arch/arm64/boot/Image.gz $L/arch/arm64/boot/dts/apple/t6050-j716s.dtb ~/Work/omarchy-m5/build/initramfs.cpio.gz -b "earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5"
```

4. About 20 s later the gadget appears and the Studio gets `10.55.0.1` from udev:

```bash
ssh -i ~/.ssh/mbp root@10.55.0.2
```

Root and `alarm` passwords are locked: SSH with the key is the only login.

`build/m1n1-chain.bin` is built with `CHAINLOADING=1`; the plain build is `build/m1n1.bin`.
After a config change delete `build/build_cfg.h` before `make`.

## Host on the Studio's macOS side (set up 2026-11-04)

When the Studio is booted into macOS instead of Omarchy, the same tree exists there: `~/Work/m1n1`
(branch `m5-t6050`, venv in `.venv`, `build-plain/m1n1.bin` and `build/m1n1-chain.bin`) and
`~/Work/omarchy-m5` (branch `j716s`). The M5 in m1n1 enumerates as `/dev/cu.usbmodemP_01`; no
udev. [`host/macos/m5.sh`](../host/macos/m5.sh) wraps the proxyclient: `wait`, `fw`, `smp-test`
(the 27.3 re-test, logged to `~/Work/m5-logs/`), `shell`, `py FILE`.

Build notes for macOS: Apple's `make` is 3.81 and cannot parse the Makefile's `&:` rules, so use
Homebrew `gmake`; `~/.cargo/bin` must precede the Homebrew Rust on `PATH` (rustup with the
`aarch64-unknown-none-softfloat` target and `rust-src`); and Homebrew clang 23.1.4 rejects the
`tlbi vmalls12e1os` in `hv_sprr.c` at `-march=armv8.2-a`, so pass
`EXTRA_CFLAGS="-Wstack-usage=2048 -march=armv8.4-a"`. Delete `build/build_cfg.h` between the plain
and `CHAINLOADING=1` builds. These images are not byte-identical to the Linux-side ones.

The Omarchy root is btrfs (`asahi-root`, unencrypted) on `disk0s5`; macOS cannot mount it but
[`host/macos/omarchy-volume.py`](../host/macos/omarchy-volume.py) reads it raw (dissect.btrfs). The
October builds and the M5 SSH key were copied out that way into `~/Work/studio-artifacts`, which
`m5.sh boot-linux` uses by default (`M5_ARTIFACTS=` overrides; the kernel built here lives in
`~/Work/omarchy-m5/vendor/linux`, a symlink to the case-sensitive image `/Volumes/linux-cs`).

Limits of the macOS host: the M5's gadget is CDC-EEM, which macOS has no driver for, so there is no
`10.55.0.x` network and no SSH from macOS; the panel is the console. Boot without `m5.root=` to stay
in the initramfs shell (banner shows `cpus:`), or boot from the Omarchy side for SSH.

## Untethered boot (2026-11-04: stage-2 from the ESP works; stage-1 ceremony pending)

Asahi layout. Stage-1 m1n1 (the stub's boot object, a `CHAINLOADING=1` build with
`chainload=<ESP PARTUUID>;m1n1/boot.bin` appended) loads stage-2 from the
EFI partition (p4, that PARTUUID, FAT) with its own NVMe + FAT drivers, which work on T6050 under the
27.3 firmware (`nvme-proxy-probe.py` lists the GPT). Stage-2 = plain m1n1 + `chosen.bootargs` +
`Image.gz` + `t6050-j716s.dtb` + `initramfs.cpio.gz` (omarchy-m5 `mkpayload.sh`, ~24 MB). A kernel
update is then a file copy to the ESP, no ceremony.

Two things were needed:

- m1n1 patch 0013: the device-side `chainload_image()` placed the new image in place at `_base`,
  and patch 0004 refuses that when it would cover the secondary-only CTRR window (12 MiB above
  `_base` on a J716s, so a 30 MiB stage-2 never fits). 0013 relocates the image above the window
  and above its own staging buffer instead; the next m1n1's heap starts above it.
- Getting the payload onto the ESP from a macOS host (no network to the M5): `host/macos/mk-esp-install.sh`
  builds the payload and a one-shot initramfs overlay (`rdinit=/esp-install.sh`) that mounts p4,
  copies `m1n1/boot.bin`, checks the hash and reboots into stage-1. Boot it over the tether:

```bash
host/macos/mk-esp-install.sh
LINUX_INITRD=~/Work/omarchy-m5/build/initramfs-esp-install.cpio.gz LINUX_ARGS="earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 rdinit=/esp-install.sh" host/macos/m5.sh boot-linux
```

Verified tethered: `chainload.py -r -n ~/Work/m1n1/build/m1n1-chain-esp.bin` (CHAINLOADING=1 build of
`m5-t6050` @ dece1ac1 with the variable appended) read the 25,322,926-byte file from the ESP,
relocated it and booted Linux into the Arch root on 18 cores with no proxy
(`~/Work/m5-logs/esp-chainload-20261104-152732.log`). The variable must be *appended to the image*;
passing it as `chainload.py` boot args is ignored.

Remaining: make that image the stage-1. On the M5 in macOS:
`sudo scripts/finish-install.sh --m1n1 ~/Work/m1n1/m1n1-chain-esp.bin` (omarchy-m5 checkout) and
the 1TR ceremony. If the ESP load ever fails, stage-1 falls back to the proxy as before.
Note the image is built on macOS (clang 23.1.4, `-march=armv8.4-a`), not the Linux-side toolchain.

## Re-provisioning the root filesystem

Writes p5 only, refuses unless the geometry matches and the partition is empty (`FORCE=1` to
overwrite). Boot `build/initramfs-provision.cpio` (from `mkinitramfs.py --rootfs-image`) without
`m5.root`, then on the M5's keyboard:

```
provision-rootfs 200224487 42724609
```

## Recovery

- **Back to macOS:** hold power → boot picker → Macintosh HD. The stub stays the default.
- **Hung Linux or m1n1:** hold power until off, press once → m1n1 again.
- **Watchdog:** `wdt-arm.py N` (omarchy-m5, max 170 s) resets into m1n1 unless something disarms
  it; a chainload with `m1n1.wdt=keep` keeps it armed and m1n1 pets it (patch 0012).
- **Remove everything:** in macOS set Startup Disk to Macintosh HD first, then
  `sudo scripts/finish-install.sh --undo` and delete p5, p4 and the p3 container by type and size
  (omarchy-m5 `docs/bringup.md`, "Resizing or re-installing"); grow p2 back.

## Known gaps

- SMP works since 2026-11-04 (stub rebuilt on macOS 27.3 beta 1, see `smp-t6050-raw-path.md`): 18 cores in the initramfs. Stubs built from macOS < 27.3 boot one core.
- No backup of the M5 exists (no Time Machine destination).
- The gadget calls itself "j714s" (hard-coded in omarchy-m5's `usb-gadget-net.sh`): cosmetic.
