# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-11-07)

The daily kernel is **Aurora Silicon's `integration/aurora` (Linux 7.3.0) plus an 87-patch J716s series**, started by
the **N1-aware m1n1** (every payload has to carry it: a loader without it hangs once on a warm N1 and falls back). It
boots untethered from the ESP on all 18 CPUs with NVMe root and a Hyprland desktop, and it now has Wi-Fi, Bluetooth,
sound, sleep on lid close and GPU acceleration (the GPU still on a test payload that is being promoted). The older
asahi-wip 7.2 stack is kept as the fallback payload; everything it proved (SMP, boot chain, NVMe, trackpad, battery,
cpufreq) carried over.

Hardware results, round by round: [`contrib/validated/integration/RESULTS.md`](contrib/validated/integration/RESULTS.md).
Exact ingredients of the current payload: [`contrib/validated/aurora/STATE.md`](contrib/validated/aurora/STATE.md).
Last full write-up with test labels and repro steps: [`docs/status-2026-11-06.md`](docs/status-2026-11-06.md).
Evidence links name the `RESULTS.md` section by its heading (the timestamp part of the heading is left out of the
link text).

| Status | Area | State and evidence |
|---|---|---|
| **Works (daily)** | CPU, memory, NVMe | 18 CPUs, NVMe root, schedutil cpufreq on all three clusters, `apple_idle` cpuidle. The device tree is source-form, has no per-unit values, and builds with the kernel. [Result (DAILY 0087)](contrib/validated/integration/RESULTS.md#result-daily-0087-2026-11-07-1655-1701-utc-loop-nobody-at-the-machine) |
| **Works (daily)** | WFI idle | The cores really sleep: idle power on the charger 16.4 W to about 9.8 W, 56 min soak with no stall, Oops or SError, all 18 cores pass a floating-point check. m1n1 still appends `idle=nop`; series 0061 ignores it. [Result (WFI-T1)](contrib/validated/integration/RESULTS.md#result-wfi-t1-2026-11-07-1008-utc-self-revert-loop--ab-stage-1-nobody-at-the-machine), [Result (WFI soak + SLEEP S1-S4)](contrib/validated/integration/RESULTS.md#result-wfi-soak--sleep-s1-s4-2026-11-07-1026-1142-utc-wfi-t1-kernel-rolando-at-the-machine-for-s4), [`contrib/pending/wfi-idle/`](contrib/pending/wfi-idle/) |
| **Works (daily)** | Keyboard, keyboard backlight | Keyboard through dockchannel-hid; `kbd_backlight` LED 0/32/255/0 verified by eye and bound to the keyboard-light keys on the desktop. [R1-A: boot and desktop checks (payload 6d6a402b, battery driver off)](contrib/validated/integration/RESULTS.md#r1-a-boot-and-desktop-checks-payload-6d6a402b-battery-driver-off) |
| **Works (daily)** | Trackpad, haptics, presets | `Touch MT ready` on every boot (the host drives the AFE reset on SMC low GPIO `gp1c`); both MTP haptic devices present and the click gives feedback; three Hyprland presets (macOS, in between, libinput default) in [`contrib/validated/desktop/trackpad/`](contrib/validated/desktop/trackpad/HOWTO.md). [Result (NEXT-DAILY)](contrib/validated/integration/RESULTS.md#result-next-daily-2026-11-07-1614-1621-utc-rolando-watching-the-panel) |
| **Works (daily)** | Battery and charger (`macsmc-power`) | Status, capacity, voltage, current, charge, cycle count, temperature, charge behaviour, AC input power. Not exercised on this kernel: discharging and MagSafe unplug events. [Result (R3-S)](contrib/validated/integration/RESULTS.md#result-r3-s-2026-11-07-0917-utc-self-revert-loop--ab-stage-1-nobody-at-the-machine) |
| **Works (daily)** | Fans and sensors (`macsmc_hwmon`) | 60+ temperature channels, both fans (0 rpm when cool), power and current rails. Fan control is not available (the T6050 SMC has no `Ftst` unlock key). [Result (HWMON-T1)](contrib/validated/integration/RESULTS.md#result-hwmon-t1-2026-11-07-0949-utc-self-revert-loop--ab-stage-1-nobody-at-the-machine) |
| **Works (daily)** | USB3, both Type-C ports | Left-front: SuperSpeed hub, RTL8153 Ethernet, receiver dongle, card reader. Right: live plug test, hub at SuperSpeed Plus (10 Gb/s), keyboard, mouse, Ethernet. DisplayPort is not tested on either. [Result (RIGHTPORT plug test)](contrib/validated/integration/RESULTS.md#result-rightport-plug-test-2026-11-07-1050-utc-on-the-wfi-soak-boot-with-the-daily-dtb-rolando-moved-the-hub) |
| **Works (daily)** | Wi-Fi, Bluetooth controller (the N1) | The N1 trains behind m1n1 and is adopted by `pcie-apple`; `wlan0` associates (WPA2, 5 GHz) with `wpa_supplicant`, DHCP and traffic work, `hci0` is up. Three warm reboots with Wi-Fi in use come back, and the series strips ASPM on the adopted port, so no boot flag is needed (5 min soak, no freeze). `iwd` starts with the crypto options of series 0065. Open: 14 % ping loss seen once during the soak, 6 GHz (no entries in this regulatory list). The firmware is personalised per unit and is not published. [Result (W3b)](contrib/validated/integration/RESULTS.md#result-w3b-2026-11-07-1344-utc-cold-start-by-rolando-wi-fi-and-bluetooth-come-up), [Result (DAILY-WIFI-T1)](contrib/validated/integration/RESULTS.md#result-daily-wifi-t1-2026-11-07-1400-utc-loop-nobody-at-the-machine-associated-dhcp-lease-traffic), [Result (W4: restart with the N1 trained and in use)](contrib/validated/integration/RESULTS.md#result-w4-restart-with-the-n1-trained-and-in-use-2026-11-07-1537-1546-utc-loop-nobody-at-the-machine), [Result (NOASPMFLAG-T1 and BOARDV2-T1)](contrib/validated/integration/RESULTS.md#result-noaspmflag-t1-and-boardv2-t1-2026-11-07-1710-1721-utc-loop-nobody-at-the-machine) |
| **Works (daily)** | Speakers (TDM format), microphone | Speakers: the J716 link runs in the J616s TDM frame (series 0081), six amps, no faults at any level, a 1 kHz tone heard clean, PipeWire sink with the volume ceiling (-30 dB) and `speakersafetyd`. Microphone: three capsules, speech tracks the voice. [Result (R3-AUDIO-B6)](contrib/validated/integration/RESULTS.md#result-r3-audio-b6-2026-11-07-1420-utc-rolando-listening-the-speakers-play-clean), [Result (R3-AUDIO-A2 and R3-AUDIO-B2)](contrib/validated/integration/RESULTS.md#result-r3-audio-a2-and-r3-audio-b2-2026-11-07-0927-0945-utc-self-revert-loop--ab-stage-1-rolando-near-the-machine-for-the-sound) |
| **Works (daily)** | Headphone jack (wiring only) | `Headphone Jack` and `Headset Mic Jack` register as switches; nothing has been plugged in yet (see the attended list). [Result (R3-AUDIO-A2 and R3-AUDIO-B2)](contrib/validated/integration/RESULTS.md#result-r3-audio-a2-and-r3-audio-b2-2026-11-07-0927-0945-utc-self-revert-loop--ab-stage-1-rolando-near-the-machine-for-the-sound) |
| **Works (daily)** | Sleep: s2idle, lid close with Wi-Fi | Real s2idle with the power-button wake and the S1-S3 steps pass; lid close sleeps and lid open wakes, with Wi-Fi back after resume (two lid-close sleeps with the N1 adopted; series 0066 lid confirm and 0087 keep-the-link-up). The first Wi-Fi daily aborted lid sleep with `-EBUSY` from the adopted port; 0087 is that fix. [Result (WFI soak + SLEEP S1-S4)](contrib/validated/integration/RESULTS.md#result-wfi-soak--sleep-s1-s4-2026-11-07-1026-1142-utc-wfi-t1-kernel-rolando-at-the-machine-for-s4), [Result (N1-SLEEP)](contrib/validated/integration/RESULTS.md#result-n1-sleep-2026-11-07-1638-1643-utc-rolando-at-the-machine) |
| **Works (daily)** | Netfilter, WireGuard | nftables, policy routing, WireGuard, bridge/veth/overlay/fuse are built in (series 0064); `nft` and `ip rule` work. No tunnel test is recorded yet. [Result (LID daily promotion + bisect C and D)](contrib/validated/integration/RESULTS.md#result-lid-daily-promotion--bisect-c-and-d-2026-11-07-1440-1452-utc-loop-nobody-at-the-machine) |
| **Works (test payload, being promoted)** | GPU: Vulkan, zink GL, Hyprland on the GPU | The firmware boots and the `aurora` DRM driver binds; Vulkan (`Apple M5 Pro (G17S B1)`) passes compute, render, stress and vkmark; GL runs through zink on that Vulkan driver (Gallium's own M5 path declines G17S/G17C); a GPU-rendered frame reaches the panel; Hyprland renders on the GPU (`Renderer: zink`) and glmark2 runs clean for 25 min. Scanout stays on simpledrm (a CPU copy) until the display driver lands. [Result (GPU E2b)](contrib/validated/integration/RESULTS.md#result-gpu-e2b-2026-11-07-1842-1846-utc-loop-nobody-at-the-machine-the-gpu-firmware-boots), [Result (GPU first frame on zink + Hyprland on the GPU)](contrib/validated/integration/RESULTS.md#result-gpu-first-frame-on-zink--hyprland-on-the-gpu-2026-11-07-1957-2003-utc-loop-13-of-13-pass), [Result (GPU soak with Hyprland on the GPU)](contrib/validated/integration/RESULTS.md#result-gpu-soak-with-hyprland-on-the-gpu-2026-11-07-2004-2035-utc-loop) |
| **Works (daily)** | Desktop | Hyprland, Waybar, foot, Xwayland on stock Arch Linux ARM packages; `card0-eDP-1` with the notch rows; the GPU session is the default once the `aurora` card exists. |
| **Works (daily)** | Boot safety | Two-stage m1n1 with an A/B stage-1 (falls back to the previous payload after a failed boot, 150 s watchdog), a self-reverting test payload, a four-payload ESP policy. The fallback fired for real several times today, unattended. A freshly written payload file sometimes fails its first boot and boots on the retry (five times today); the ESP is now unmounted and remounted before the reboot. RAM-backed pstore is not viable (iBoot clears the region); crash evidence has to come from netconsole. [Observation: first boot of a new payload file fails once (4 of ~16 today)](contrib/validated/integration/RESULTS.md#observation-first-boot-of-a-new-payload-file-fails-once-4-of-16-today), [Result (CRASHLOG-PRAM)](contrib/validated/integration/RESULTS.md#result-crashlog-pram-2026-11-07-1548-1558-utc-loop-nobody-at-the-machine) |
| **Attended only, pending** | Speaker listening check | Heard clean on the test kernel; one more listen on the exact daily kernel (and one lid-close sleep on it) when Rolando is at the machine. [Result (DAILY 0087)](contrib/validated/integration/RESULTS.md#result-daily-0087-2026-11-07-1655-1701-utc-loop-nobody-at-the-machine) |
| **Attended only, pending** | Headphone jack test | Plug in headphones and a headset: output, jack detection, headset mic. |
| **Attended only, pending** | Bluetooth pairing | The controller scans (36 devices in 8 s); no device has been paired. [Result (W3b)](contrib/validated/integration/RESULTS.md#result-w3b-2026-11-07-1344-utc-cold-start-by-rolando-wi-fi-and-bluetooth-come-up) |
| **Attended only, pending** | Trackpad feel test | libinput palm and thumb handling on the J716s pad: the palm-class patch is a module parameter, untested. [`contrib/pending/platform/trackpad-feel/`](contrib/pending/platform/trackpad-feel/NOTES.md) |
| **Attended only, pending** | Display stage C (DCP takeover) | The loader hand-off (stages A, B0) and the 27.3 method-table kernel (stage B) pass; only the internal panel's `apple,bw-scratch` offset stands between this and taking the display over. No brightness control until then. [Result (DCP stages B0 and B)](contrib/validated/integration/RESULTS.md#result-dcp-stages-b0-and-b-2026-11-07-1850-1907-utc-loop-reruns-with-full-capture), [`contrib/pending/dcp/`](contrib/pending/dcp/) |
| **Attended only, pending** | 120 Hz and VRR | After stage C. |
| **Prepared, not booted** | Thunderbolt/USB4 | Device tree, kernel and m1n1 patches on top of Aurora's #946 base; compile and `dtbs_check` only. [`contrib/pending/thunderbolt/`](contrib/pending/thunderbolt/) |
| **Prepared, not booted** | Camera | ISP patches, DT and a staged test plan; nothing has run on the machine. [`contrib/pending/camera/`](contrib/pending/camera/TEST-PLAN.md) |
| **Prepared, not booted** | Video decode | AVD and JPEG engine patches and DT nodes. [`contrib/pending/video/`](contrib/pending/video/) |
| **Prepared, not booted** | ANE observer | Kernel and m1n1 patches that bind the Neural Engine for observation only. [`contrib/pending/ane/`](contrib/pending/ane/) |
| **Prepared, not booted** | External displays | Needs the display driver (stage C) first; DisplayPort over Type-C is untested on both ports. |
| **Prepared, not booted** | Thermal zones | Design report only. [`contrib/pending/platform/`](contrib/pending/platform/) |
| **Not realistic** | Touch ID | Sits behind the Secure Enclave; not planned. |
| **Not realistic** | ProRes | Only a device-tree binding exists, no driver. |
| **Not realistic** | Hardware video encode, for now | The encoder has a probe-only driver; nothing beyond that is expected soon. |

Open PRs: `aurora-silicon/linux` **#1082** (rtkit handshake wait 1 s to 10 s), **#1083** (dockchannel-hid 50 ms settle
after the AFE reset), **#1084** (macsmc hwmon keeps a fan whose optional keys are missing), **#1152** (T6050 idles in WFI
even with `idle=nop`), **#1160** (macsmc-input confirms a lid-open report during sleep), **#1167** (the J716s board device
tree), **#1173** (M5 GPU InitData for the 27.2 and 27.3 firmware), **#1174** (display driver: 27.3 method table and swap
layout); `aurora-silicon/m1n1` **#65** (train the N1 link and fill its hand-off). Held: CIO reset (#946 replaces it),
cpufreq binding (#481), SMC match (#941). [`contrib/validated/aurora/prs/`](contrib/validated/aurora/prs/)

## Quick start: build and install a payload

The payload is one file: m1n1 (0x400000 bytes) | boot arguments | `Image.gz` | device tree | initramfs.
[`mk-daily.py`](contrib/validated/aurora/tools/mk-daily.py) builds it from named, hash-pinned ingredients and
prints the commands for the swap; it never touches the machine. What may sit on the ESP, and how a failed test
returns to the last good payload, is in [`ESP-POLICY.md`](contrib/validated/aurora/tools/ESP-POLICY.md): read it first.

```bash
# 1. kernel: a worktree of aurora-silicon/linux at 33bec4016c46 + the series, then build it (recipe: series/SERIES.md)
git am contrib/validated/aurora/series/patches/*.patch
make LLVM=1 ARCH=arm64 defconfig asahi.config j716s.config && make LLVM=1 ARCH=arm64 -j Image.gz dtbs

# 2. check the ingredients, then build a test payload (it reverts itself if the network does not come up)
python3 -I contrib/validated/aurora/tools/mk-daily.py --list      # edit INGREDIENTS (paths, pins) for your machine first
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --label my-test

# 3. print the ESP swap, read it, run it yourself; boot the test with the Ethernet adapter attached
python3 -I contrib/validated/aurora/tools/mk-daily.py --deploy-plan --payload DIR/my-test-<date>-<hash>.bin --host root@<linux-ip>

# 4. once it reached the network, rebuild the same ingredients as the daily (no self-revert, battery on)
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --daily --battery --force
```

The stage-2 m1n1 of the daily is upstream plus `patches/m1n1/` and the N1 patches of `contrib/pending/wireless/patches/m1n1/` (0022, 0023, 0025-0027; a payload without them hangs once on a warm N1) (toolchain and recipe: [`m1n1-BUILD.md`](contrib/validated/integration/m1n1-BUILD.md)):

```bash
git -C ~/Work/m1n1 checkout -b m5-t6050 7cde7d1a && git -C ~/Work/m1n1 am ~/Work/m5pro-linux/patches/m1n1/*.patch
```

The stage-1 A/B patch is separate (`patches/m1n1-stage1/`): it only belongs in a CHAINLOADING build.

## Layout

| Path | What |
|---|---|
| `patches/m1n1/` | `git format-patch` series on upstream m1n1 (see SOURCES.md), the stage-2 build of the daily. 0001-0007: omarchy-m5's T6050 patches, rebased (author kept). 0008-0015: written here (0013-0015: chainload and SMP for a stage 2 on the ESP). 0017, 0018, 0020, 0021: notch rows, USB-PD controllers into S0, PIPE park, and the combo-PHY tunables produced from the ADT at boot, so the device tree carries no per-unit values. |
| `patches/m1n1-stage1/` | 0016: the A/B fallback and watchdog of the CHAINLOADING stage 1. |
| `patches/omarchy-m5/` | Changes to the omarchy-m5 checkout (the 7.2 stack): J716s board DT, measured PMGR boot state, `GCC=1` builds, `finish-install.sh --macho`. |
| `contrib/validated/aurora/` | The Aurora kernel work that has run on the machine: `series/` (the 87 patches and the rebuild recipe), `tools/` (`mk-daily.py`, `ESP-POLICY.md`), `atc-tunables/`, `pipe-park/`, `trackpad/`, `prs/` (upstream PRs), `STATE.md`. |
| `contrib/validated/integration/` | Hardware results (`RESULTS.md`), test kits and the patch set of the 7.2 stack. |
| `contrib/validated/desktop/`, `contrib/validated/legacy-7.2/` | Desktop setup; trackpad, SMC, cpufreq and USB-host work that ran on the 7.2 stack (what the fallback payload is made of). |
| `contrib/pending/` | Test-payload work, prepared work and design reports: `audio` (with the Aurora audio kernel patches), `dcp`, `gpu`, `wireless` (with the N1 patches), `wfi-idle`, `platform`, `thunderbolt`, `camera`, `video`, `ane`, `crashlog`, `followups`, `boot-ab`, `dt-prep`, `isp-tb`. |
| `contrib/distro/` | Design and prototypes for an installable distribution; not run on the machine. |
| `dt/` | The 7.2-stack J716s board DTS and its measured PMGR power-state table. |
| `host/macos/`, `host/`, `scripts/` | Studio-side tether and deploy helpers (macOS and Omarchy), udev rules, the NAT script, m1n1 proxy helpers. |
| `docs/` | Boot and recovery, the SMP investigation, status snapshots, redacted log excerpts, the plan. |

## Not in this repo, on purpose

- Apple boot objects (kernelcache, SPTM, TXM), firmware, and anything extracted from macOS.
- The Mac's ADT dump: it carries the serial number and MAC addresses.
- Per-unit firmware (the Wi-Fi/Bluetooth image) and per-unit device-tree values.
- Disk images, root tarballs, initramfs and kernel builds, payloads.
- Keys and passwords.

Reverse-engineering notes (disassembly excerpts of Apple binaries made while chasing SMP) are kept
outside this repository and are not published. Nothing in this tree is copied from them: the
register writes, ADT properties and SMC keys documented here come from hardware measurements, the
ADT and public sources. Earlier commits of this repository still contain a `docs/re/` folder with
those excerpts; if your project works clean-room, do not check out or read history before the
commit that removed it.

## Contributing / contact

Questions, reports and corrections: [issues on this repo](https://github.com/rolotrealanis98/m5pro-linux/issues).
Fixes that belong upstream go to `aurora-silicon/linux` as small PRs (see
[`UPSTREAM-NOTES.md`](contrib/validated/aurora/series/UPSTREAM-NOTES.md)).

## Credits

omarchy-m5 (betim-hodza) did the T6050 bring-up this builds on: the stub install scripts, the
J714s device trees, the kernel patches and the original m1n1 patches. The Aurora Silicon project
(aurora-silicon/linux; Jeff Queisser, Erik Bourget, Dj and others) carries the T6050 kernel work the
daily is based on: the series carries their commits with authors kept; the AOP audio port is
edimoldovan's. m1n1 and linux-asahi are the Asahi Linux project's work.

## License

Kernel patches are GPL-2.0-only, m1n1 patches and everything else MIT; material taken from
omarchy-m5, Aurora and Asahi keeps its origin and terms. Details: [`LICENSE.md`](LICENSE.md).
