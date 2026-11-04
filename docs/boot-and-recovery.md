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

## Every boot (tethered; only needed when `m1n1/boot.bin` is absent from the ESP)

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

### Stage-1 attempts (2026-11-04, evening): every CHAINLOADING image boot-loops from iBoot

Installing a CHAINLOADING=1 m1n1 as the stub's boot object makes the Mac boot-loop into the
"The version of macOS on the selected disk needs to be reinstalled" recovery. Probes, each one
ceremony, each landing in that recovery:

| stage-1 image | size | result |
|---|---|---|
| October plain (CHAINLOADING=0, Linux clang 23) | 0x4D0000 | boots (baseline, restored each time) |
| macOS clang 23 CHAINLOADING + `chainload=<ESP>;m1n1/boot.bin` | 0x4E0000 + var | loop |
| same, variable pointing at a nonexistent file | 0x4E0000 + var | loop (never enumerates USB) |
| October Linux clang 23 CHAINLOADING + nonexistent-file variable | 0x4F0000 + var | loop |
| October plain zero-padded to 0x4F0000 | 0x4F0000 | loop (one run; to be re-confirmed) |

Caveat on that table: only the first row's failure went through the `finish-install.sh` route;
the three probes used the `arm` shortcut, after which even `boot-plain` failed, so they are void.
The likely reason (aurora-silicon/m1n1 337f3486): iBoot counts failed boots in the PMU's legacy
scratchpad and drops to the "needs to be reinstalled" screen once the count is high; macOS clears
it after a good boot, which every `finish-install` round trip did and the shortcut never did.
m1n1 can clear it too (`proxyclient/tools/reset_panic_counter.py`) once a stage-1 is up.

What the research found (2026-11-04): the cliff is image size, on the iBoot side, and it is
reproduced on two other chips with the *same bytes merely padded*: bretttegart/j604-linux
(T8132, 0x3B0000 boots, zero-padded copy boot-loops with no m1n1 output) and aurora-silicon/m1n1
f24d7197 (T8140 J700, 0x410000 boots, 0x420000 hangs before the logo). iBoot's own allocations
(boot_args, the 48 KiB SMP-RO window) sit a fixed distance above the image base, so the usable
size is layout-relative, not a documented cap. Our plain image is 0x4D0000 and boots; the
CHAINLOADING build is 0x4F0000 and does not.

The practical fix, untested: shrink the CHAINLOADING stage-1 below 0x4D0000. Most of the raw file
is zeros from `secondary_stacks[MAX_CPUS=32][0x10000]` (2 MiB, `src/smp_asm.h`, `src/smp.c:46`);
the J716s has 18 cores, Gravity's fork already uses `MAX_CPUS 24`. `MAX_CPUS 24` alone saves
0x80000 and puts the chainloading image around 0x470000. Dropping `LOGO=` saves another ~320 KiB.
Keep `.bss` and the stacks inside the file part (aurora 8bd67a82: iBoot places live coprocessor
buffers on the page right after the raw file). Protocol for the next attempt: build, check the
size, install through the macOS route (a macOS boot clears the failure counter), and if it loops,
back to macOS and `boot-plain`. Also to check on the stage-2 side: that the relocated stage-2's
`secondary_stacks`/`_smp_shared` never land in the old SMP-RO window (Gravity 093767c9 allows the
overlap; aurora 32c043bf saw EL2 faults from L2 blocks crossing it).

Second finding (research, 2026-11-04): on M4+ the installed raw object **including appended
variables** must be a 16 KiB multiple. GravityLinux/installer 517c72a pads "the complete boot
object, including variables" to 64 KiB for T8132; the Esocidae M5 project saw a 23,610,751-byte
object rejected and a 16 KiB-aligned one accepted. Our plain October image is exactly 0x4D0000;
every image we appended `chainload=` to was not aligned. So the one genuine failure may be
alignment, size, or both. Candidates are now padded to a 64 KiB multiple after the variable and
its `\0\0\0\0` terminator. Fallback if a padded, small raw image still loops: aura's Mach-O wrapper
(`tools/macho_boot_object.py`, `kcbz: 0`, installed without `--raw`), tested by them on T8140.
Prior art for untethered M5 (base chip only): Esocidae (eliott.info/pond), all 10 cores from
internal storage since 2026-09-14.

