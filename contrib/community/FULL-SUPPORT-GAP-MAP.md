# Full-support gap map: MacBook Pro 16-inch M5 Pro (J716s, T6050) under Linux/Omarchy

Written 2026-11-08 (UTC) on the Mac Studio from the repository, the public trackers and the private hardware
inventory of this one machine. Nothing was booted for this document. Machine-readable twin: [`gap-map.csv`](gap-map.csv)
(same rows, same columns). Status words used everywhere: **works** (daily or test payload, with a result log),
**partial** (works with a named hole), **prepared** (patches/DT built, never booted), **blocked** (tried, stopped by a
hang or a missing piece), **missing** (nothing written here yet), **in study** (a sibling feasibility study is being
written right now), **not planned**. Effort uses the repo scale (S <= 2 days, M <= 2 weeks, L <= 2 months, XL = new
driver or protocol RE, no date). "Elsewhere" names who already has the feature: Asahi (M1/M2), Aurora (M3/M4; the
M4 Pro 16-inch J616s record is the closest precedent), or nobody.

No per-unit value appears in this file or in the CSV: only node names, compatible strings, property names, register
offsets and sizes. The ADT dump, the N1 firmware, calibration data and NVRAM contents stay off the repository.

## 1. One-screen summary

- **94 capabilities** across 18 domains: 20 work, 27 partial, 12 prepared (built, unbooted), 2 blocked, 23 missing,
  4 in study (ProRes, hardware encode, Touch ID, SEP keys), 6 not planned.
