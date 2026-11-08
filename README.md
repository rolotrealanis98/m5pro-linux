# m5pro-linux

Personal bring-up of Linux (Arch, aiming at Omarchy) on a **16-inch MacBook Pro M5 Pro**
(Mac17,8, board J716s, SoC T6050, 48 GiB), with the Mac Studio M2 Ultra running Omarchy
as the build and USB host. Started 2026-10-20.

This repo holds only what was made or changed here. Upstream sources are pinned in
[`SOURCES.md`](SOURCES.md), not vendored.

## Status (2026-11-08)

The daily is **`daily-n1k-20261107-512a1c00.bin`**: kernel **7.3.0-g36845aa5f650** = the GPU tree (Aurora Silicon's
`integration/aurora`, our 87-patch J716s series, Aurora #1012 and the 27.2+ GPU port) + the kernel-side N1 training
(wireless 0004-0010) + the F6 key fix + the read-only NVRAM nodes. Its loader is m1n1 `n1-dt-gpu`: it does **not**
train the N1 (the kernel does), keeps the port enabled and copies the host tunables, and no `n1` variable is set.
It boots untethered from the ESP on all 18 CPUs with NVMe root and a Hyprland desktop, and has Wi-Fi, Bluetooth,
sound, sleep on lid close and GPU acceleration. The GPU (`aurora` driver, 27.3 firmware, G17S) is up on every daily
boot, and the desktop starts the zink GPU session by itself (Omarchy 4.5 is installed on the root). Rollback is the
test twin, `daily-n1k-test-20261107-5c74c66c.bin`, on the previous slot. The asahi-wip 7.2 stack that came first proved
SMP, the boot chain, NVMe, trackpad, battery and cpufreq, and all of it carried over
([`contrib/validated/legacy-7.2/`](contrib/validated/legacy-7.2/)).

Hardware results, round by round: [`contrib/validated/integration/RESULTS.md`](contrib/validated/integration/RESULTS.md).
Exact ingredients of the current payload: [`contrib/validated/aurora/STATE.md`](contrib/validated/aurora/STATE.md).
Last full write-up with test labels and repro steps: [`docs/status-2026-11-06.md`](docs/status-2026-11-06.md) (a
dated snapshot; this section and `RESULTS.md` are newer).
Evidence links name the `RESULTS.md` section by its heading (the timestamp part of the heading is left out of the
link text).

| Status | Area | State and evidence |
|---|---|---|
| **Works (daily)** | CPU, memory, NVMe | 18 CPUs, NVMe root, schedutil cpufreq on all three clusters, `apple_idle` cpuidle. The device tree is source-form, has no per-unit values, and builds with the kernel. The current daily booted first pass at 79 s with 0 faults. [DAILY-N1K: next daily promoted, the kernel trains the Wi-Fi port](contrib/validated/integration/RESULTS.md#daily-n1k-next-daily-promoted-the-kernel-trains-the-wi-fi-port-2026-11-07-2316-utc--pass), [Result (DAILY 0087)](contrib/validated/integration/RESULTS.md#result-daily-0087-2026-11-07-1655-1701-utc-loop-nobody-at-the-machine) |
| **Works (daily)** | WFI idle | The cores really sleep: idle power on the charger 16.4 W to about 9.8 W, 56 min soak with no stall, Oops or SError, all 18 cores pass a floating-point check. m1n1 still appends `idle=nop`; series 0061 ignores it. [Result (WFI-T1)](contrib/validated/integration/RESULTS.md#result-wfi-t1-2026-11-07-1008-utc-self-revert-loop--ab-stage-1-nobody-at-the-machine), [Result (WFI soak + SLEEP S1-S4)](contrib/validated/integration/RESULTS.md#result-wfi-soak--sleep-s1-s4-2026-11-07-1026-1142-utc-wfi-t1-kernel-rolando-at-the-machine-for-s4), [`contrib/pending/wfi-idle/`](contrib/pending/wfi-idle/) |
| **Works (daily)** | Keyboard, keyboard backlight | Keyboard through dockchannel-hid; `kbd_backlight` LED 0/32/255/0 verified by eye and bound to the keyboard-light keys on the desktop. F6 is mapped to Do Not Disturb (peripherals 0007, in the daily; not yet checked with the key). [R1-A: boot and desktop checks (payload 6d6a402b, battery driver off)](contrib/validated/integration/RESULTS.md#r1-a-boot-and-desktop-checks-payload-6d6a402b-battery-driver-off), [DAILY-N1K](contrib/validated/integration/RESULTS.md#daily-n1k-next-daily-promoted-the-kernel-trains-the-wi-fi-port-2026-11-07-2316-utc--pass) |
| **Works (daily)** | Trackpad, haptics, presets | `Touch MT ready` on every boot (the host drives the AFE reset on SMC low GPIO `gp1c`); both MTP haptic devices present and the click gives feedback; three Hyprland presets (macOS, in between, libinput default) in [`contrib/validated/desktop/trackpad/`](contrib/validated/desktop/trackpad/HOWTO.md). [Result (NEXT-DAILY)](contrib/validated/integration/RESULTS.md#result-next-daily-2026-11-07-1614-1621-utc-rolando-watching-the-panel) |
| **Works (daily)** | Battery and charger (`macsmc-power`) | Status, capacity, voltage, current, charge, cycle count, temperature, charge behaviour, AC input power. Not exercised on this kernel: discharging and MagSafe unplug events. [Result (R3-S)](contrib/validated/integration/RESULTS.md#result-r3-s-2026-11-07-0917-utc-self-revert-loop--ab-stage-1-nobody-at-the-machine) |
| **Works (daily)** | Fans and sensors (`macsmc_hwmon`) | 60+ temperature channels, both fans (0 rpm when cool), power and current rails. Fan control is not available (the T6050 SMC has no `Ftst` unlock key). [Result (HWMON-T1)](contrib/validated/integration/RESULTS.md#result-hwmon-t1-2026-11-07-0949-utc-self-revert-loop--ab-stage-1-nobody-at-the-machine) |
| **Works (daily)** | USB3, both Type-C ports | Left-front: SuperSpeed hub, RTL8153 Ethernet, receiver dongle, card reader. Right: live plug test, hub at SuperSpeed Plus (10 Gb/s), keyboard, mouse, Ethernet. DisplayPort is not tested on either. [Result (RIGHTPORT plug test)](contrib/validated/integration/RESULTS.md#result-rightport-plug-test-2026-11-07-1050-utc-on-the-wfi-soak-boot-with-the-daily-dtb-rolando-moved-the-hub) |
| **Works (daily)** | Wi-Fi, Bluetooth controller (the N1) | **The kernel trains the N1 itself** (K1 and K2 PASS): the loader leaves the port down but enabled with the host tunables copied (m1n1 0022 + 0028, no training), and `pcie-apple` trains it (`port 0: trained by Linux, the boot loader left it down`; cold train, host tunables, DART availability, a 250 ms warm-N1 power reset, the J716s gP13 template and the DT, wireless 0004-0010). All three functions enumerate, `wlan0` associates (WPA2, 5 GHz) with `wpa_supplicant`, DHCP and traffic work, `hci0` is up. A warm restart with Wi-Fi in use comes back (the kernel trains it again), and a port a loader trained is still adopted (K2). The series strips ASPM on the adopted port, so no boot flag is needed. `iwd` starts with the crypto options of series 0065. Open: 14 % ping loss seen once during an earlier soak, 6 GHz (no entries in this regulatory list). The firmware is personalised per unit and is not published. Upstream: `aurora-silicon/linux` #1182 (driver half, on #937's branch) and #1183 (DT half, on #1167). [K1/K2: the kernel trains the N1 port itself](contrib/validated/integration/RESULTS.md#k1k2-the-kernel-trains-the-n1-port-itself-2026-11-07-2127-utc--pass), [DAILY-N1K](contrib/validated/integration/RESULTS.md#daily-n1k-next-daily-promoted-the-kernel-trains-the-wi-fi-port-2026-11-07-2316-utc--pass), [Result (W3b)](contrib/validated/integration/RESULTS.md#result-w3b-2026-11-07-1344-utc-cold-start-by-rolando-wi-fi-and-bluetooth-come-up), [Result (DAILY-WIFI-T1)](contrib/validated/integration/RESULTS.md#result-daily-wifi-t1-2026-11-07-1400-utc-loop-nobody-at-the-machine-associated-dhcp-lease-traffic), [Result (W4: restart with the N1 trained and in use)](contrib/validated/integration/RESULTS.md#result-w4-restart-with-the-n1-trained-and-in-use-2026-11-07-1537-1546-utc-loop-nobody-at-the-machine) |
| **Works (daily)** | Speakers (TDM format), microphone | Speakers: the J716 link runs in the J616s TDM frame (series 0081), six amps, no faults at any level, a 1 kHz tone heard clean, PipeWire sink with the volume ceiling (-30 dB) and `speakersafetyd`. Microphone: three capsules, speech tracks the voice. [Result (R3-AUDIO-B6)](contrib/validated/integration/RESULTS.md#result-r3-audio-b6-2026-11-07-1420-utc-rolando-listening-the-speakers-play-clean), [Result (R3-AUDIO-A2 and R3-AUDIO-B2)](contrib/validated/integration/RESULTS.md#result-r3-audio-a2-and-r3-audio-b2-2026-11-07-0927-0945-utc-self-revert-loop--ab-stage-1-rolando-near-the-machine-for-the-sound) |
| **Works (daily)** | Headphone jack (wiring only) | `Headphone Jack` and `Headset Mic Jack` register as switches; nothing has been plugged in yet (see the attended list). [Result (R3-AUDIO-A2 and R3-AUDIO-B2)](contrib/validated/integration/RESULTS.md#result-r3-audio-a2-and-r3-audio-b2-2026-11-07-0927-0945-utc-self-revert-loop--ab-stage-1-rolando-near-the-machine-for-the-sound) |
| **Works (daily)** | Sleep: s2idle, lid close with Wi-Fi | Real s2idle with the power-button wake and the S1-S3 steps pass; lid close sleeps and lid open wakes, with Wi-Fi back after resume (two lid-close sleeps with the N1 adopted; series 0066 lid confirm and 0087 keep-the-link-up). The first Wi-Fi daily aborted lid sleep with `-EBUSY` from the adopted port; 0087 is that fix. Not yet re-run on the kernel-trained N1 of the current daily. [Result (WFI soak + SLEEP S1-S4)](contrib/validated/integration/RESULTS.md#result-wfi-soak--sleep-s1-s4-2026-11-07-1026-1142-utc-wfi-t1-kernel-rolando-at-the-machine-for-s4), [Result (N1-SLEEP)](contrib/validated/integration/RESULTS.md#result-n1-sleep-2026-11-07-1638-1643-utc-rolando-at-the-machine) |
| **Works (daily)** | Netfilter, WireGuard | nftables, policy routing, WireGuard, bridge/veth/overlay/fuse are built in (series 0064); `nft` and `ip rule` work. No tunnel test is recorded yet. [Result (LID daily promotion + bisect C and D)](contrib/validated/integration/RESULTS.md#result-lid-daily-promotion--bisect-c-and-d-2026-11-07-1440-1452-utc-loop-nobody-at-the-machine) |
| **Works (daily)** | GPU: Vulkan, zink GL, Hyprland on the GPU | The firmware boots on every daily boot (`GPU firmware: 27.3 (26C5035r), G17S`, `[drm] Initialized aurora`, `renderD128`); Vulkan (`Apple M5 Pro (G17S B1)`) passes compute, render, stress and vkmark; GL runs through zink on that Vulkan driver; a GPU-rendered frame reaches the panel; Hyprland renders on the GPU (`Renderer: zink`) and glmark2 ran clean for 25 min with 0 GPU kernel errors. `hypr-session` starts the GPU session by itself when the `aurora` card and `/opt/mesa-aurora` exist (software session otherwise, or with `/etc/hypr-gpu-disable`; a GPU session that dies within 30 s is replaced by the software one). Scanout stays on simpledrm (a CPU copy) in the daily until the display driver is in it. Upstream: `aurora-silicon/linux` #1173. [Result (GPU E2b)](contrib/validated/integration/RESULTS.md#result-gpu-e2b-2026-11-07-1842-1846-utc-loop-nobody-at-the-machine-the-gpu-firmware-boots), [Result (GPU first frame on zink + Hyprland on the GPU)](contrib/validated/integration/RESULTS.md#result-gpu-first-frame-on-zink--hyprland-on-the-gpu-2026-11-07-1957-2003-utc-loop-13-of-13-pass), [Result (GPU soak with Hyprland on the GPU)](contrib/validated/integration/RESULTS.md#result-gpu-soak-with-hyprland-on-the-gpu-2026-11-07-2004-2035-utc-loop), [GPU DAILY promotion](contrib/validated/integration/RESULTS.md#gpu-daily-promotion-2026-11-07-2035-utc) |
| **Works (daily)** | Desktop | Hyprland (Lua config) on Omarchy 4.5.0 from the official aarch64 packages, installed on the root (the old Waybar desktop is kept as a fallback, `m5pro-desktop lite`). `getty@tty2` autologin is enabled and the VT is switched to tty2 before Hyprland starts (otherwise Hyprland crashed waiting for an inactive session and the panel sat at the tty1 login); the Quickshell wallpaper needed `qt6-imageformats` (webp). `card0-eDP-1` with the notch rows; the GPU session is the default. [`contrib/validated/desktop/omarchy-upgrade-REPORT.md`](contrib/validated/desktop/omarchy-upgrade-REPORT.md), [GPU DAILY promotion](contrib/validated/integration/RESULTS.md#gpu-daily-promotion-2026-11-07-2035-utc) |
| **Works (daily, read-only)** | NVRAM (boot NOR) | The qspi controller and `flash@0` are in the daily's device tree: `spi-nor` probes, `mtd2` = `nvram` (768 KiB) reads back fully from `/dev/mtd2ro`; parsed read-only (12 banks, 217 entries, names match what macOS shows). No write has been done; the dump stays on the machine. [NVRAM-RO: boot NOR and NVRAM partition visible from Linux](contrib/validated/integration/RESULTS.md#nvram-ro-boot-nor-and-nvram-partition-visible-from-linux-2026-11-07-2047-utc), [DAILY-N1K](contrib/validated/integration/RESULTS.md#daily-n1k-next-daily-promoted-the-kernel-trains-the-wi-fi-port-2026-11-07-2316-utc--pass) |
| **Works (daily)** | Boot safety | Two-stage m1n1 with an A/B stage-1 (falls back to the previous payload after a failed boot, 150 s watchdog), a self-reverting test payload, a four-payload ESP policy. **Cause of the old "first boot of a fresh payload falls back"**: a reboot while the SSD is still busy after a write burst (an ext4 burst reproduces it with no ESP write); it shows up as a counted restart or a panic in the next boot's first seconds. **Rule: 60 s of idle after any large write** (`esp-put.sh` defaults to `ESP_SETTLE=60`; 9 of 9 clean with the settle, 5 of 14 failed with a ~1 s gap). A shutdown settle hook (`sync`, 20 s) is installed on the root; stage-1 0017 (stage marks, a counted restart boots the primary) is recommended and waits for an attended sitting. RAM-backed pstore is not viable (iBoot clears the region); crash evidence has to come from netconsole. Details: [`contrib/pending/boot-ab/firstboot/REPORT.md`](contrib/pending/boot-ab/firstboot/REPORT.md). [First-boot fallback root cause](contrib/validated/integration/RESULTS.md#first-boot-fallback-root-cause-2026-11-07-analysis-of-todays-logs), [RESTART-EXP4: a disk write burst right before the reboot reproduces the failure without any ESP write](contrib/validated/integration/RESULTS.md#restart-exp4-a-disk-write-burst-right-before-the-reboot-reproduces-the-failure-without-any-esp-write-2026-11-07-2337-utc), [Result (CRASHLOG-PRAM)](contrib/validated/integration/RESULTS.md#result-crashlog-pram-2026-11-07-1548-1558-utc-loop-nobody-at-the-machine) |
| **Works (test payload)** | Power: cpufreq profile, PMC observe | T1 PASS on retest: `apple-cpufreq` on all three policies (max 4308/4308/4608 MHz, boost listed on the M clusters, off), the PMC driver in observe mode (nothing written), the CLPC computes its votes under load (every vote refused in observe mode). The first T1 failure was the early-panic case after an omacom-loader session, not the power patches. Idle 10.4 W on the charger (the daily 9.0 W in an earlier, shorter sample). T3 (the first PMC write) stays attended. [POWER-T1 retest: the power kernel boots and observes](contrib/validated/integration/RESULTS.md#power-t1-retest-the-power-kernel-boots-and-observes-2026-11-07-2212-utc--pass), [POWER-T1 baseline](contrib/validated/integration/RESULTS.md#power-t1-baseline-2026-11-07-2251-utc), [POWER-T1: the power kernel resets within a minute](contrib/validated/integration/RESULTS.md#power-t1-the-power-kernel-resets-within-a-minute-2026-11-07-2122-utc--fail), [`contrib/pending/power/`](contrib/pending/power/REPORT.md) |
| **Works (test payload)** | Display: DCP drives the panel (stage C), 120 Hz | Stage C PASS, unattended: the DCP drives the internal panel on the 27.3 firmware. simpledrm is replaced by `apple-drm` and `card1-eDP-2` (3456x2234, connected and enabled), fbcon moved onto it, no DCP crash, `swap failed` or timeout lines. The firmware offers six native timings (120 Hz preferred, 60, 59.94, 50, 48, 47.95); 120 Hz is adopted at boot (the timing iBoot left running). `vrr_capable` is 0 by default and 1 with the opt-in `appledrm.fw27_panel_vrr=1`; swap cadence and VRR are still unmeasured. The DT display clock (`clk_disp0`, 712 MHz on the dcp node) silences the firmware's clock complaints. The DCP-120 series showed a counter-timestamp stall (the first swap after the boot mode set never completes, then every commit is refused); it is fixed in the 120 Hz v2 series (constant swap deadline, [`contrib/pending/dcp/promotion/`](contrib/pending/dcp/promotion/)), not booted yet. Brightness writes are accepted but do not reach the panel yet (`actual_brightness` stays 300). **The DCP is not in the daily yet; that build is in progress.** [DISPLAY STAGE C: the DCP drives the internal panel](contrib/validated/integration/RESULTS.md#display-stage-c-the-dcp-drives-the-internal-panel-2026-11-07-2135-utc--pass-unattended-remote-checks), [Stage C corrections after the journal analysis](contrib/validated/integration/RESULTS.md#stage-c-corrections-after-the-journal-analysis-contribvalidateddisplaystage-c-analysismd), [DCP-120 series: 120 Hz and VRR measurements](contrib/validated/integration/RESULTS.md#dcp-120-series-120-hz-and-vrr-measurements-2026-11-07-2259-utc--mode-list-confirmed-cadence-still-unmeasured), [DCP-120 series: why the measurements failed](contrib/validated/integration/RESULTS.md#dcp-120-series-why-the-measurements-failed-journal-analysis-2026-11-07-2330-utc), [`contrib/pending/dcp/`](contrib/pending/dcp/) |
| **Works (test tree)** | Native OpenGL (Gallium) on the G17S | The Gallium path for the G17S passes 12 of 12 scenes (triangle, depth, texture, MRT, MSAA, compute, geometry shader, mipmaps and more), the GBM scanout test and the OpenGL benchmark on the machine (GL 4.6 core, no GPU errors; five Mesa patches). The session still runs on zink; the session switch is pending. The first run was 11 of 12 with the scanout and GL-version failures; those are fixed in patches 0004 and 0005 and the timer-query change. [GL-NATIVE A/B: the native Gallium driver runs on the G17S](contrib/validated/integration/RESULTS.md#gl-native-ab-the-native-gallium-driver-runs-on-the-g17s-2026-11-07-2218-utc--partial), [`contrib/pending/gpu/gl-native/REPORT.md`](contrib/pending/gpu/gl-native/REPORT.md#update-2026-11-07-2250-utc-all-three-hardware-failures-fixed-verified-on-the-machine) |
| **Works (test payload)** | Camera: ISP DARTs and power domains | I1 PASS: the three ISP DARTs bind to `apple-dart`, 8 of 8 ISP power domains are present (`isp_be` and `isp_fe` on), `apple_isp` stays unloaded, no faults. I2 (firmware handshake, `/dev/video0`) is not run: the segment pre-check could not confirm the ISP firmware ranges on the running daily and the ISP kernel patches are still being built. [CAMERA I1: ISP DARTs and power domains](contrib/validated/integration/RESULTS.md#camera-i1-isp-darts-and-power-domains-2026-11-07-2140-utc--pass), [`contrib/pending/camera/`](contrib/pending/camera/TEST-PLAN.md) |
| **Attended only, pending** | Speaker profile and listening check | A J716s speaker profile is built and checked offline (Apple's speaker tuning for the J716s is byte-identical to the J616s one, so the J616s graph is the base, with the volume graph capped at -10 dB and the kernel -30 dB ceiling kept); staged, not active. Needs a listening test with the staged signals, and one more listen and lid-close sleep on the exact daily kernel. [`contrib/validated/desktop/audio/j716-profile/REPORT.md`](contrib/validated/desktop/audio/j716-profile/REPORT.md), [Result (R3-AUDIO-B6)](contrib/validated/integration/RESULTS.md#result-r3-audio-b6-2026-11-07-1420-utc-rolando-listening-the-speakers-play-clean) |
| **Attended only, pending** | Omarchy boot chain (B1) | Our A/B stage 1 -> m1n1 -> U-Boot -> Limine -> the daily kernel as an EFI-stub image, built, not booted: needs a cold start (a warm restart is not enough) and has only the 150 s stage-1 watchdog as fallback. [`contrib/pending/installer/omarchy-chain/REPORT.md`](contrib/pending/installer/omarchy-chain/REPORT.md) |
| **Attended only, pending** | Headphone jack test | Plug in headphones and a headset: output, jack detection, headset mic. |
| **Attended only, pending** | Bluetooth pairing | The controller scans (36 devices in 8 s); no device has been paired. [Result (W3b)](contrib/validated/integration/RESULTS.md#result-w3b-2026-11-07-1344-utc-cold-start-by-rolando-wi-fi-and-bluetooth-come-up) |
| **Attended only, pending** | Trackpad feel test | libinput palm and thumb handling on the J716s pad: the palm-class patch is a module parameter, untested. [`contrib/pending/platform/trackpad-feel/`](contrib/pending/platform/trackpad-feel/NOTES.md) |
| **Attended only, pending** | Brightness, swap cadence, VRR | Brightness writes and a measured flip cadence (120 Hz, VRR on and off) once the DCP is in a booted payload; the atomic test program `vrrflip` is in [`contrib/pending/dcp/vrr/tools/`](contrib/pending/dcp/vrr/tools/). [DCP-120 series: why the measurements failed](contrib/validated/integration/RESULTS.md#dcp-120-series-why-the-measurements-failed-journal-analysis-2026-11-07-2330-utc) |
| **Attended only (T0 hung)** | Thunderbolt/USB4 | Device tree, kernel and m1n1 patches on top of Aurora's #946 base. The T0 boot hung in kernel init (`swapper/0` blocked in `deferred_probe_initcall` -> `flush_work`, over 1000 s), so userspace, the self-test and the fallback never ran and the machine needed a power cycle. Attended only now; it needs a probe timeout and a watchdog that only Linux's init completion pets before another loop attempt. [TB-T0: Thunderbolt kernel boot lost the machine](contrib/validated/integration/RESULTS.md#tb-t0-thunderbolt-kernel-boot-lost-the-machine-2026-11-08-0002-utc--open-needs-hands), [`contrib/pending/thunderbolt/`](contrib/pending/thunderbolt/) |
| **Prepared, not booted** | Video decode | AVD and JPEG engine patches and DT nodes. [`contrib/pending/video/`](contrib/pending/video/) |
| **Prepared, not booted** | ANE observer | Kernel and m1n1 patches that bind the Neural Engine for observation only. [`contrib/pending/ane/`](contrib/pending/ane/) |
| **Prepared, not booted** | External displays | Needs the DCP in a daily payload first (stage C passes on the internal panel); DisplayPort over Type-C is untested on both ports. |
| **Prepared, not booted** | Thermal zones | Design report only. [`contrib/pending/platform/`](contrib/pending/platform/) |
| **Not realistic** | Touch ID | Sits behind the Secure Enclave; not planned. |
| **Not realistic** | ProRes | Only a device-tree binding exists, no driver. |
| **Not realistic** | Hardware video encode, for now | The encoder has a probe-only driver; nothing beyond that is expected soon. |

Open PRs: `aurora-silicon/linux` **#1082** (rtkit handshake wait 1 s to 10 s), **#1083** (dockchannel-hid 50 ms settle
after the AFE reset), **#1084** (macsmc hwmon keeps a fan whose optional keys are missing), **#1152** (T6050 idles in WFI
even with `idle=nop`), **#1160** (macsmc-input confirms a lid-open report during sleep), **#1167** (the J716s board device
tree), **#1173** (M5 GPU InitData for the 27.2 and 27.3 firmware), **#1174** (display driver: 27.3 method table and swap
layout), **#1182** (kernel-side N1 training, driver half, on #937's branch), **#1183** (kernel-side N1 training, DT half,
on #1167); `aurora-silicon/m1n1` **#65** (train the N1 link and fill its hand-off). For the Omarchy project (`omacom`):
`omarchy-mac-pkgs` **#103** (J716s in the audio tests and the manual) and `m1n1` **#33** (T6050 bring-up), **#34** (N1
training and hand-off), **#37** (GPU hand-off), **#35** (internal display hand-off), **#36** (`m1n1.wdt=keep`), stacked on
#30; the stacks based on #26 and on #30 both booted the J716s and the review fixes are in; the `linux-aurora` J716s PR is
being opened from a fresh fork. Held: CIO reset (#946 replaces it), cpufreq binding (#481), SMC match (#941).
[`contrib/validated/aurora/prs/`](contrib/validated/aurora/prs/)

## Quick start: build and install a payload

The payload is one file: m1n1 (0x400000 bytes) | boot arguments | `Image.gz` | device tree | initramfs.
[`mk-daily.py`](contrib/validated/aurora/tools/mk-daily.py) builds it from named, hash-pinned ingredients and
prints the commands for the swap; it never touches the machine. What may sit on the ESP, and how a failed test
returns to the last good payload, is in [`ESP-POLICY.md`](contrib/validated/aurora/tools/ESP-POLICY.md): read it first.

```bash
# 1. kernel: a worktree of aurora-silicon/linux at 33bec4016c46 + the series, then build it (recipe: series/SERIES.md)
git am contrib/validated/aurora/series/patches/*.patch
# the daily adds, in this order: Aurora #1012 and the 27.2+ GPU port (contrib/pending/gpu/patches/kernel-27.2/), the N1 training
# (contrib/pending/wireless/patches/linux/0004-0010), peripherals 0007 (F6) and nvram 0001 (contrib/pending/)
make LLVM=1 ARCH=arm64 defconfig asahi.config j716s.config && make LLVM=1 ARCH=arm64 -j Image.gz dtbs

# 2. check the ingredients, then build a test payload (it reverts itself if the network does not come up)
python3 -I contrib/validated/aurora/tools/mk-daily.py --list      # edit INGREDIENTS (paths, pins) for your machine first
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --label my-test

# 3. print the ESP swap, read it, run it yourself; boot the test with the Ethernet adapter attached
#    (leave the machine idle for 60 s after any large write before rebooting: docs/boot-and-recovery.md)
python3 -I contrib/validated/aurora/tools/mk-daily.py --deploy-plan --payload DIR/my-test-<date>-<hash>.bin --host root@<linux-ip>

# 4. once it reached the network, rebuild the same ingredients as the daily (no self-revert, battery on)
python3 -I contrib/validated/aurora/tools/mk-daily.py --out DIR --daily --battery --force
```

The stage-2 m1n1 of the daily (`n1-dt-gpu`) is upstream plus `patches/m1n1/`, the N1 hand-off patches 0022 and 0028 of `contrib/pending/wireless/patches/m1n1/` (the port stays enabled and the host tunables are copied; the kernel trains the N1, so 0023 and 0025-0027, the loader-side training, are optional) and the GPU hand-off of `contrib/pending/gpu/patches/m1n1/` (0019 and the GPU patch numbered 0028, behind `chosen.m5pro,gpu=1`; the N1 patch 0028 is a different one) (toolchain and recipe: [`m1n1-BUILD.md`](contrib/validated/integration/m1n1-BUILD.md)):

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
