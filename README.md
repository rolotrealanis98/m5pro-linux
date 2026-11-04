# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-11-04)

| Area | State |
|---|---|
| m1n1 installed as the stub's boot object (macOS 27.2 stays at Full Security) | works |
| m1n1 proxy over USB-C to the Studio, through the CalDigit TS5 Plus | works |
| Chainloading m1n1 builds (`chainload.py -r -n`) | works |
| Linux 7.2 (asahi-wip-7.2 + omarchy-m5 patches), J716s device tree | boots untethered from the ESP, 18 CPUs |
| Framebuffer console, built-in keyboard, NVMe read/write, USB gadget network | works |
| Arch Linux ARM root on the internal SSD (GPT entry 5 = `nvme0n1p5`) | works, systemd `running` |
| SMP (secondary cores) | **works, 18 cores** (2026-11-04): stub rebuilt on macOS 27.3 beta 1, whose stage-2 mBoot carries Apple's fix for raw boot objects on M5 Pro/Max/Ultra (release notes, mBoot > Resolved Issues). No m1n1 or kernel change needed; `maxcpus=1` dropped. Any stub must be built from macOS >= 27.3 beta 1. [`docs/smp-t6050-raw-path.md`](docs/smp-t6050-raw-path.md) |
| Trackpad | firmware extracted and shipped; first boot logs `dockchannel-hid: input iface multitouch start timed out` (2026-11-04). Keyboard works. Next: dmesg from the Arch root. |
| GPU, display driver (DCP), Wi-Fi/BT (N1), audio | not started |
| Untethered boot (kernel on the ESP) | **works on all 18 CPUs** (2026-11-04 18:08): stage-1 = CHAINLOADING m1n1 (0013+0014, chainload variable, 64 KiB-aligned) installed once; stage-2 on the ESP = m1n1 with patch 0015 (reset-vector trampoline for a relocated image) + kernel + DTB + initramfs. Kernel updates are an ESP file copy over the SSH bridge. [`docs/boot-and-recovery.md`](docs/boot-and-recovery.md) |

## Layout

| Path | What |
|---|---|
| `patches/m1n1/` | `git format-patch` series on upstream m1n1 (see SOURCES.md). 0001-0007: omarchy-m5's T6050 patches, rebased (author kept). 0008-0015: written here (0013: chainload relocation above the CTRR window, for stage-2 from the ESP; 0014: MAX_CPUS 24 so a chainloading stage-1 stays under the T6050 raw-image size cliff; 0015: a relocated m1n1 plants a trampoline at the locked RVBAR so secondaries reach it, and reserves it in the FDT). |
| `patches/omarchy-m5/` | Changes to the omarchy-m5 checkout: J716s board DT, measured PMGR boot state, `GCC=1` kernel builds; `0002` adds `finish-install.sh --macho`. |
| `dt/` | The J716s board DTS and its measured PMGR power-state table, also inside the patch above. |
| `host/macos/` | The same tether from the Studio booted into macOS: `m5.sh`, stub refresh/recreate, ESP installer, Omarchy-volume reader. |
| `host/` | Studio-side (Omarchy) config: udev rules for the m1n1 device and the M5's USB network, the NAT script. |
| `scripts/` | Tether helpers used on the Studio (tmux-driven proxy sessions, watchdog-guarded rounds). They expect the omarchy-m5 checkout at `~/Work/omarchy-m5`. `scripts/probes/` are the SMP hardware probes, `scripts/kc/` the kernelcache/SPTM disassembly helpers. |
| `docs/` | [`boot-and-recovery.md`](docs/boot-and-recovery.md) (rebuild, boot, provision, recover), [`smp-t6050-raw-path.md`](docs/smp-t6050-raw-path.md) (the SMP investigation), `docs/re/` (disassembly excerpts). |

## Rebuild m1n1

```bash
git -C ~/Work/m1n1 checkout -b m5-t6050 7cde7d1a && git -C ~/Work/m1n1 am ~/Work/m5pro-linux/patches/m1n1/*.patch
```

The result is byte-identical to the branch the Mac was booted with.

## Not in this repo, on purpose

- Apple boot objects (kernelcache, SPTM, TXM) and anything extracted from macOS.
- The Mac's ADT dump (`adt-runtime-j716s.bin`): it carries the serial number and MAC addresses.
- Disk images, the Arch/Alpine tarballs, initramfs and kernel builds.
- Keys and passwords.

## Credits

omarchy-m5 (betim-hodza) did the T6050 bring-up this builds on: the stub install scripts, the
J714s device trees, the kernel patches and the original m1n1 patches. m1n1 and linux-asahi are
the Asahi Linux project's work.