- **What a user has today** (from [`README.md`](../../README.md) and the tracker
  [`machines/j716s/machine.yaml`](https://github.com/rolotrealanis98/m4-m5-linux/blob/main/machines/j716s/machine.yaml)):
  18 cores, NVMe root, WFI idle (~9.8 W idle on the charger), keyboard, backlight, trackpad with haptics, battery and
  sensors, s2idle with lid, both front Type-C ports as USB3 hosts, Wi-Fi and the Bluetooth controller on the N1,
  speakers (capped) and mics, the DCP driving the panel at 120 Hz with VRR, GPU acceleration (Vulkan, zink), Hyprland
  on Omarchy 4.5, NVRAM read, an A/B boot chain with a watchdog.
- **The seven gaps that decide whether this is a laptop or a demo**: (1) GPU recovery that kills the compositor,
  (2) Thunderbolt/USB4 and with it external displays and docks, (3) the speaker profile and the lifted volume ceiling,
  (4) sleep power on battery (never measured) and the RTC wake, (5) the Omarchy installer refusing M4+ with no
  per-unit firmware step for the N1, (6) packages (linux-aurora 7.2.11 has no T6050; mesa-aurora has no G17), (7) no
  deeper idle than WFI and no DRAM DVFS, so the power budget stays about 2x macOS.
- **What Asahi delivers on M1/M2 that the J716s lacks** (their M5 page is all TBA, so every T6050 feature comes from
  Aurora and omacom): external displays and HDMI (with audio preview), camera, SD card slot, video decode in the daily,
  NVRAM write via `asahi-bless`, ambient light sensor, an installer, hibernation-free but measured s2idle.
- **What Aurora adds on M3/M4 that the J716s lacks**: Touch ID with fprintd (SEP), HDR/EDR output, Thunderbolt + DP
  tunnels, fan control (impossible as-is on the T6050 SMC: no `Ftst`), ANE driver, video encode and ProRes, RTC wake,
  NVRAM writes, Aura (EL2 loader (Aura PR #77, merged 2026-11-07, removed the EL2 monitor, PSCI, NV2 and PV-KVM: Linux now runs at EL2 inside the CTXR window; monitor-free build untested on hardware at merge time)), speakerguardd/aurora-audio profiles, `aura recover`.
- **What macOS does that no Linux on Apple Silicon has a name for yet** (from the macOS 27.3 kext list and the ADT):
  the always-on display coprocessor (`aod2`), voice trigger and always-listening mics, USB audio offload (`auss`),
  the AES engine, the USB-C retimers (`uatcrt0..2`), the DP input muxes (`atc*-dpin*`), the panel TCON and its PMIC/EEPROM/temperature
  sensors (owned by the DCP firmware), the BTM battery/thermal monitor, NFC, the exclave services (ISP, ANE, SEP
  manager, privacy indicator brightness), deep sleep with the SoC powered down, hibernation, secure boot with signed
  kernels.
- **Hardware inventory**: 608 classified ADT rows; 109 driven, 43 prepared in a test tree, 125 with a driver elsewhere
  but no T6050 wiring, 45 with no Linux driver anywhere, 286 firmware-internal (section 4).

## 2. How to read the tables

Columns: Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing |
Effort | Risk | Dependency / upstream | Tracker issue (`#N` = [rolotrealanis98/m4-m5-linux](https://github.com/rolotrealanis98/m4-m5-linux/issues)) |
Sources (repo paths relative to `m5pro-linux`; `RESULTS` = `contrib/validated/integration/RESULTS.md`, section by heading).

Sources behind every row, in the order the brief asked for: the repo status table and `RESULTS.md`; `contrib/pending/*`
reports; the tracker YAML; the private ADT walked node by node and cross-checked against the kernel worktrees
(`/Volumes/linux-cs/wt-*/arch/arm64/boot/dts/apple/t6050*`); the Asahi feature-support pages
([m2](https://github.com/AsahiLinux/docs/blob/main/docs/platform/feature-support/m2.md),
[m5](https://github.com/AsahiLinux/docs/blob/main/docs/platform/feature-support/m5.md)); Aurora's device records
([support.json](https://github.com/aurora-silicon/aurora-silicon.github.io/blob/main/src/data/support.json), whose J716s
rows are owner-asserted and conflict with this machine's logs on fan control, HDMI and external displays) and PR list;
omacom's [roadmap #56](https://github.com/omacom/linux-aurora/issues/56) (M1/M2/M3/Neo only, no M4/M5),
[omarchy-pkgs](https://github.com/omacom/omarchy-pkgs), [omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer),
[linux-aurora #413](https://github.com/omacom/linux-aurora/pull/413); the macOS 27.3 kext list and ioreg planes (names only).
The three sibling feasibility studies are referenced, not repeated: `contrib/pending/video/prores/`,
`contrib/pending/video/encode/`, `contrib/pending/platform/touchid-sep/FEASIBILITY.md`.

## 3. Gap tables by domain

### Boot chain and recovery

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Untethered boot from the internal disk | iBoot -> macOS | A/B stage-1 m1n1 on the boot slot, stage-2 payload on the ESP, ~50 s to ssh; needs the macOS 27.3 beta 1 stub (older stubs start one core) | **works** | Asahi, Aurora | Nothing for the owner; a stranger needs the installer row below | - | - | omacom/m1n1 #30 + #33; aurora-silicon/linux #1167 (merged) | - | README; machine.yaml boot.untethered |
| Fallback after a failed boot (A/B, watchdog, self-revert) | iBoot boot-failure counter, Recovery | Stage-1 A/B with a 150 s watchdog, systemd feeds the watchdog on the daily, test payloads self-revert; a reboot right after a write burst is still counted as a failed boot (60 s idle rule); stage-1 0017 (counted restart boots the primary) waits for an attended 1TR sitting; NVMe shutdown patches compile-checked only | **partial** | nobody (Asahi/Aurora have no A/B stage 1; Aura has a fixed boot layout) | Stage-1 0017 install (ceremony); NVMe/SMC shutdown settle patches booted; nothing resets a userspace-dead partial hang | S + one 1TR ceremony | Stage-1 reinstall is the one step that can leave the machine on the USB proxy; attended only | omacom/m1n1 #36 (wdt=keep) | #5, #15 | contrib/pending/boot-ab/firstboot/REPORT.md; contrib/pending/boot-ab/nvme-shutdown/README.md; RESULTS 'RESTART-EXP4' |
| Omarchy boot chain (m1n1 -> U-Boot -> Limine -> EFI-stub kernel) | n/a | Built, never booted; needs a cold start with a person present; U-Boot does a fresh ANS handshake, no N1 hand-off, Limine menu has no keyboard | **prepared** | Asahi (U-Boot + GRUB/systemd-boot), Aurora/Omarchy (U-Boot + Limine, or Aura stage 1/2) | One attended cold boot; ANS live hand-over ported into stage 1; N1 hand-off in that chain; Plymouth/initramfs size on the 476 MiB ESP unmeasured | M | Attended only (only the 150 s stage-1 watchdog as fallback) | omacom/m1n1 #30; omarchy-mac-boot | #6 | contrib/pending/installer/omarchy-chain/REPORT.md; contrib/pending/installer/PLAN.md section 5 |
| Aura (EL2 monitor + stage 1/2) or UEFI firmware instead of m1n1 | n/a | Not used; the J716s runs m1n1 at EL2 with Linux at EL2 | **missing** | Aurora (Aura on J616s/Neo; Project Mu UEFI work in aurora-silicon/mu) | Aura T6050 support (its SEP warm-registration rule, display/GPU hand-offs) or a decision to stay on m1n1 | L | Boot-chain change = ceremony; attended | aurora-silicon/aura | - | contrib/pending/platform/touchid-sep/FEASIBILITY.md section 1; upstream aurora.md (aura) |
| Crash evidence from a frozen boot (pstore, netconsole) | panic log in NVRAM/pram, sysdiagnose | RAM pstore not viable (iBoot clears the region); netconsole needs a LAN receiver the machine can reach (double NAT blocked it); evidence today = selftest logs and panel photos | **blocked** | Asahi (pstore not used either; serial via Kanzi/kisd) | A reachable netconsole receiver; or an SMC/NVRAM-backed panic record (protocol unknown); or DebugUSB serial | S (receiver) / XL (NVRAM panic record) | none | - | #31, #32 | contrib/pending/crashlog/REPORT.md; RESULTS 'CRASHLOG-PRAM' |
| Reboot into macOS / choose the startup disk from Linux | Startup Disk, bless | Omarchy menu rows installed; the click path needs an NVRAM write (alt-boot-volume) that has never been done; macOS today = power-hold menu | **prepared** | Asahi (asahi-bless), Aurora (aurora-bless; NVRAM writes merged for J616s #674, J700 #673) | First NVRAM write (see nvram.write); asahi-bless/aurora-bless packaged for the root; proof that iBoot consumes the one-shot variable on M5 | S | A bad NOR write can need DFU; the driver's board row fails closed; attended | aurora-silicon/linux spi-apple-qspi board row | #4 | contrib/pending/nvram/REPORT.md; contrib/validated/desktop/omarchy-fixes/2026-11-08-startup-disk-menu.md |

### CPU, memory and power management

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| All 18 cores (12 P + 6 E) | yes | 18 CPUs online on every boot with the 27.3 beta 1 stub firmware | **works** | Asahi, Aurora | Nothing; the stub-version gate belongs in the installer | - | - | omacom/m1n1 #33 | - | README; docs/smp-t6050-raw-path.md |
| CPU frequency scaling with the right p-state table | CLPC + DVFS, boost states | schedutil on all three clusters through the T8112 fallback binding; the P-cluster p-state offset, M p16 (4380 MHz) and P p18-p21 never measured on the J716s; no T6050 entry in apple-soc-cpufreq.c | **partial** | Asahi (M1/M2 upstream 6.2), Aurora (J616s with PMP #402; T6050 binding PR #481 open) | One measurement boot (cpuhz/dvfs-regs); T6050 entry + binding decision (#481); boost grant check | S | none | aurora-silicon/linux #481 | - | contrib/pending/followups/PSTATE.md; contrib/pending/power/REPORT.md |
| CPU idle: WFI and deeper states | deep core/cluster power gating via CLPC/PMP | WFI idle works (16.4 W -> ~9.8 W on the charger); m1n1 still appends idle=nop, series 0061 ignores it; no deeper state (WFI/WFIT lose state on M4+, cpuidle-apple writes a locked sysreg) | **partial** | Asahi (WFI hack, not upstreamable), Aurora (#826 cpuidle T6050 merged) | A cluster/core power-down method for M4+ (PSCI-less), likely via PMP or an EL2 monitor (Aura); drop idle=nop from m1n1 | XL | Hangs/SError when experimenting with power gating; loop-safe payloads only | aurora-silicon/linux #1152; Aura | - | contrib/pending/wfi-idle/REPORT.md; docs/plan/ROADMAP.md Tier 3; asahi-fs m2 cpuidle note |
| DRAM/fabric DVFS (PMC/CLPC votes, memory bandwidth) | CLPC votes DCS/fabric states; full bandwidth | PMC driver in observe mode booted (votes computed, nothing written); firmware enables no voter, so DRAM/fabric likely sit at the lowest state (T8142 precedent: 40 -> 110 GB/s copy bandwidth); T3 (first write) built, attended | **prepared** | Aurora (PMP cpufreq on J616s #402; PMP v2 #475 open) | T3 attended write, T4 boost check, T5 10-min thermal run; bandwidth/power per state; PMP throttling behaviour | M | Attended only (a wrong vote can hang the fabric) | aurora-silicon/linux #475/#481 | #3 | contrib/pending/power/REPORT.md; RESULTS 'POWER-T1 retest' |
| Idle power budget comparable to macOS | ~3-5 W class idle on battery with display on (not measured here) | ~9.8 W idle on the charger with the display on; no deep idle, no DRAM DVFS, no DCP/GPU power states tuned, VRR idle not measured, s2idle drain on battery not measured | **partial** | Aurora J616s reports s2idle 1.35-2.65 W drain (omacom #291/#403); Asahi M1/M2 full idle path | Measurement ladder (battery, panel off, VRR on/off, GPU idle); then the items cpu.idle, power.pmc, gpu.pm, display.pm | M (measure) / XL (close) | none | - | #10 | README WFI row; contrib/pending/dcp/vrr/REPORT.md; contrib/pending/peripherals/REPORT.md (s2idle-drain.sh) |
| Thermal zones, passive cooling trips | CLPC thermal management, SMC fans automatic | /sys/class/thermal empty; stage A (7 monitoring zones) and stage B (passive 95 C trips + cpufreq cooling) designed and compile-checked, not booted; fans run on the SMC's own loop | **prepared** | Asahi/Aurora (macsmc-hwmon zones; Aurora #481 thermal profile) | Boot stage A, then B; macsmc_soc_die key discovery; critical trips only after power-off is re-verified on the Aurora kernel | S | A wrong critical trip powers the machine off | - | #35 | contrib/pending/platform/REPORT.md; contrib/pending/power/REPORT.md |
| Memory: 48 GiB, zram, EDAC | memory compression, ECC scrub | 48 GiB with 16 K pages, zram zstd built in; apple_soc_edac only =m, untested; a ~46 GB allocation runaway seen once on the DCP+GPU kernel under fullscreen glmark2 (under investigation) | **partial** | Asahi, Aurora | Root-cause the display-path leak; EDAC check | S-M | none | - | #36 (related) | RESULTS 2026-11-08 'daily-dcp-rec-p2000 ... OOM'; contrib/validated/aurora/tools/modules/MODULES.md |
| CPU performance counters (perf) | kperf/Instruments | Apple PMU driver exists upstream (M1/M2 6.4) with per-core event tables; no T6050 core entry checked, `perf stat` not recorded on the J716s | **missing** | Asahi (M1/M2 upstream), Aurora (M3/M4 WIP per asahi-fs m3) | apple-m1-pmu compatible for the M5 cores (sawtooth/everest) in the DT and driver event tables; one perf run | S-M | none | - | - | asahi-fs m2 PMU row; macOS ioreg CPU compatibles (names only) |

### Storage

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Internal NVMe (ANS) root | yes | Root on NVMe, read-write; ANS RTKit handshake takes ~3 s (10 s wait merged as #1082) | **works** | Asahi, Aurora | PCIe/NVMe power states and shutdown ordering (see boot.ab); APST/ASPM not studied | - | - | aurora-silicon/linux #1082 (merged), #936 | - | README; machine.yaml storage.nvme |
| SDXC card reader (Genesys GL9755 on apcie0 port 1, same root complex as the N1) | AppleSDXC, UHS-II | DT patch (peripherals 0005: port + DART, disabled) written; the m1n1/kernel training of apcie0 port 1 (pcIO power line, PERST#, Gen1) not written; never booted | **prepared** | Asahi M1/M2 MBP (upstream 5.17), Aurora J616s partial (#867 detected, #1069 reset flake) | Port-1 training (kernel-side like the N1 port or in m1n1), sdhci-pci-gli built in, one card test | M | Shares the root complex with the Wi-Fi port: a bad train can take Wi-Fi down for that boot | aurora-silicon/linux #937 (PCIe root ports) | - | contrib/pending/peripherals/REPORT.md items 6; macOS ioreg pci17a0,9755 |
| Full-disk encryption (LUKS) with the keyboard in the initramfs | FileVault (SEP-sealed) | Root is plain ext4; Omarchy's Mac path expects btrfs + LUKS at first boot (omarchy-mac-boot); not run on the J716s | **missing** | Aurora/Omarchy (in-place encryption at first boot; SEP-sealed LUKS2 in aurora-xart for Neo) | omarchy-mac-boot first-boot encryption on this chain; later SEP-sealed unlock (see sec.sep) | M | Data loss if the initramfs lacks the keyboard driver; test on a scratch root | omarchy-mac-boot | - | contrib/distro/GAPS.md #16; contrib/pending/installer/PLAN.md phase 5 |

### Display

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Internal panel through the DCP (modeset, 120 Hz, VRR) | IOMobileFramebuffer, ProMotion 24-120 Hz, QMS/LFC | apple-drm on the 27.3 firmware drives the panel (six native timings, 120 Hz preferred, VRR with fw27_panel_vrr=1, min 24 Hz); verifier 22/0; demoted once (page flip wedged by a GPU client fault) and re-promoted with the recovery patches; mode list inferred, fixed-rate modes unproven | **works** | Asahi (M1/M2 DCP), Aurora (J616s #446/#452, VRR #451/#763) | Daily stability under GPU faults (gpu.recovery); Hyprland vrr switch once per session; surface-less swap quirk; direct scanout for fullscreen clients | S-M | A DCP crash blacks the panel until reboot | aurora-silicon/linux #1174, #1012; omacom/m1n1 #35 | #18, #19, #36 | README display row; contrib/pending/dcp/REPORT.md; contrib/pending/dcp/vrr/REPORT.md |
| Backlight brightness and the brightness keys | DCP-owned backlight, 1600 nit HDR peak, auto-brightness from the ALS | Backlight writes reach the panel through the DCP (readback 300/600 verified; by-eye confirm pending); keys bound on the desktop; no auto-brightness (no ALS) | **works** | Asahi, Aurora | By-eye confirm; auto-brightness needs sensors.als | S | none | - | #13 | machine.yaml display.brightness |
| HDR/EDR, 10-bit output, P3 colour, True Tone, Night Shift | XDR panel: HDR to 1600 nit, EDR headroom, P3, True Tone (truetone-shift + ALS), Night Shift | Nothing studied: 8-bit XR24 scanout only; no HDR metadata path, no colour management, no True Tone (no ALS), Night Shift = compositor gamma only | **missing** | Aurora J616s (EDR panel #777, HDR10 external #764, GNOME HDR #789); Asahi partial (10-bit on some) | DCP fw-27 HDR/EDR swap properties and colour-space calls in apple-drm for T6050; 10-bit framebuffer formats; compositor plumbing (Hyprland HDR); True Tone needs ALS + a colour pipeline | L | none beyond display stability | aurora-silicon/linux #777/#789 ports to fw 27 | - | macOS ioreg display properties (names only); upstream aurora.md 10-bit/HDR row |
| External displays: DisplayPort alt mode on the Type-C ports | up to 2 external 6K via dispext0-3 and the DP crossbars | dcpext0 and atc2_xbar disabled in the DT; DP alt mode untested on both ports; the DP PHY (#940) and combo PHY (#480) series are Aurora's, not booted here; DisplayPort tunnelling over USB4 needs usb.thunderbolt | **prepared** | Asahi (WIP on M1/M2), Aurora (J616s #451/#526 works) | dcpext nodes + m1n1 hand-off for the external DCPs, DP crossbar routing, dptx-phy for T6050, one monitor test per port | M-L | Attended (a PHY misconfiguration can wedge the port or hang probe like TB-T0) | aurora-silicon/linux #940, #480, #946 | #20 | RESULTS line 846 (DP untested); contrib/validated/aurora/atc-tunables/REPORT.md |
| HDMI port (atc3 DP->HDMI, pcon0 on i2c8, dp2hdmi GPIOs) | HDMI 2.1 with audio | No DT node for atc3/pcon0/dp2hdmi-gpio0 (i2c8 'HDMI converter' listed as node-less); nothing booted | **missing** | Asahi M1/M2 MBP (HDMI out linux-asahi, audio preview), Aurora J616s (#749) | Nodes for atc3 as a DP-only port, the HDMI protocol converter on i2c8 and its GPIOs, a dcpext instance for it, HDMI audio via dp-audio | M-L | Attended | display.external | #20 | contrib/pending/peripherals/REPORT.md /arm-io list; macOS ioreg AppleATCDPHDMIPort |
| Display power management (panel off on idle, DCP low power, early buffer release) | full DCP PM, panel self-refresh | Idle desktop stops redrawing; DPMS off/on and the DCP idle state not measured; early-release-buffer not enabled; idle power with VRR on/off not measured | **partial** | Asahi, Aurora | DPMS cycle test, idle-power measurement, firmware idle cache behaviour (Aurora #1185 freeze on j713 is the risk) | S-M | A DPMS bug blanks the panel | - | - | contrib/pending/dcp/vrr/REPORT.md lines 38,43; contrib/validated/display/stage-c-analysis.md |
| Notch handling and the camera privacy indicator brightness | notch-aware menu bar; indicator brightness via ExBright (exclave) | Notch rows kept (m1n1 show-notch) and the desktop avoids them; indicator LED brightness is exclave-owned, not reachable | **partial** | Asahi (notch), Aurora | Nothing for the notch; indicator brightness not planned | - | - | - | - | docs/plan/ROADMAP.md Tier 3; patches/m1n1/0017 |

### GPU

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| GPU acceleration: Vulkan, zink GL, compositor on the GPU | Metal 4, AGXG17X 20 cores | aurora DRM driver with the 27.3 firmware boots on every daily; Vulkan (G17S B1) passes compute/render/stress; Hyprland renders on zink and the GPU writes straight into the DCP scanout buffers | **works** | Asahi (M1/M2 asahi driver), Aurora (M3/M4; G17 #1056/#1070 open) | Upstream merge of #1173; see the rows below for the rest | - | - | aurora-silicon/linux #1173, #1012; omacom/m1n1 #37 | - | README GPU row; RESULTS 'GPU E2b' |
| GPU fault recovery that does not kill the compositor | per-context recovery, apps survive | A client fault (Chrome, Electron, quickshell) makes recovery declare Hyprland's context lost, zink SEGVs, Hyprland falls to safe mode and on the DCP kernel the page flip wedges; recovery patches 0001-0003 + aurora.m5_pause_timeout_us=2000 gave zero recoveries in one 10-min run; Electron apps still run with --disable-gpu | **partial** | Asahi (same driver family, fewer reports), Aurora M3/M4 (no equivalent report) | A daily with the 2000 us bound after a loop boot; Mesa fix for zink's lost-context SEGV; root cause of the DSF pause timeout (hypotheses H2-H6) | M | Desktop crashes; display wedge until reboot | aurora-silicon/linux (future PR), aurora-silicon/mesa | #36 | contrib/pending/gpu/GPU-RECOVERY-KILLS-COMPOSITOR.md; contrib/pending/gpu/faults/HYPOTHESES.md |
| Native Gallium OpenGL (no zink) | n/a | 12/12 scenes, GL 4.6, faster than zink; cannot build the fragment programs of ordinary apps (Alacritty black); fixes 0006-0008 verified offline and once side by side, the gl2 A/B not done; session stays on zink | **partial** | Asahi (native GL on M1/M2 in upstream Mesa), Aurora (mesa#194 for G17S/G17C) | Land 0006-0008 in mesa#194, A/B on the desktop, then make it the session default | S-M | none (A/B tree) | aurora-silicon/mesa #194 | #16, #17 | contrib/pending/gpu/gl-native/REPORT.md; APP-REGRESSIONS.md |
| GPU power management (idle power states, clock/voltage scaling, perf counters) | full DVFS and power gating, GPU counters in Instruments | Firmware-managed DVFS as the driver initialises it; no measurement of idle GPU power or clock states on the J716s; perf counters not exposed | **missing** | Asahi (asahi driver exposes pstates/idle; counters WIP), Aurora | InitData power tables for the M5 Pro tuned (not copied), idle power measured, counters (perfmon) plumbing | M | none | aurora-silicon/linux #1173 | - | contrib/pending/gpu/REPORT.md; contrib/pending/gpu/RUNTIME-DIFF-27.2.md |
| Hardware ray tracing, mesh shaders, Dynamic Caching, Vulkan 1.4 conformance | Metal 4: RT, mesh shaders, Dynamic Caching, neural accelerators in shaders | Not exercised; the aurora-support site marks J716s ray tracing 'partial' with no test behind it | **missing** | Aurora (RT via mesa#139 on J616s), Asahi (no RT on M1/M2 hardware) | mesa#139 RT path validated on G17S; mesh shaders and Dynamic Caching are compiler/firmware features nobody has started on | L-XL | none | aurora-silicon/mesa #139 | - | upstream aurora.md J716s row; aurora-support j716s |

### Audio

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Six-speaker array with the tuned DSP profile | spatial audio, full level | Speakers play clean in the J616s TDM frame with six amps and speakersafetyd; kernel ceiling -30 dB; the J716 profile (J616s graph, cap -10 dB) is staged, not active; speaker-sense reads 4x (a J714c realign bit applied to the J716s) unverified; the listening test has not run; route had to be fixed by hand once | **partial** | Asahi (M1/M2 full profiles), Aurora J616s partial (J316 values, silent after sleep until #820) | Listening test, per-board realign fix, lift the ceiling, bankstown-lv2 packaged, a J716 graph in aurora-audio | S (listen) / M (profile upstream) | Speaker damage if the ceiling is lifted before the sense fix; attended | omacom/omarchy-mac-pkgs #103; aurora-audio | #7, #22 | contrib/validated/desktop/audio/j716-profile/REPORT.md; RESULTS 'R3-AUDIO-B6' |
| Three-microphone array (AOP leap path), beamforming, voice trigger | beamforming, voice isolation, 'Hey Siri' on the AOP | Three capsules record and track the voice through the AOP audio path; no beamforming, no voice trigger, no always-listening | **works** | Asahi (M1/M2 mics), Aurora (J616s #406) | Beamforming/noise suppression are userspace (PipeWire filter chain), voice trigger not planned | S (filters) | none | - | - | RESULTS 'R3-AUDIO-A2' |
| 3.5 mm jack: headphones, jack detect, headset mic, impedance sensing | CS42L84 with impedance detection and high-impedance mode | Jack and headset-mic switches register; nothing has been plugged in yet | **partial** | Asahi (M1/M2 jack linux-asahi), Aurora J616s partial (headset mic untested) | One attended plug test; high-impedance mode and impedance sensing are codec features the cs42l84 driver does not expose | S | none | - | #11 | README jack row |
| HDMI / DisplayPort audio | yes | No external display path yet | **missing** | Asahi (HDMI audio preview, glitches), Aurora J616s (no audio yet #729) | display.hdmi/display.external first, then the dp-audio endpoints in apple-drm | M | none | display.external | #20 | asahi-fs m2 HDMI audio note |

### Input

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Keyboard, Globe/Fn row, media keys | full | dockchannel-hid keyboard; fnmode=3; Globe = KEY_FN; F6 mapped to Do Not Disturb (was KEY_SLEEP), not yet pressed to confirm; no keyboard-light keys on this keyboard (bound to SUPER+F5/F6) | **works** | Asahi, Aurora | F6 confirm; Globe-key emoji/input-switch behaviour in the shell | S | none | - | #12 | contrib/pending/peripherals/REPORT.md function row |
| Keyboard backlight and its ambient control | PWM, auto by ALS | kbd_backlight LED works (fpwm0, 255 steps); no automatic control (needs the ALS) | **works** | Asahi, Aurora (kbd-light daemon uses ALS) | sensors.als, then aurora-silicon/kbd-light | S after ALS | none | sensors.als | - | README keyboard row |
| Trackpad, haptic click, palm and thumb rejection, presets | Force Touch, palm rejection in firmware | Multi-touch ready on every boot, both MTP haptic devices give feedback, three Hyprland presets; the firmware palm class is not reported on T6050 (module parameter, untested); click strength not set | **works** | Asahi, Aurora | Palm/thumb measurement and the T6050 palm-class follow-up; libinput quirk thresholds measured; click-strength value | S | none | aurora-silicon/linux #1083 (merged) | #12 | contrib/pending/platform/trackpad-feel/NOTES.md; contrib/pending/followups/HAPTIC.md |
| Touch ID button as power/wake key | power + biometrics | SMC button 0x06 -> KEY_POWER, wakes from s2idle; no biometrics (see sec.touchid) | **works** | Asahi, Aurora | - | - | - | - | - | contrib/pending/peripherals/REPORT.md |

### SMC: battery, charging, fans

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Battery and charger reporting | full gas-gauge data, cycle count, health | macsmc-power: status, capacity, voltage, current, cycles, temperature, AC input power; discharging, MagSafe unplug events and overnight drain not exercised on this kernel | **works** | Asahi (7.1 upstream), Aurora | Attended discharge/unplug test, overnight drain | S | none | aurora-silicon/linux #941 (T6050 SMC, open) | #10 | RESULTS 'R3-S' |
| Charge limit (80 %), optimised charging, battery health management | Optimized Battery Charging, 80 % limit, health management (macOS-side learning; no such keys visible in the registry on this unit) | charge_control_end_threshold via SMC CHLS works by code (same as Asahi/Aurora), untested on the J716s; charge_behaviour auto only (no CHTE/CH0C/CH0I keys, so no inhibit-charge or force-discharge); Omarchy ships omarchy-battery-charge-limit | **partial** | Asahi/Aurora (CHWA/CHLS) | One attended threshold test; inhibit/force-discharge impossible on this firmware; 'optimised' learning is userspace policy if wanted | S | none | omarchy-mac package | #10 | contrib/pending/peripherals/REPORT.md charging; macOS ioreg AppleSmartBattery property names |
| MagSafe: attach state, LED, PD negotiation reporting | hpm5 PD controller, LED amber/green by charge state | Charging through MagSafe works; hpm5 (SN201202x) attach-state draft (peripherals 0006) not run; LED not controlled (path unknown: only policy-override-led on eic) | **partial** | Asahi/Aurora (MagSafe charging; LED is firmware-managed there too) | hpm5 node for attach/PD state; LED semantics are probably firmware/SMC, protocol unknown | S / XL (LED) | none | - | - | contrib/pending/peripherals/REPORT.md item 7; macOS ioreg hpm5 |
| Fan readout and manual fan control | SMC automatic; manual via private APIs | Both fans and 60+ temperatures read; no manual control: the T6050 SMC has no Ftst unlock key; macOS also shows no fan service (SMC-internal loop) | **partial** | Asahi (readout; manual via hwmon on some), Aurora J616s (manual via #639 + unlock retry #696) | The T6050 unlock key or F0md/F1md mode semantics (SMC key RE); may be impossible by design | M (RE) or not planned | Overheating if a manual mode sticks | aurora-silicon/linux #1084 (merged) | - | RESULTS 'HWMON-T1'; UPSTREAM-NOTES F0md/F1md |
| Power-off and restart through the SMC | yes | Power-off worked on the 7.2 stack (apple,poweroff-only); not re-run on the Aurora kernel; restart = watchdog | **partial** | Asahi, Aurora | One power-off run on the current daily (a person must power it on again) | S | attended | - | - | contrib/validated/aurora/STATE.md Aurora open items |

### Sleep and wake

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Suspend to idle, lid close/open, wake sources | full sleep ladder | Real s2idle with power-button and lid wake, Wi-Fi back after resume; not re-run on the current daily (kernel-trained N1, DCP scanout, systemd watchdog); apple_wdt stops in suspend so a sleep hang is uncaught; lid wake limit when MSLD says open | **works** | Asahi, Aurora (#826 T6050 cpuidle; #1199 retained-link s2idle open) | Re-run on the daily (attended); repeated cycles; sleep with audio playing; right port across sleep; WD2 guard | S | A hang in sleep needs the power button | aurora-silicon/linux #1160 | #8 | RESULTS 'WFI soak + SLEEP S1-S4', 'N1-SLEEP'; contrib/pending/platform/lid-sleep/ANALYSIS.md |
| Sleep power draw and standby time | days of standby; hibernation after a threshold | Not measured (s2idle-drain.sh ready, needs a night on battery); no PMGR/PMP sleep sequence runs, so coprocessors stay up | **missing** | Aurora J616s/J413 reports 1.35-2.65 W s2idle drain | Measurement, then device-level suspend for the DCP, GPU, N1, ANS | S (measure) / L (reduce) | none | - | #10 | contrib/pending/peripherals/REPORT.md item 4; omacom/linux-aurora #291/#403 |
| RTC wake alarm (rtcwake, scheduled wake) | yes (PMU RTC alarm) | No rtcwake: rtc-macsmc has no alarm, the PMU alarm needs nvmem cells + the SPMI interrupt, and the gen-4 SPMI driver refuses interrupts | **missing** | Asahi (RTC 7.0, alarm on some), Aurora J616s (#836 RTC wake) | SPMI gen-4 interrupts (#477) and the Abbey PMU RTC alarm (#478) for T6050 | M | none | aurora-silicon/linux #477, #478 | - | contrib/pending/dt-prep/s2idle/SLEEP-PLAN.md line 44 |
| Deep sleep (SoC powered down, suspend-to-RAM class) | yes | None; only s2idle | **not planned** | Aurora WIP for the Neo only (#1208 at EL2); nobody on M4/M5 Pro | An EL2 monitor that survives the SoC power-down (Aura-class) and PMGR/PMP restore paths; firmware re-boot of every coprocessor on resume | XL | high (hang/brick-adjacent state, attended) | aurora-silicon/linux #1208; Aura | - | contrib/pending/peripherals/REPORT.md hibernate row; upstream aurora.md deep sleep |
| Hibernation (suspend to disk) | safe sleep / hibernation | Not feasible now: spin-table CPUs cannot go offline, iBoot restarts every coprocessor on resume; CONFIG_HIBERNATION on but units masked, never write 'disk' | **not planned** | Asahi (not set), Aurora WIP on J616s (#906 under Aura's fixed boot layout) | PSCI-like CPU offline (monitor), coprocessor restore, a fixed boot layout the resume kernel can find | XL | Writing 'disk' today = a hang or a corrupted resume | aurora-silicon/linux #906; Aura | - | contrib/pending/peripherals/REPORT.md; contrib/pending/dt-prep/s2idle/SLEEP-PLAN.md lines 51-52 |

### Wireless (Apple N1)

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Wi-Fi association, DHCP, traffic, warm restart, NetworkManager | Wi-Fi 7 (802.11be), 2.4/5/6 GHz | The kernel trains the N1 PCIe port itself; wlan0 WPA2/WPA3 on 5 GHz, DHCP, traffic, survives a warm restart and lid sleep; NetworkManager since 2026-11-08 (pmf=1 for transition SSIDs); 14 % ping loss seen once | **works** | Asahi (brcmfmac M1/M2), Aurora (J616s BCM4388; J716c N1 #938) | Long soak; upstream merge of #1182/#1183; firmware is per-unit (see dist.firmware) | S | none | aurora-silicon/linux #937, #938, #1182, #1183; aurora-silicon/m1n1 #65; omacom/m1n1 #34 | #33 | README Wi-Fi row; contrib/pending/wireless/N1-KERNEL-TRAIN.md |
| Wi-Fi 6 GHz, Wi-Fi 7 features (MLO, 320 MHz), regulatory | full | No 6 GHz entries in the firmware regulatory list on this unit (6 GHz 0); MLO/320 MHz not studied; country handling not stated | **partial** | Aurora J716c (#938 claims 6 GHz) | Regulatory table source (firmware vs. host), 6 GHz enable, MLO support in the protocol-27 driver | M | regulatory | aurora-silicon/linux #938, #483 | #33 | README Wi-Fi row; series 0043 |
| AP/hotspot, monitor, P2P/AWDL (AirDrop), low-latency | Personal Hotspot, AWDL, NAN | Not studied; the driver is station-only | **missing** | Asahi (brcmfmac AP mode; AWDL via brcmfmac-awdl-dkms on BCM4378/87/88); nobody on the N1 | Firmware interface RE for AP/monitor modes in the protocol-27 driver | XL | none | - | - | omarchy-pkgs brcmfmac-awdl-dkms (BCM only) |
| Bluetooth pairing, audio (A2DP/LE Audio), input devices | BT 5.3/6, LE Audio | hci0 up, scans 36 devices; no device paired yet; no address/calibration sync from macOS needed? (the N1 firmware is per-unit) | **partial** | Asahi (M1/M2 BT), Aurora (#484 N1 BT) | One attended pairing + audio test; BT across sleep; LE Audio stack in userspace | S | none | aurora-silicon/linux #484 | #9 | RESULTS 'W3b' |

### USB, Type-C and Thunderbolt

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| USB 2/3 host on the Type-C ports, hot-plug, PD | three USB4 ports, 10 Gb/s USB3, PD source/sink | Left-front (SuperSpeed) and right (10 Gb/s) ports work with hot-plug; the left-back port (ATC0) carries the CDC-EEM tether gadget and is refused as host by policy; one hub enumeration failure in ~12 boots; 70 s replug delay unexplained; PD role swap untested | **partial** | Asahi (7.0 upstream), Aurora (J616s all three ports #403) | ATC0 as a host port (retire the tether, m1n1 without the gadget, DT opt-in); replug delay; PD role swap/charging on the right port | M | Losing the tether removes the remote-recovery path; attended | aurora-silicon/linux #939, #489, #487 | - | contrib/pending/peripherals/REPORT.md item 9; contrib/pending/followups/USB2-REARM.md |
| Thunderbolt 5 / USB4 (PCIe and DP tunnels, docks, eGPU-class devices) | TB5 80 Gb/s on all three ports, retimers | DT, kernel and m1n1 patches on Aurora's #946 base; the T0 boot hung in kernel init (deferred probe waiting forever) and needed a power cycle; bisect ladder (K0, D1-D3) built, attended only; right port (ATC2) only by design | **blocked** | Asahi (WIP on M1/M2), Aurora M4 (TB host + DP tunnels merged #843-#957, J616s left-back #1220); T6050 right port PR #946 open | Probe timeout and watchdog in init, the bisect, then the full T0; later the other two ports and the retimers (uatcrt0-2 on i2c6, no node); TB5 speeds unverified anywhere on Linux | L | Attended only (hangs in init; power cycle) | aurora-silicon/linux #946, #1126 | #1 | RESULTS 'TB-T0'; contrib/pending/thunderbolt/T0-HANG-ANALYSIS.md |
| USB gadget tether (CDC-EEM) for recovery and development | n/a | Works on ATC0 (the development lifeline); conflicts with usb.host on that port | **works** | Asahi (m1n1 proxy over USB) | A decision for end users: no tether, all three ports as host | - | - | - | - | docs/boot-and-recovery.md |

### Camera, Neural Engine and media engines

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Front camera (ISP) capture, Center Stage, privacy indicator | 12 MP Center Stage camera, HDR, exclave-hosted ISP | I1 passed (three ISP DARTs bind, 8/8 power domains); I2 (firmware handshake, /dev/video0) not run: the firmware segment pre-check failed and the T6050 apple-isp alias was missing; ADT marks the ISP exclave-assigned with no_ps power domains, so AP-side control is the open question | **prepared** | Asahi (M1/M2 apple-isp), Aurora (J616s #384, J700; J714c front camera omacom #422 open) | I2 attended run with m1n1 0029 (ISP firmware hand-off); if the exclave blocks it, protocol RE; libcamera/PipeWire integration; Center Stage is software (not planned) | M (if the AP path works) / XL (if exclave-only) | Never defeat the indicator; attended | omacom/linux-aurora #422; aurora-silicon/linux ISP T6040 path | #2 | RESULTS 'CAMERA I1'; contrib/pending/camera/TEST-PLAN.md; contrib/pending/isp-tb/REPORT.md |
| Neural Engine (ANE) for Core ML / MLX workloads | 16-core ANE, exclave-hosted firmware | Observer-only kernel + m1n1 patches bind apple,t6050-ane for a read-only probe; not booted; no T6050 ANE PR anywhere | **prepared** | Asahi (out-of-tree eiln/ane M1/M2), Aurora (accel/ane H13-H17 merged for M1..M4 Pro and Neo; omarchy-ane userspace) | Observer boot A, then the H17 (M5) platform entry in accel/ane, iBoot-preloaded firmware hand-off, PWGATE/reset values, mil-hwx-compiler support for the M5 ANE | L | none (observe) / power-domain hangs later | aurora-silicon/linux accel/ane (#920 family) | #23 | contrib/pending/ane/patches/; upstream aurora.md ANE row |
| Hardware video decode (AVD: H.264, HEVC, VP9, AV1) | yes | AVD (T8142 generation, avd-version 4) and JPEG patches + DT nodes prepared, modules built, test script ready; not booted; VP pool size unknown; open AVD firmware (avd-fw) to be built | **prepared** | Asahi (M1/M2 linux-asahi + asahi-va-driver), Aurora (M1/M2/M4 Pro, many PRs; libva-v4l2_request) | Boot A with the modules, firmware build, decoder loop test, VA-API in the browser | M | none | aurora-silicon/avd-fw; aurora-silicon/linux AVD PRs (#702/#703/#712/#1116) | #24 | README video row; contrib/pending/video/test/video-test.sh |
| JPEG engine (two instances) | yes | Patch + DT node prepared with the AVD set; not booted | **prepared** | Aurora (JPEG admit on M4 Pro) | Boot with video.decode; a V4L2 m2m consumer | S after decode | none | video.decode | #24 | contrib/pending/video/patches/ |
| Hardware video encode (AVE2) | H.264/HEVC encode | Probe-only driver family; the feasibility study for the J716s is being written in contrib/pending/video/encode/ (in study) | **in study** | Aurora (encode merged for the Neo and M4 Pro: #615, #748), Asahi TBA | Per the study (not redone here): T6050 AVE2 register map, firmware, V4L2 stateful encoder | XL | none | aurora-silicon/linux #615/#748 | - | contrib/pending/video/encode/ (in study); README |
| ProRes engine (apr) | ProRes RAW/4444 encode+decode | Only a DT binding; the feasibility study is being written in contrib/pending/video/prores/ (in study) | **in study** | Aurora (ProRes on the Neo #835 and M1 Pro #1164) | Per the study: T6050 apr port of the Aurora driver, firmware, a consumer (FFmpeg) | L-XL | none | aurora-silicon/linux #835/#1164 | - | contrib/pending/video/prores/ (in study); README |
| Scaler/rotator (scaler0/1, AppleM2ScalerCSC) | used by the camera/video pipelines | No Linux driver anywhere | **missing** | nobody | Everything (low value: the GPU covers it) | XL | none | - | - | macOS kextstat AppleM2ScalerCSCDriver; ADT scaler nodes |

### Security: SEP, Touch ID, NVRAM, secure boot

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Touch ID (SEP + Mesa sensor) with fprintd/PAM | Touch ID, Apple Pay, SEP-sealed keys | Nothing: no sep/dart_sep/spi2/mesa nodes, no T6050 profile in sep.rs; m1n1 still queries the SEP RNG at boot (Aura skips it on M2+ to keep iBoot's warm registration); feasibility study written (contrib/pending/platform/touchid-sep/FEASIBILITY.md) | **in study** | Aurora (M1 j313 enrol/verify/sudo/lock; M4 Pro J616s #498/#545; Neo; libfprint fork + aurora-sep-userspace), Asahi TBA | Ladder from the study: (0) stop the m1n1 SEP RNG query, (a) sep node + T6050 profile read-only, (b) spi2 + pinctrl_nub + mesa sensor, (c) xART/keybag path + libfprint, (d) survive reboot/sleep | L | Step (c) writes persistent SEP state (xART, Linux keybag); keybag reset is irreversible for Linux enrolments; keep a macOS enrolment and password; attended | aurora-silicon/linux sep.rs, keybag.rs; aurora-sep-userspace; omarchy-pkgs libfprint-git | - | contrib/pending/platform/touchid-sep/FEASIBILITY.md |
| SEP-backed disk unlock, hardware RNG, /dev/sep-key | FileVault, Data Protection | None (follows sec.touchid step (a)) | **in study** | Aurora (SEP-sealed LUKS2 in aurora-xart for the Neo; #1196 /dev/sep-key open) | The same SEP bring-up, then the aurora-xart tooling | L | As sec.touchid (c) | aurora-silicon/aurora-xart | - | contrib/pending/platform/touchid-sep/FEASIBILITY.md section 5 |
| NVRAM read | nvram(8) | spi-nor on the boot NOR, mtd2 = nvram (768 KiB, 12 banks, v3) parsed read-only; dump stays on the machine | **works** | Asahi, Aurora | asahi-nvram packaged | S | - | - | - | RESULTS 'NVRAM-RO' |
| NVRAM write (next-boot target, boot-args, persistent variables) | nvram(8), bless | Driver board row for the J716s written (JEDEC id known, block-protect bits unknown: fails closed), tools ready; no write done | **prepared** | Asahi (M1/M2), Aurora (J616s #674, J700 #673) | Attended first write of alt-boot-volume with the probe passing; then package aurora-bless | S | A wrong write to the boot NOR is DFU-recoverable at best; the driver verifies and latches read-only on any failure; attended | aurora-silicon/linux spi-apple-qspi | #4 | contrib/pending/nvram/REPORT.md |
| Secure boot / signed kernels / measured boot | Full Security, SSV, SPTM-enforced | Reduced-security stub signs only m1n1; the kernel is unsigned; no measured boot; SPTM binds EL1 to Apple-signed kernels, which is why Linux runs at EL2 | **not planned** | nobody (Asahi/Aurora run unsigned kernels under Permissive Security) | Apple would have to sign third-party kernels; no path | - | - | - | - | omacom/linux-aurora #293 (SPTM finding); docs/smp-t6050-raw-path.md |
| Hardware watchdog and RTC clock | yes | apple_wdt drives restarts and the boot watchdog (systemd feeds it); rtc-macsmc sets the clock at boot; no alarm (see sleep.rtc-wake) | **works** | Asahi (5.17 / 7.0 upstream), Aurora | - | - | - | - | - | machine.yaml boot.loop-safety |

### Virtualization

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| KVM guests (Linux at EL2, GICv3 emulation, nested) | Virtualization.framework (has-virtualization) | KVM built in and kvm-arm.wfi_trap_policy=trap on the command line; no guest has been booted; no record of the AIC/vGIC quirks on T6050; 16 K pages mean 4 K guests need muvm-style VMs | **missing** | Asahi (KVM on M1/M2 works; muvm for 4 K), Aurora (Aura monitor with nested virt; #901/#985 EL2 fixes merged) | One QEMU/crosvm guest boot, vGIC check, then muvm/FEX for x86 (omarchy-steam-fex) | S (test) / M (muvm) | none | aurora-silicon/linux #901, #985 | - | contrib/validated/aurora/tools/modules/MODULES.md:48; contrib/pending/wfi-idle/REPORT.md |
| x86 apps and games (FEX, muvm, Steam) | Rosetta 2, Game Porting Toolkit | Not installed; qemu-binfmt deferred | **missing** | Asahi (muvm + FEX), Aurora/Omarchy (omarchy-steam-fex, aurora-steam-native) | virt.kvm, then the packages | S after KVM | none | omarchy-pkgs omarchy-steam-fex | - | upstream omarchy-pkgs.md |

### Sensors and the always-on processor

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Ambient light sensor (VD6286 on the AOP): auto-brightness, True Tone, keyboard light | auto-brightness, True Tone | Nothing binds: no AOP DT children; the Aurora Rust AOP/ALS drivers match T8103..T6020 only; needs the per-unit apple/aop-als-cal.bin from macOS ioreg; untested VD6286 path on this AOP firmware (routes through an exclave mailbox) | **missing** | Asahi (aop.rs + aop_als on M1/M2), Aurora (ALS CCT #667/#779 on M3/M4; kbd-light daemon) | Kernel 0001-0003 + m1n1 0028 (peripherals, written), a T6050 AOP match, the calibration extraction step in the installer, then iio consumers (auto-brightness in the shell) | S-M | A lock-up loses audio for that boot (the AOP also carries the mics) | aurora-silicon/linux aop.rs | - | contrib/pending/peripherals/REPORT.md item 3; contrib/pending/platform/REPORT.md section 2 |
| Accelerometer, gyroscope, lid angle (Mogul on i2c5), device motion | sudden motion, lid-angle hinge features | Nothing binds; calibration for accel/gyro is in the ADT (m1n1 0028 ports Aura's dt_set_aop_motion_cal); lid angle needs none | **prepared** | Aurora (accel/gyro #680/#745, lid angle #665) | Same AOP bring-up as sensors.als; iio-sensor-proxy for screen rotation (low value on a laptop) | S after ALS | as sensors.als | - | - | contrib/pending/peripherals/REPORT.md item 3 |
| Lid (hall) sensor | SMC wake event (no hall HID service) | Lid close/open events through macsmc-input with the MSLD confirm; works | **works** | Asahi, Aurora | - | - | - | aurora-silicon/linux #1160 | - | RESULTS 'N1-SLEEP'; macOS ioreg (lid = SMC event) |
| Voice trigger / always-listening (AOP VoiceTrigger, LPMic), proximity, NFC (Stockholm on aop-spmi0) | 'Hey Siri', Apple Pay NFC | None; no proximity sensor exists on this machine; NFC is Apple Pay only | **not planned** | nobody | - | - | - | - | - | macOS kextstat AppleAOPVoiceTrigger; ADT aop-spmi0 |

### Omarchy desktop glue

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| Hyprland session on Omarchy 4.5 (two-card: GPU renders, DCP scans out) | n/a | Works; software session as fallback; m5pro-rescue for recovery; Quickshell needed qt6-imageformats and imagemagick by hand | **works** | Omarchy on M1-M3 (one card) | Two-card session upstreamed into omarchy-mac (AQ_DRM_DEVICES, render node), missing package dependencies filed | S | - | omacom/omarchy-mac-pkgs | #21, #30 | contrib/validated/desktop/omarchy-upgrade-REPORT.md |
| Screen lock on lid/sleep, idle lock, fingerprint unlock | yes | hyprlock/hypridle present; the account had no password until 2026-11-08, so the idle lock was off; not re-verified since; fingerprint unlock needs sec.touchid | **partial** | Omarchy M1-M3 (lock + Touch ID via libfprint-git on Aurora) | Lock-on-sleep verified with logind drop-ins (stage S after S4 passes 3x); fprintd later | S | Locked out if the lock misbehaves while remote; attended | - | #8 | contrib/validated/desktop/omarchy/REPORT.md; contrib/pending/dt-prep/s2idle/SLEEP-PLAN.md line 49 |
| Wi-Fi/Bluetooth menus (NetworkManager, bluetoothd) in the shell | yes | NetworkManager switched on 2026-11-08 with pmf=1; Bluetooth menu untested (no pairing yet) | **partial** | Omarchy | BT pairing UX test; audit of the omarchy-mac Wi-Fi backend rule (iwd vs wpa_supplicant) for the N1 | S | none | - | #9, #21 | RESULTS 2026-11-08 desktop fixes |
| Brightness/volume/media keys, Mission Control gesture, three-finger swipes | yes | Keys bound; Mission Control overlay + Ctrl+= / Ctrl+arrows as a local plugin (thumbnails off, ScreencopyView unvalidated on the Aurora GPU); theme picker previews blank on the software renderer | **partial** | Omarchy | Live thumbnails once screencopy is validated; picker previews on the GPU session; upstream the plugin | S | none | - | #37, #38 | contrib/validated/desktop/omarchy-fixes/2026-11-08-mission-control.md |
| Audio profile install, speakersafetyd/speakerguardd service, volume ceiling in the UI | n/a | speakersafetyd active, bring-up sink; the J716 profile staged; packages not in Arch ARM repos (local build script) | **partial** | Omarchy/Aurora (aurora-audio, speakerguardd packaged) | J716 graph into aurora-audio + alsa-ucm-conf-aurora, bankstown-lv2 packaged | S-M | as audio.speakers | omacom/omarchy-pkgs aurora-audio | #7 | contrib/pending/audio/aurora/build-audio-pkgs.sh |
| Battery indicator, charge-limit toggle, power profiles | yes | upower reads macsmc-power; omarchy-battery-charge-limit not installed (omarchy-mac held back); power-profiles-daemon has no platform profile on this SoC | **partial** | Omarchy (omarchy-mac charge limit; Aurora upower fork) | Install/vet omarchy-mac rules; a platform_profile driver (Aurora #481 thermal profile) for power modes | S | none | omacom/omarchy-mac-pkgs | #21 | upstream omarchy-pkgs.md omarchy-mac |
| External display handling in the shell (scaling, hot-plug, lid-closed mode) | yes | Nothing until display.external; the DCP 'clamshell value is 1' log line may blank the internal panel when an external one attaches (unchecked) | **missing** | Omarchy/Asahi | display.external first; clamshell behaviour check | S after display.external | none | display.external | #20 | contrib/validated/display/stage-c-analysis.md row 18 |
| omarchy update with the Aurora kernel/Mesa packages | Software Update | The kernel is a hand-built payload on the ESP; /opt/mesa-aurora is hand-built; IgnorePkg + a pacman hook guard the boot chain; omarchy update must not run unattended (Mesa/LLVM could break /opt/mesa-aurora) | **missing** | Omarchy (linux-aurora 7.2.11 + mesa-aurora packages, update verify in omarchy-mac-boot) | A linux-aurora package with the 7.3 base and the T6050 DTBs; a mesa-aurora with G17 support; the payload update hook (m5pro-update-payload / A/B update) packaged | M | A bad update = unbootable without the A/B fallback | omacom/linux-aurora #413; omacom/omarchy-pkgs | #21, #27 | contrib/validated/desktop/omarchy-upgrade-REPORT.md; contrib/distro/GAPS.md #5, #9 |

### Distribution: a stranger installs it

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| The Omarchy macOS installer supports Mac17,8 (J716s) | n/a | omarchy-mac-installer refuses M4+ ('This Mac isn't supported yet'); the J716s path is two reviewed-by-hand sudo scripts plus a tether host and per-desk tools | **missing** | Asahi (M1/M2 installer), Omarchy (M1-M3, Neo) | Catalog entries (DEVICES, CHIP_MIN_VER = 27.3 beta 1 stub gate, BOARD_STAGE1/2), the A/B stage-1 as a stage-1 kind, the N1 FTAB firmware step, qualification phase (fresh install, ceremony, LUKS, A/B update, recover) | L | Live APFS resize; backup prompt | omacom/omarchy-mac-installer; omacom/linux-aurora #413; omacom/m1n1 #30-#37 | #27, #28 | contrib/pending/installer/PLAN.md; contrib/distro/GAPS.md section A; upstream omarchy-pkgs.md installer |
| Firmware extraction from the user's own macOS (N1 FTAB, ALS calibration, ISP/AOP/DCP/GPU firmware, syscfg) with no per-unit data in any repo | n/a | The per-unit N1 FTAB (~31 MB) is pulled by hand from the machine's macOS; GPU/DCP firmware come from the paired stub; PHY tunables are generated by m1n1 from the ADT (no per-unit values in the DT); ALS calibration extraction not written; nothing automated | **partial** | Asahi (asahi-installer asahi_firmware/*.py), Omarchy (omarchy-restore-image + vendorfw, omarchy-aurora-firmware admission order) | An FTAB extractor and a vendorfw layout in the installer/first boot; ALS cal extraction; the firmware-version pairing rule (stub = 27.3 beta 1) documented for users; omarchy-aurora-firmware branch for the J716s | M | Firmware is personalised per unit and must never be published | omacom/omarchy-mac-installer; omarchy-aurora-firmware | #27 | contrib/pending/installer/PLAN.md phase 4; contrib/pending/wireless/N1-KERNEL-TRAIN.md |
| Packages: linux-aurora with the T6050 DTBs and the 7.3 base, m1n1 with the T6050 patches, mesa with G17, aurora-audio J716 profile, aurora-bless, libfprint | n/a | omarchy-pkgs linux-aurora is 7.2.11 without T6050 DTBs; m1n1-aurora lacks #30-#37; mesa-aurora has no G17; aurora-audio has no J716 graph; everything here is built on the Studio from worktrees | **missing** | Omarchy (all of these packaged for M1-M3/Neo) | Merge of #413 and the m1n1 stack, a 7.3-based linux-aurora, mesa#194 in mesa-aurora, the audio profile PR, CI that builds aarch64 | M (after the upstream merges) | none | omacom/linux-aurora #413; omacom/m1n1 #30-#37; aurora-silicon/mesa #194; omacom/omarchy-pkgs | #27 | upstream omarchy-pkgs.md; contrib/distro/GAPS.md #5, #9, #10 |
| `aura`/`aurora` CLI: update m1n1, recover, switch startup disk, refresh firmware after a macOS update | n/a | Hand scripts (esp-put.sh, mk-daily.py, m5pro-rescue); stub refresh after a macOS update is manual and needs a ceremony; firmware pairing must be re-done | **missing** | Asahi (asahi-scripts: update-m1n1, asahi-fwupdate, asahi-diagnose), Aurora (aura recover, aurora-diag) | Packaged update/recover tooling that knows the A/B stage 1 and the ESP policy; an installer 'Refresh' action (recreate -> firmware -> known-good stage 1) | M | Stub refresh can break GPU/DCP if the firmware changes | aurora-silicon/aura, asahi-scripts | #27 | contrib/distro/GAPS.md #20, #22; contrib/pending/installer/PLAN.md |
| Everything upstream (no private series needed to build the kernel) | n/a | Merged: #1082, #1083, #1084, #1167 (J716s DT). Open: #1152, #1160, #1173, #1174, #1182, #1183, m1n1 #65, mesa #194, omacom #413, m1n1 #33-#37, omarchy-mac-pkgs #103. Series 0059-0094 (sensors, right port, audio 0067-0083, netfilter, PCIe adopted port) mostly have no PR; aurora m1n1 branches pr/t6050-bringup, -gpu-handoff, -display not opened | **partial** | - | PRs for the audio series (needs edimoldovan's AOP sign-offs), the right-port/sensor DT additions, the m1n1 branches after attended boots; dtbs_check on the series tip; the apple,internal-panel binding | M (ongoing) | none | maintainers' review queue | #25, #26, #27 | contrib/validated/aurora/prs/REPORT.md; contrib/validated/aurora/series/UPSTREAM-NOTES.md |
| Public, evidence-gated status (M4Plus-Linux tracker) and omacom's per-Mac test report | n/a | rolotrealanis98/m4-m5-linux published with the J716s YAML and 30 result logs; transfer to omacom pending; omacom/linux-aurora #423 carries the status table | **works** | Asahi docs feature-support pages; Aurora support.json (M5 rows owner-asserted, not tested) | Transfer to omacom; J714c/J714s owners confirm their drafts; correct the Aurora site's J716s claims (fan control, HDMI, RT) | S | none | omacom | #28, #29 | contrib/community/SHARED-REPO-PLAN.md; upstream aurora.md conflicts |

### SoC blocks seen in the ADT with no Linux counterpart

| Capability | What macOS does | Linux today on the J716s | Status | Who has it elsewhere | What is missing | Effort | Risk | Dependency / upstream | Tracker | Sources |
|---|---|---|---|---|---|---|---|---|---|---|
| PMGR power domains: 661 ADT power-state entries vs 33 pwrstate nodes in the DT | every block power-gated | Only the domains the booted drivers need are described; the rest stay as iBoot left them (pd_ignore_unused/clk_ignore_unused); unused blocks cannot be powered down | **partial** | Asahi/Aurora describe most domains per SoC | A generated t6050-pmgr.dtsi from the ADT `devices` table (names only, no per-unit data) and a review of which domains may be gated | M | Gating a domain a coprocessor still uses hangs the bus (seen with sleep on T6050) | aurora-silicon/linux #490 (pmdomain), #1202 | - | scratchpad ADT summary (PMGR gap); contrib/pending/platform/REPORT.md s2idle note |
| RAS/EDAC: error-handler (36 sources), event-log-handler, MCC counters | AppleEverestErrorHandler, panic on uncorrectable | apple_soc_edac and mcc.c exist for earlier SoCs; no T6050 nodes; apple_soc_edac built =m, untested | **missing** | Aurora (apple_soc_edac, mcc.c) | DT nodes for error-handler/sources and mcc, a T6050 match, a test | S-M | none | - | - | ADT dt-coverage DRIVER-ELSEWHERE list |
| SIO DMA coprocessor, AUSS (USB audio offload), AES engine | SIO serves SPI/UART DMA and the TCON; AUSS offloads USB audio; AES for keystore ops | sio has a driver (apple-sio) but no T6050 node (spi-apple is PIO, so nothing needs it yet); AUSS and AES have no Linux driver anywhere | **missing** | Asahi/Aurora (sio on M1/M2 for the Touch Bar/TCON); AUSS/AES nobody | sio node if a DMA consumer appears; AUSS/AES not planned (CPU does the work) | S / not planned | none | - | - | ADT dt-coverage NO-DRIVER list |
| Panel TCON (Parade DP855 on spi4), LCD PMIC/EEPROM, three display temperature sensors (TMP103), backlight IC on i2c7, sync-hub on i2c0 | DCP firmware drives them | All owned by the DCP firmware; Linux talks only to the DCP; no node for spi4/i2c7/i2c0 children | **not planned** | nobody (same on every Asahi/Aurora machine) | Nothing unless panel temperature readout is wanted (tmp103 behind the TCON path) | - | Driving them directly fights the DCP firmware (rejected) | - | - | contrib/pending/dcp/REPORT.md decision 4; ADT NO-DRIVER list |
| DisplayPort input muxes (atc*-dpin0..3), DP crossbars (atc0/2-dpxbar), USB-C retimers (uatcrt0..2 on i2c6), pcon0 on i2c8 | route any DCP pipe to any port; retimers for TB5/DP2.1 signal integrity | atc2 crossbar node exists but its t6050 compatible matches no driver; dpin muxes and retimers have no Linux driver anywhere | **missing** | Asahi/Aurora (apple-display-crossbar for M1/M2; retimers firmware-managed there) | Crossbar driver match, dpin description, retimer handling for TB5 speeds (protocol unknown) | M (crossbar) / XL (retimers) | none | display.external, usb.thunderbolt | #20 | ADT NO-DRIVER / DRIVER-ELSEWHERE lists |
| aod2 (always-on display coprocessor), mtp-aop-mux, BTM battery/thermal monitor on nub-spmi0, fillmore radio node | internal services | No driver, no node | **not planned** | nobody | - | - | - | - | - | ADT NO-DRIVER list |
| m1n1 ADT lookups that miss on T6050 (wlan, spi1/spinor/anvram, pmp/iop-pmp-nub) | n/a | m1n1 looks for /arm-io/wlan (here centauri: Wi-Fi calibration not copied), /arm-io/spi1/spinor/anvram (here under qspi: 'nvram partition not found', harmless because the DT is static) and /arm-io/pmp/iop-pmp-nub (here pmp0: bails 'not found') | **partial** | Asahi m1n1 (paths fit M1-M4) | Path fixes in m1n1 kboot.c for the T6050 names (centauri, qspi, pmp0); then PMP hand-off becomes possible | S | none | omacom/m1n1 #30 stack; aurora-silicon/m1n1 | - | scratchpad ADT summary 'm1n1 lookups that miss' |
## 4. Hardware inventory: every ADT node under `/arm-io` and at the top level, classified

Method: the runtime ADT of this unit was parsed node by node (626 inventory rows; 608 classified after folding 156
`iommu-mapper` nodes into `iommus=` and 23 RTKit `iop-nub` nodes into their coprocessor). Each node with a
`compatible` was matched against the daily kernel tree (`wt-daily-dcp`, branch `j716s-daily-dcp`: the compiled
`t6050-j716s.dts` has 267 nodes, 167 with a compatible), against every other `t6050-j716s*.dts` in the worktrees
(`wt-tb`, `wt-video`, `wt-isp*`, `wt-ane`, `wt-extdisp`, `wt-periph`, `wt-platform`, old bases), and against the
driver match tables. DRIVEN = DT node at that register address and a driver that matches one of its compatibles;
PREPARED = DT node only in a test worktree; DRIVER-ELSEWHERE = a family driver exists but no T6050 node or match;
NO-DRIVER = nothing in any Linux tree; FIRMWARE-ONLY = pmgr placeholders, debug/trace, memory-controller internals,
exclave plumbing. Only names, compatibles, property names and `reg` offsets/sizes were read into the working files;
none of those files is committed.

| Class | All rows | `/arm-io` only |
|---|---|---|
| DRIVEN (15 of them `status = "disabled"` in the merged DT) | 109 | 80 |
| PREPARED (test worktree only) | 43 | 42 |
| DRIVER-ELSEWHERE | 125 | 119 |
| NO-DRIVER | 45 | 43 |
| FIRMWARE-ONLY / not for Linux | 286 | 268 |
| Total | 608 | 552 |

PMGR: the ADT `devices` table of `/arm-io/pmgr` names 661 power states; the DT describes 33 `apple,t6050-pmgr-pwrstate`
nodes (plus 4 pmgr banks and the GPU's). The rest run as iBoot left them.

### 4.1 No Linux driver anywhere (45 nodes)

| ADT node(s) | What it is | Gap row |
|---|---|---|
| `i2c5/mogul-las` | lid-angle / light sensor (Mogul) on I2C, read by the AOP | sensors.motion |
| `i2c7/disp-bklt` | display backlight IC (mini-LED chain), DCP-owned | soc.panel-tcon |
| `i2c0/sync-hub-config`, `i2c0/sync-hub-prog` | display sync hub, DCP-owned | soc.panel-tcon |
| `iop-voicetrigger-controller` (+ `audio-vt-device`), `aop/iop-aop-nub/aop-voicetrigger` | voice trigger | sensors.voice-trigger |
| `i2c4/sd-card` | SD reader sideband | storage.sdxc |
| `i2c6/uatcrt0..2` | USB-C/TB retimers | soc.dp-muxes-retimers |
| `i2c8/pcon0` | HDMI protocol converter / power controller | display.hdmi |
| `spi4/dp855` + `lcd-pmicwp`, `lcd-pmic`, `lcd-sswp`, `lcd-ss`, `tcon-registers`, `lcd-eeprom` | Parade DP855 eDP TCON and LCD parts, DCP-owned | soc.panel-tcon |
| `mtp-aop-mux` | HID transport mux between MTP and AOP | soc.aod-mux-btm |
| `aod2` | always-on display coprocessor | soc.aod-mux-btm |
| `atc0..2-dpin0..3` (12) | DisplayPort input muxes (DCP pipe -> PHY) | soc.dp-muxes-retimers |
| `aes` | AES engine | soc.sio-auss-aes |
| `auss-cpu0`, `usb-auss0` | USB audio offload subsystem | soc.sio-auss-aes |
| `smc/iop-smc-nub/smc-pmu`, `smc-charger-util*` (4) | SMC battery/charger endpoints (served in practice through the `smc` MFD cells, no node of their own) | smc.battery |
| `nub-spmi0/btm` | battery/thermal monitor on SPMI | soc.aod-mux-btm |
| `aop-spmi0/stockholm-spmi` (+ `stockholm`) | NFC | sensors.voice-trigger |
| `aop-spmi0/spmi-wifibt` | Wi-Fi/BT PMIC rail | wifi.basic (firmware-managed) |
| `scaler0`, `scaler1` | media scaler/rotator | video.scaler |
| `fillmore` | radio-related node (BT/UWB) | not planned |
| `/buttons` | button descriptor (consumed via SMC/MTP) | input.touchid-button |
| `/port-magsafe3-1` | MagSafe port component | smc.magsafe |

### 4.2 Driver exists elsewhere, no T6050 wiring (125 nodes, grouped)

| ADT node(s) | Linux driver family | Gap row |
|---|---|---|
| `i2c5`..`i2c8` | `i2c-pasemi-platform` | sensors.motion, display.hdmi, soc.dp-muxes-retimers |
| `spi2/mesa` | `soc/apple/sensor_shim.c`, `apple,mesa-fingerprint` binding | sec.touchid |
| `spi4/display-temp-sens1..3` | `hwmon/tmp103` | soc.panel-tcon |
| `apcie0/pci-bridge1` | `pcie-apple` | storage.sdxc |
| `apciec0`, `pcic0..2-bridge` | `pcie-apple` (tunnelled PCIe) | usb.thunderbolt |
| `acio0`, `acio-cpu0`, `acio-phy-cpu0` | `thunderbolt/apple.c`, `soc/apple/mailbox.c` | usb.thunderbolt |
| 17 DARTs (`dart-apciec0`, `dart-acio0..2`, `dart-sio`, `dart-pmp0`, `dart-sep`, `dart-auss0`, `dart-disp0-isoc`, `dart-dispext0..3-isoc`, `dart-scaler*`, `dart-apr1`) | `apple-dart` | follows the owning block |
| `display-crossbar0`, `atc0-dpxbar`, `atc2-dpxbar` | `mux/apple-display-crossbar` (atc2 node exists, compatible unmatched) | display.external |
| `atc0..3-dpphy`, `dptx0/1-aux` (+ core/ufp) | `phy/apple/dptx`, `atc-t6050-dp` | display.external, display.hdmi |
| `mcc` | `soc/apple/mcc.c` | soc.edac |
| `error-handler` + 36 sources, `event-log-handler` | `edac/apple_soc_edac` | soc.edac |
| `aop/iop-aop-nub/als`, `accel`, `gyro`; `aop2` | `iio/common/aop_sensors`, `soc/apple/aop.rs` | sensors.als, sensors.motion |
| `sio`, `sio-dma` | `dma/apple-sio` | soc.sio-auss-aes |
| `pmp0` | `soc/apple/pmp.rs`, `pmdomain/apple/pmp-report` | power.pmc, soc.m1n1-adt-misses |
| `sep` | `soc/apple/sep.rs` | sec.touchid |
| `dp2hdmi-gpio0`, `/port-hdmi0` | `drm/apple/dcp-hdmi` | display.hdmi |
| `nub-spmi2/3`, `aop-spmi0`; `spmi-mosquitoM0`, `spmi-abbeyF1/F2` | `spmi-apple-controller`, `nvmem/apple-spmi-nvmem` | sleep.rtc-wake |
| `nub-spmi-a0/hpm0`, `hpm5` | `usb/typec/tipd` | usb.host (ATC0), smc.magsafe |
| `dp-audio0..4`, `admac-disp0`, `admac-dispext0..3`, `admac-*-ced-ssw`, `admac-leap-ns/-s` | `drm/apple`, `dma/apple-admac` | audio.hdmi, audio.mic |
| `dispext0..3` | `drm/apple/dcp.c` | display.external |

### 4.3 Prepared in a test worktree only (43 nodes)

`isp0` + `dart-isp0` (wt-isp/isptb); `ane0` + `dart-ane0` (wt-ane); `avd0`, `ave0`, `apr0`, `jpeg0/1` + DARTs
(wt-video; AVD/JPEG/ProRes drivers are in the daily tree but bind no T6050 compatible, the AVE driver only in wt-video);
`acio1/2`, `acio-cpu1/2`, `apciec1/2` + DARTs (wt-tb); `dcpext1..3` + DARTs, `atc1-dpxbar`, `atc3-dpxbar` (wt-extdisp);
`atc-phy0` (wt-platform); `pcie-sdreader`, `/pcie-sdreader-helper`, `dart-apcie1` (wt-periph); `i2c0`, `i2c4`, `spi2`,
`spi4`, `uart0`, `dockchannel-uart`, `nub-gpio0` (old-base trees).

### 4.4 Blocks the brief asked about that this ADT does not have

No `hall`, `prox`, `fan*`, `spu`, `sdxc`/`sdhci`, `mcdp*`, `lpdptx`, `ipc`, `nvmem`/`efuse` or `cpm*` node. What
stands in: the lid is an SMC wake event (no hall HID service in macOS either), fans are SMC keys with no fan service,
the ALS and motion sensors are AOP services, the SD reader is a PCIe device (`pci17a0,9755`) behind `apcie0/pci-bridge1`,
HDMI is `atc3` + `dp2hdmi-gpio0` + `pcon0` (no MCDP29xx), the retimers are `uatcrt*`, USB4 is `acio*`, `cpm` appears
only as the `/arm-io` property `cpm-impl` and nine PMGR names (`MCPM0`...). `rtbuddy` is only a compatible on 22
`iop-nub` nodes. Top level: `/backlight-override` (40 calibration property names, per-unit), `/exbrightpil`,
`/hibernate`, `/hib-exclave-watchdog`, `/port-usb-c-1..3` (`dock,usb-c`), `/product` (`camera`, `audio`), `/sacm`,
`/iboot-syscfg`, `/ced-ssw`, `/socd-trace-ram`.

### 4.5 m1n1 lookups that miss on this ADT

`/arm-io/wlan` (the node is `centauri`, so no Wi-Fi calibration is copied), `/arm-io/spi1/spinor/anvram` (here
`/arm-io/qspi/spinor/anvram`; harmless, the DT partition is static) and `/arm-io/pmp/iop-pmp-nub` (here `pmp0`;
`kboot.c` bails "not found", so no PMP hand-off is possible until the path is fixed).

## 5. Proposed priority order for "full support", with the reasoning

Ordering rule: first what keeps a user's desktop alive, then what the hardware already has patches for and only
needs a sitting, then the long items with an upstream precedent, then research. Attended items are grouped so one
sitting covers several.

| # | Gap (row id) | Why now | Effort | Needs hands? |
|---|---|---|---|---|
| 1 | GPU recovery that keeps the compositor alive (gpu.recovery) and the display-path memory runaway (mem.zram) | The one bug that still takes the desktop down for an ordinary user (Chrome, Electron); the DCP daily was demoted once for it; the 2000 us pause bound has one clean run and needs a loop boot | M | no (loop) |
| 2 | Speaker profile, sense fix, lifted ceiling (audio.speakers, desktop.audio-ui) | Speakers at -30 dB are the most visible daily limitation; the J716 profile and the listening tool are ready; the 4x sense read must be fixed before any ceiling change | S + attended listen | yes |
| 3 | The attended sitting bundle: lid sleep on the current daily (sleep.s2idle), headphone jack (audio.jack), Bluetooth pairing (bt.pairing), discharge/MagSafe events and the overnight battery drain (smc.battery, sleep.power), brightness by eye, F6, palm/thumb numbers, power-off on the Aurora kernel | All S, all need a person; one evening closes eight tracker issues and produces the first sleep-power number | S each | yes |
| 4 | Thunderbolt/USB4 on the right port (usb.thunderbolt) | Unlocks docks, DP tunnels, external displays and the J616s-class port story; the T0 hang analysis names the suspects and the loop safety now covers a hung init; attended because the failure mode was a power cycle | L | yes |
| 5 | External displays: DP alt mode, then HDMI with audio (display.external, display.hdmi, audio.hdmi, desktop.external-displays-shell) | The biggest Asahi/Aurora feature the J716s lacks; Aurora's dptx/crossbar/dcpext work is the precedent; the ADT shows four dispext pipes and the dpin/dpxbar muxes have no driver | M-L | yes |
| 6 | NVRAM write and startup-disk switching (nvram.write, boot.macos-switch) + stage-1 0017 (boot.ab) in the same 1TR ceremony | Getting back to macOS without the power-hold menu is a daily-use need; the driver fails closed; stage-1 0017 removes the counted-restart fallback | S + ceremony | yes |
| 7 | Installer and packages for a stranger (dist.installer, dist.firmware, dist.packages, dist.aurora-cli, desktop.update-path) | Nothing above reaches another J716s owner until omarchy-mac-installer accepts Mac17,8 with a 27.3-stub gate and an N1 FTAB step, and omarchy-pkgs ships a 7.3-based linux-aurora with the T6050 DTBs and a G17 mesa; depends on #413 and the m1n1 stack merging | L (mostly upstream review) | no |
| 8 | Power: cpufreq measurement + T6050 binding (cpu.cpufreq), PMC/CLPC control T3-T5 (power.pmc), thermal zones A/B (power.thermal), platform profile for power modes (desktop.battery-ui) | Closes the measurable half of the 2x power gap and gives memory bandwidth back; T3 is attended once | S-M | T3 yes |
| 9 | Camera I2 and onward (camera.isp) | Patches and m1n1 hand-off exist; the exclave question is answered by one attended boot; a camera is expected on a laptop | M (or XL if exclave-only) | yes |
| 10 | Video decode + JPEG boot A (video.decode, video.jpeg) | Prepared, unattended-loopable, saves battery in the browser; Aurora firmware and VA-API exist | M | no |
| 11 | AOP sensors: ALS, motion, lid angle (sensors.als, sensors.motion, input.kbd-backlight auto, display.brightness auto) | Peripherals 0001-0003 + m1n1 0028 are written; needs the calibration extraction step for strangers; the one risk is the AOP sharing with the mics | S-M | loop + one attended |
| 12 | RTC wake alarm (sleep.rtc-wake) and SD reader (storage.sdxc) | Both are Aurora-precedent items with a clear path (SPMI gen-4 IRQ + Abbey RTC; port-1 training like the N1); rtcwake also enables timed wake for updates | M each | no |
| 13 | Touch ID / SEP (sec.touchid, sec.sep-keys) following the ladder in the feasibility study | Aurora has it on M1 and M4 Pro; step 0 (stop m1n1's SEP RNG query) is free and removes a risk; steps (a)-(b) are read-only; (c) writes persistent SEP state and is the only step with a real cost | L | (c) yes |
| 14 | ANE (ane), native GL as default (gpu.gl-native), GPU power/perf (gpu.pm, gpu.features), KVM test (virt.kvm, virt.x86) | Value items with upstream work to lean on (accel/ane, mesa#194/#139, Aura); none blocks daily use | M-L | no |
| 15 | Deep idle, deep sleep, hibernation, HDR/EDR, encode/ProRes, fan control (cpu.idle, sleep.deep, sleep.hibernate, display.hdr, video.encode, video.prores, smc.fans) | All XL or protocol RE; only Aurora's Neo/J616s work points the way (EL2 monitor, #906, #1208, #777/#789); fan control is likely impossible without an SMC key the T6050 lacks | XL | - |

Not planned, with the reason: secure boot with signed kernels (Apple-signed only), voice trigger/NFC/AOD/AUSS/AES
(no user value on Linux), the privacy-indicator brightness (exclave), direct control of the panel TCON/backlight IC
(fights the DCP firmware).

## 6. Where the data came from

- Repo: `README.md` (status table, 2026-11-08), `contrib/validated/integration/RESULTS.md`, `contrib/validated/aurora/STATE.md`,
  `contrib/validated/aurora/prs/REPORT.md`, `contrib/validated/aurora/series/UPSTREAM-NOTES.md`, every `contrib/pending/*/REPORT.md`
  and `TEST-PLAN.md`, `contrib/pending/peripherals/REPORT.md` (SD reader, AOP sensors, charging, hibernate), `contrib/pending/nvram/REPORT.md`,
  `contrib/pending/platform/REPORT.md`, `contrib/pending/followups/*.md`, `contrib/pending/dt-prep/s2idle/SLEEP-PLAN.md`,
  `contrib/pending/thunderbolt/T0-HANG-ANALYSIS.md`, `contrib/pending/gpu/GPU-RECOVERY-KILLS-COMPOSITOR.md` and `faults/HYPOTHESES.md`,
  `contrib/pending/installer/PLAN.md`, `contrib/distro/GAPS.md`, `docs/plan/ROADMAP.md`, `contrib/community/SHARED-REPO-PLAN.md`,
  `contrib/validated/desktop/*` reports, `contrib/pending/platform/touchid-sep/FEASIBILITY.md` (in study).
- Tracker: https://github.com/rolotrealanis98/m4-m5-linux (issues #1-#39, `machines/j716s/machine.yaml`, `schema/features.yaml`).
- Hardware: the private runtime ADT of this unit (local read; names, compatibles, property names, `reg` only) against
  `/Volumes/linux-cs/wt-*/arch/arm64/boot/dts/apple/t6050*`; the macOS 27.3 kextstat and ioreg planes (277 kexts, 656 DT nodes, names only).
- Asahi: https://github.com/AsahiLinux/docs/tree/main/docs/platform/feature-support (m1, m2, m5), `docs/sw/kernel-config.md`,
  AsahiLinux/linux branches `asahi`/`asahi-wip` driver directories, AsahiLinux/m1n1 #610/#631.
- Aurora: https://github.com/aurora-silicon/linux PRs (#826, #906, #1012, #1082-#1084, #1152, #1160, #1167, #1173, #1174, #1182, #1183,
  #1202, #1208, #946, #480, #939, #940, #639, #674, #732, #384, #779, #920, #1116, #615, #748, #835, #1164, #789),
  https://github.com/aurora-silicon/aurora-silicon.github.io `src/data/support.json` (J616s, J716s records),
  https://github.com/aurora-silicon/aura, aurora-sep-userspace, aurora-xart, avd-fw, kbd-light, mesa #139/#194, m1n1 #65.
- omacom: https://github.com/omacom/linux-aurora (#56, #293, #404, #413, #414, #422, #423), https://github.com/omacom/m1n1 (#30, #33-#37),
  https://github.com/omacom/omarchy-pkgs (`pkgbuilds/`: linux-aurora, m1n1-aurora, mesa-aurora, aurora-audio, speakerguardd, aurora-bless,
  omarchy-aurora-firmware, libfprint-git, omarchy-mac, omarchy-mac-boot, omarchy-ane, omarchy-steam-fex),
  https://github.com/omacom/omarchy-mac-installer (`scripts/supported-models.json`), https://github.com/omacom/omarchy-mac-pkgs #103.
- Other M5 trees: https://github.com/betizzel/omarchy-m5 (J714s), https://github.com/TripleU613/Omarchy-M5-Pro (J714s), edimoldovan's
  `linux-aurora` `t6050-j714c` and `m1n1` `t6050-aurora` branches.