Done on 2026-11-04 evening: m1n1 patch 0014 (`MAX_CPUS 32 -> 24`) brings the CHAINLOADING image to
0x420000 (Linux toolchain build in the Fedora container, `~/Work/m1n1-linuxbuild`). Tethered
regression with the ESP variable appended and the file padded to 0x430000
(`~/Work/stage1-serve/chain-esp-small.bin`): it loads stage-2 from the ESP and boots Linux on 18
cores. Installed as stage-1 through the macOS route
(`stage1-install.sh` + ceremony) on 2026-11-04 ~17:40: **the M5 boots Linux untethered**, power-on
to the Arch login. Correction from the first SSH session into that root: it runs on **1 CPU**
(`smp: Brought up 1 node, 1 CPU`; the cmdline gained `idle=nop arm64.nowfxt` from kboot). Cause:
the secondaries' RVBAR is locked by iBoot to the stage-1 image base; chainload.py chainloads in
place (same base, so RVBAR points at the new image and SMP works, hence the 18 penguins), but the
ESP stage-2 is relocated above the CTRR window by patch 0013, so released cores reset into
stage-1's old vector table, m1n1 prints "Failed!" and prunes them (aurora-silicon 8bd67a82 notes
the same). Fix, done 2026-11-04 18:08 (m1n1 patch 0015, stage-2 @ 459a3af2): when RVBAR is locked and differs
from `_vectors_start`, `smp_start_cpu()` installs a trampoline (`ldr x16, #8; br x16; .quad
_vectors_start`, rest `b .`) in slot 0 at the locked address, with dc civac / ic ivau and a readback
under an exception guard, once per locked address, only if the address is in RAM below `_base`;
kboot adds an FDT `/memreserve/` of 0x80 bytes for it. Deployed as an ESP file update over the
SSH bridge (`eem-vm.py --put`), one reboot: `smp: Brought up 1 node, 18 CPUs`, `nproc` 18,
untethered. `/boot/m1n1/boot.bin.prev` on the ESP (systemd automounts the ESP at `/boot`) holds
the previous 1-CPU payload; `cp` it back to roll back. New cpufreq fact from that boot:
`apple_soc_cpufreq_init: failed to add OPP table: -19` for cpu12-17 (MIDR 0x611f0651 cluster).

Access without a tether: `~/Work/eem-vm/eem-vm.py` (README there) boots a Debian guest under QEMU
with the M5's EEM gadgets passed through and proxies SSH to root@10.55.0.2; `--shell`, `--keep`.
Console logins for root and alarm were enabled on 2026-11-04 with a temporary password Rolando
knows; change it. Whether the fix was the size (0x4F0000 -> 0x430000), the 64 KiB
alignment of the appended-variable image, or both, is not separated; both are kept.

Tooling that came out of it (all in `host/macos/`):
- `1tr-stage1.sh`, served from the Studio with `cd ~/Work/stage1-serve && python3 -m http.server 8000`
  (the Studio is <studio-ip>). From any recovery Terminal (join Wi-Fi first):
  `sh <(curl -s <studio-ip>:8000/stage1.sh) <image> arm` copies the image into the stub's
  `Finish Installation.app` as `boot.bin`, re-arms the install-media markers and reboots; then
  power-hold -> Omarchy runs step2 (bputil -nc + kmutil) in the stub's *paired* recovery. `kmutil`
  from the "Options" recovery fails with "Boot policy error: ... code pairing". `check` prints the
  installed boot.bin hash. `boot-plain` is the rollback.
- `stage1-install.sh`: the macOS-side variant (finish-install.sh + copies images to the stub).
- `m5.sh log`: m1n1 replays its whole boot log on the primary USB interface when a host opens it
  (pyserial with DTR), so any stage-1 that reaches the proxy can be read back; a stage-1 that dies
  before USB init shows nothing. `m5.sh reboot`: macvdmtool reboot over a Thunderbolt cable from the
  Studio's DFU port (rear, next to Ethernet) to the M5's port next to MagSafe. Serial mode over that
  cable answers BUSY (`0x05ac80d2`) on this firmware; `/chosen/debug-enabled = 0`.
- `sudoers-m5pro`: scoped passwordless sudo for the two macOS-side scripts (install from the M5).
- m1n1 built with a Linux toolchain in an Apple `container` Fedora VM
  (`~/Work/m1n1-linuxbuild`, clang 21): same sizes as the October builds.

## Trackpad (started 2026-11-04 evening)

Kernel and DT were already in place (omarchy-m5 patch 0005 dockchannel MTP, `CONFIG_HID_DOCKCHANNEL=y`,
`CONFIG_HID_MAGICMOUSE=y`, `&mtp_hid` in `t6050-j716s.dts` naming `apple/tpmtfw-j716s.bin`); only the
firmware blob was missing. omarchy-m5's `scripts/extract-tpmtfw.py` works on real data (first run):
with `--installer ~/Work/asahi-installer --device-class j716sap` and the public 27.2 IPSW
(`--ipsw`, ~30 MB of range requests) it wrote an 81,420-byte `HIDF` blob. The blob from the build the stub
boots (27.3 beta 1 bundle, `--bundle ~/Work/stub-backup-26C5035r/restore --behavior Update
--variant "macOS Customer Software Update"`, since a Preboot bundle carries the Update identity)
is byte-identical to the 27.2 one, so the shipped blob is final. Delivery: `mkinitramfs.py --firmware DIR` packs it under
`/lib/firmware`, and `host/macos/mk-esp-install.sh --initramfs ... --firmware DIR` rebuilds the ESP
stage-2 payload with it and makes the one-shot installer also copy the tree into the Arch root
(`/usr/lib/firmware/apple/`). Both done on 2026-11-04.

Operational note for the untethered stage-1: it goes straight to Linux, so the proxy is only
reachable if `m1n1/boot.bin` is removed from the ESP (from Linux), or by re-installing
`boot-plain`. Console passwords on the Arch root are still locked (SSH-key only, Linux hosts only);
set them from a Linux host over the gadget, or via the `root-passwd` overlay before going untethered. To verify: in the
initramfs (`no m5.root`) `cat /proc/bus/input/devices` should list the trackpad; in Arch, `libinput`.

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
