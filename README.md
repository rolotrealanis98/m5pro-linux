# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-11-06)

Summary with test labels and repro steps: [`docs/status-2026-11-06.md`](docs/status-2026-11-06.md) (previous: [`2026-11-05`](docs/status-2026-11-05.md)).
Per-feature designs, patches and test plans: `contrib/pending/<feature>/`; hardware results: [`contrib/pending/integration/RESULTS.md`](contrib/pending/integration/RESULTS.md).

| Area | State |
|---|---|
| m1n1 installed as the stub's boot object (macOS on Macintosh HD stays at Full Security) | works |
| m1n1 proxy over USB-C to the Studio, through the CalDigit TS5 Plus | works |
| Chainloading m1n1 builds (`chainload.py -r -n`) | works |
| Linux 7.2 (asahi-wip-7.2 + omarchy-m5 patches), J716s device tree | boots untethered from the ESP, 18 CPUs; since 2026-11-06 evening the Linux side is reachable from the Studio over Tailscale and payloads are swapped from Linux |
| Aurora Silicon kernel (`integration/aurora`, Linux 7.3.0) on the J716s | **boots with USB3/Ethernet/trackpad, battery pending** (2026-11-07, round R3-R): NVMe root, 18 CPUs, cpuidle and schedutil cpufreq, SuperSpeed hub and RTL8153, keyboard, trackpad multi-touch (`Touch MT ready` at 1.7 s); battery (R3-S), Wi-Fi, display and GPU missing. The main stack above is unchanged. [`RESULTS.md`](contrib/pending/integration/RESULTS.md) ("Round R3"), [`contrib/pending/aurora/`](contrib/pending/aurora/) |
| Framebuffer console, built-in keyboard, NVMe read/write, USB gadget network | works |
| NVMe at boot | **works** (2026-11-05) with kernel patch 0016: the ANS firmware sometimes needs ~3 s for the RTKit handshake, the 1 s wait gave `ANS did not boot` and no root; 10 s wait, NVMe up at 8.3-10.7 s on 3/3 boots |
| Kernel built with LLVM/clang on the Studio's macOS | works (2026-11-05): 18 CPUs, SSH, trackpad |
| Arch Linux ARM root on the internal SSD (GPT entry 5 = `nvme0n1p5`) | works, systemd `running` |
| SMP (secondary cores) | **works, 18 cores** (2026-11-04): stub rebuilt on macOS 27.3 beta 1, whose stage-2 mBoot carries Apple's fix for raw boot objects on M5 Pro/Max/Ultra (release notes, mBoot > Resolved Issues). No m1n1 or kernel change needed; `maxcpus=1` dropped. Any stub must be built from macOS >= 27.3 beta 1. [`docs/smp-t6050-raw-path.md`](docs/smp-t6050-raw-path.md) |
| Trackpad | **works** (2026-11-05, 3/3 boots): the MTP firmware never drives the trackpad AFE reset; dockchannel-hid now drives it on SMC low GPIO `gp1c` (line 28, active-low), `Touch MT ready`, events flowing. [`contrib/pending/trackpad/`](contrib/pending/trackpad/) |
| iBoot boot-failure counter | **fixed, verified over four boots** (2026-11-05, kernel patch 0017): macsmc-reboot built in, poweroff-only, Abbey scratchpad cells. The first Linux reboot reported and cleared 1 boot error; the "B2" payload (old DTB, sha256 `55d95928...`) then survived three consecutive Linux (watchdog) reboots with zero PMU boot errors, NVMe and trackpad up and 18 CPUs each time. This was the cause of the "needs to be reinstalled" recovery after repeated Linux restarts. |
| Battery and charger (`macsmc-power`) | **works** (2026-11-06, 3/3 boots): the round-3 hang at ~7.8 s is gone with integration patches 0018-0027; status, capacity, voltage, current, charge, cycle count, temperature and MagSafe plug events read correctly. Which patch cured it is not known. [`RESULTS.md`](contrib/pending/integration/RESULTS.md) |
| Keyboard backlight, eDP connector | **work** (2026-11-06): `kbd_backlight` 0/32/255/0, `card0-eDP-1` connected. |
| Notch rows | **works** (2026-11-06 evening): the stage-2 m1n1 rebuild (patch 0017) keeps the rows behind the notch, `fb0` 3456x2234. |
| SMC core, cpufreq (all three clusters, schedutil default) | **work** (2026-11-06): hwmon, RTC, poweroff, low-GPIO; a loaded cluster reaches 4308000. The "idle stays high" reading was a measurement artifact (the read wakes the cluster; `time_in_state` shows the floor). Open: states above `cpuinfo_max_freq` in policy12's table. |
| USB host (left-front port), USB Ethernet | **works if plugged in before boot** (2026-11-06 evening): stage-2 m1n1 patch 0018 restores the USB-PD controller S0 setup (our 0005 had skipped it, so no VBUS). Hub chain, Logitech Bolt mouse, card reader and an RTL8153 (`r8152`, DHCP, ping) enumerate. No re-enumeration after an unplug: the kernel has no `tipd`/`cd321x` driver yet. `contrib/pending/usb/`, [`RESULTS.md`](contrib/pending/integration/RESULTS.md) ("Round R2") |
| Power off, S1 sleep step | **power off works** (`systemctl poweroff`, no PMU boot error next boot); **S1 freezer-only step passes**. Real s2idle not tested. |
| Thermal zones | design only, compile-checked (`contrib/pending/platform/`) |
| GPU, display driver (DCP), Wi-Fi/BT (N1), audio, camera, Thunderbolt | not working; design reports only (`contrib/pending/{gpu,dcp,wireless,audio,isp-tb}/`) |
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
| `docs/` | [`boot-and-recovery.md`](docs/boot-and-recovery.md) (rebuild, boot, provision, recover), [`smp-t6050-raw-path.md`](docs/smp-t6050-raw-path.md) (the SMP investigation), [`status-2026-11-06.md`](docs/status-2026-11-06.md) (status with test labels; the 2026-11-05 version is kept beside it), [`logs/`](docs/logs/) (redacted log excerpts). |

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

Reverse-engineering notes (disassembly excerpts of Apple binaries made while chasing SMP) are kept
outside this repository and are not published. Nothing in this tree is copied from them: the
register writes, ADT properties and SMC keys documented here come from hardware measurements, the
ADT and public sources. Earlier commits of this repository still contain a `docs/re/` folder with
those excerpts; if your project works clean-room, do not check out or read history before the
commit that removed it.

## Contributing / contact

Questions, reports and corrections: [issues on this repo](https://github.com/rolotrealanis98/m5pro-linux/issues).
The code, patches and reports here were produced with Claude (AI) under Rolando's direction; every
hardware result was run by him on the J716s. Asahi Linux does not accept AI-generated
contributions, so nothing here is offered to Asahi as code.

## Credits

omarchy-m5 (betim-hodza) did the T6050 bring-up this builds on: the stub install scripts, the
J714s device trees, the kernel patches and the original m1n1 patches. m1n1 and linux-asahi are
the Asahi Linux project's work.

## License

Kernel patches are GPL-2.0-only, m1n1 patches and everything else MIT; material taken from
omarchy-m5 and Asahi keeps its origin and terms. Details: [`LICENSE.md`](LICENSE.md).
