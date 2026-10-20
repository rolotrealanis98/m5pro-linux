# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-10-20)

| Area | State |
|---|---|
| m1n1 installed as the stub's boot object (macOS 27.2 stays at Full Security) | works |
| m1n1 proxy over USB-C to the Studio, through the CalDigit TS5 Plus | works |
| Chainloading m1n1 builds (`chainload.py -r -n`) | works |
| Linux 7.2 (asahi-wip-7.2 + omarchy-m5 patches), J716s device tree | boots, tethered |
| Framebuffer console, built-in keyboard, NVMe read/write, USB gadget network | works |
| Arch Linux ARM root on the internal SSD (GPT entry 5 = `nvme0n1p5`) | works, systemd `running` |
| SMP (secondary cores) | **not working**, `maxcpus=1`. Released cores power up but never fetch; PMGR side exhausted, macOS does the same writes. Known firmware issue (Gravity Linux: reported to Apple, waiting). Re-test after each macOS update. [`docs/smp-t6050-raw-path.md`](docs/smp-t6050-raw-path.md) |
| Trackpad (needs `tpmtfw-j716s.bin`), GPU, display driver, Wi-Fi/BT (N1), audio | not started |
| Untethered boot (kernel on the ESP) | not started |

## Layout

| Path | What |
|---|---|
| `patches/m1n1/` | `git format-patch` series on upstream m1n1 (see SOURCES.md). 0001-0007: omarchy-m5's T6050 patches, rebased (author kept). 0008-0012: written here. |
| `patches/omarchy-m5/` | Changes to the omarchy-m5 checkout: J716s board DT, measured PMGR boot state, `GCC=1` kernel builds; `0002` adds `finish-install.sh --macho`. |
| `dt/` | The J716s board DTS and its measured PMGR power-state table, also inside the patch above. |
| `host/` | Studio-side config: udev rules for the m1n1 device and the M5's USB network, the NAT script. |
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
