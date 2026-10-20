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

## Every boot (tethered)

1. Power on the M5: it starts in m1n1 and waits.
2. Chainload the working-tree m1n1 (SEPFW dropped so the image clears the M5's CTRR window):

```bash
cd ~/Work/m1n1/proxyclient && M1N1DEVICE=/dev/m1n1 PYTHONPATH=. ../.venv/bin/python tools/chainload.py -r -n ../build/m1n1-chain.bin
```

3. Boot Linux (run it in a terminal: `linux.py` ends in an interactive console):

```bash
cd ~/Work/m1n1/proxyclient && L=~/Work/omarchy-m5/vendor/linux && M1N1DEVICE=/dev/m1n1 PYTHONPATH=. ../.venv/bin/python tools/linux.py $L/arch/arm64/boot/Image.gz $L/arch/arm64/boot/dts/apple/t6050-j716s.dtb ~/Work/omarchy-m5/build/initramfs.cpio.gz -b "maxcpus=1 earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5"
```

4. About 20 s later the gadget appears and the Studio gets `10.55.0.1` from udev:

```bash
ssh -i ~/.ssh/mbp root@10.55.0.2
```

Root and `alarm` passwords are locked: SSH with the key is the only login.

`build/m1n1-chain.bin` is built with `CHAINLOADING=1`; the plain build is `build/m1n1.bin`.
After a config change delete `build/build_cfg.h` before `make`.

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

- One CPU core only (`maxcpus=1`).
- No backup of the M5 exists (no Time Machine destination).
- The gadget calls itself "j714s" (hard-coded in omarchy-m5's `usb-gadget-net.sh`): cosmetic.
