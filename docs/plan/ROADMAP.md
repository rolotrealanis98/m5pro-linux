# M5 Pro (J716s, T6050) Linux roadmap

Planning agent, 2026-11-05. Design only; no hardware was touched. Read with `FRICTION.md` (how to
make each hardware round need less of Rolando) and `SUMMARY.md` (top five changes).
Sources: repo `README.md`, `docs/status-2026-11-05.md`, `contrib/pending/*/REPORT.md` +
`TEST-PLAN.md`, `contrib/pending/integration/RESULTS.md`, `contrib/distro/{DESIGN,GAPS}.md`. Effort
uses the distro GAPS scale: **S** <= 2 days, **M** <= 2 weeks, **L** <= 2 months, **XL** = new
driver or upstream work with no date.

## Tiers (defined here; the repo had none)

- **Tier 1, "a laptop on a desk"**: only needs existing drivers, DT and testing: battery/charger,
  cpufreq on all clusters, thermal monitoring, keyboard backlight, power-off, USB 2.0 host (and
  through it a network and Wi-Fi/BT dongles), unattended reboot and recovery.
- **Tier 2, "a laptop you can carry"**: needs adopting a large external tree or a new transport:
  display driver (DCP: brightness, modeset, display PM), audio (speakers, jack, headset mic),
  Thunderbolt/USB4 on the right port, built-in Wi-Fi/BT (N1), s2idle, an installable distro.
- **Tier 3, gated by unpublished ABIs or exclaves**: GPU acceleration, camera (ISP), built-in mics,
  ALS, CPU idle states, Touch ID / SEP-backed features.

## 1. Where things stand (2026-11-05)

Works on hardware: 18-core SMP, untethered two-stage boot, NVMe root (0016), trackpad (0001-0002),
iBoot boot-failure counter cleared by Linux (0017), LLVM kernel builds on macOS, framebuffer
console, keyboard, EEM gadget SSH, SMC core (RTKit, both GPIO banks, lid/power input, RTC, hwmon).
Fails: `macsmc-power`, which hangs hard at ~7.8 s in its probe (RESULTS.md:148-153). Booted but
untested: fan keys, cpufreq OPPs for all three clusters, USB host drivers (the host DTB has never
been booted).

## 2. Tier 1 remainder

| ID | Feature | Next step | Depends on | Effort | Round |
|---|---|---|---|---|---|
| T1.0 | **Unattended reboot/recovery** (FRICTION P1-P4) | prototypes done: m1n1 0016, `m5-debug.config`, netconsole initramfs, `m5-deploy.sh` | one 1TR ceremony | S | R1 |
| T1.1 | **macsmc-power probe bisect** | see below | T1.0; P3 kernel config | S-M | R2 (unattended) |
| T1.2 | cpufreq stages 1-2 (`contrib/pending/cpufreq/TEST-PLAN.md`) | `userspace` governor checks per cluster, then `schedutil`. Never cpuidle (REPORT: WFI loses state on M4+) | T1.0 for safety | S | R2 |
| T1.3 | SMC fan keys and hwmon, thermal stage A (7 monitoring-only zones), keyboard backlight (`fpwm0` PWM, `PWM_APPLE=y`) | platform TEST-PLAN stage A, T1-T3; the stage-B thermal trips wait for T1.2 | T1.2 for stage B | S | R2 |
| T1.4 | **USB 2.0 host, left-front** (`contrib/pending/usb/`) | step 0 (proxy probe of the PHY addresses), steps 1-5 (usbhost DTB, first device, Ethernet dongle, replug); 1b (PD controller) if VBUS reads 0 V | proxy access (see the R3 note); dongle, hub, meter | S (1a), M (1b) | R3 |
| T1.5 | Network over USB Ethernet (FRICTION P8a) | systemd-networkd DHCP on `en*`, SSH straight from macOS, pacman over the LAN | T1.4 | S | R3 |
| T1.6 | Wi-Fi/BT through a USB dongle (`contrib/pending/wireless/` README + `packages.txt`) | mt76/rtl8xxxu `=y`, firmware staged into the root (`mk-esp-install.sh --firmware`) | T1.4 | S | R4 |
| T1.7 | Power-off, and the power key / lid under logind | platform TEST-PLAN P steps; logind config so the power key does not halt | a human, to power on after power-off | S | R1/R3 |
| T1.8 | pstore/ramoops (FRICTION P5) | retention probe (3 boots), then the m1n1 kboot ramoops node | T1.0 | S | R1 probe, R4 node |

**T1.1 in detail.**
- Build a kernel with `MACSMC_POWER=m` and one `dev_info` per SMC key in probe order, plus one
  around `power_supply_register` and one around the notifier.
- The debug initramfs loads the module after netconsole is up (`m5.insmod=macsmc_power`). Console
  ramoops is the second witness.
- Each hang resets by itself (the P1 watchdog) and the next boot falls back. The agent reads the
  last line, moves the bracket and redeploys: 3-6 iterations at about 15 min each, no human.
- The fix is then one of: skip or guard the offending key for T6050 (the smc REPORT lists which
  keys are present and absent), or move that read into a work item with a timeout.

## 3. Tier 2

| ID | Feature | Path | Depends on | Effort | Earliest round |
|---|---|---|---|---|---|
| T2.1 | **Display: DCP brightness, then modeset, then display PM** | see below | W2 (aurora tree adoption); T1.0, because a DCP crash blacks the panel, so netconsole and fallback are mandatory | M-L (2-4 weeks with hardware iterations) | R4 (read-only), R5+ (bring-up) |
| T2.2 | **Audio**: speakers, jack, headset mic | stage A DTB now: amps and codec on I2C, amps held in shutdown. Stage B: port aurora's J616s AOP transport (`aop.rs` for T6050, apple-admac `evolved_layout`, `aop_spkr.rs`, a J716 macaudio entry with speakers off by default; audio REPORT section 5) | **W1 (CONFIG_RUST)**; whether AOP coexists with `aop-exclave-mailbox` (unknown) | L | R4 (stage A), R6+ (stage B) |
| T2.3 | **N1 Wi-Fi/BT** | aurora's GPL N1 stack plus their T6050 PCIe host. Gates: apcie0 port-0 training in m1n1 (not public), the per-device FTAB and the J716s platform ID (wireless REPORT section 2) | W2; bootloader work in m1n1. T1.6 covers the need meanwhile | L (1-3 months) | after T2.1 |
| T2.4 | **Thunderbolt/USB4, right port only** | import aurora `j716c/thunderbolt` (combo PHY CIO mode, routers/NHI, DART from DT, PCIe tunnel). A separate DTB describes ATC2 only and **never** hpm0/atcphy0/acio0: left-back carries the tether (isp-tb REPORT) | W2; T1.0 (failure modes are SError and SoC-watchdog resets) | M-L | R5+ |
| T2.5 | s2idle | platform TEST-PLAN, staged: freezer, devices, platform, real. Kernel 0042 skips PMGR writes in system sleep. No CPU savings while `idle=nop` stays | T1.1-T1.3, T2.1 (display PM) | M | last |
| T2.6 | Installer/distro (`contrib/distro/`) | see W4 | T1.0, T1.5 | M | in parallel |

**T2.1 in detail.**
- Path (a1): adopt aurora-silicon `t6050/dcp` (firmware-27, C, about +4k lines) on top of an
  import of aurora's drm/apple.
- m1n1 needs a T6050 display handoff:
  - reserved memory;
  - `firmware-compat` written only for a verified firmware build;
  - DART handling that does not wipe iBoot's L1 tables (`apple-dart.c:469-472`).
- **Gate**: does aurora's method table match the DCP firmware that 26C5035r pairs? (dcp REPORT
  "Decision", point 3.) Run the read-only TEST-PLAN steps 0-4 before anything else.

## 4. Tier 3 and what is blocked (trigger to revisit)

| Feature | Blocker | Trigger to revisit |
|---|---|---|
| GPU (G17S, two firmware instances, 27.x firmware) | no public driver for any 27.x GPU firmware; aurora's M5 runtime is not public (gpu REPORT "Decision") | aurora publishes the T6050 runtime (then 3-6 weeks: W1 plus the matching firmware build), or m1n1 boots macOS 27 under the HV on M5 for other people (re-cost an own port, 10-19 weeks). Meanwhile: software-rendered Hyprland (gpu REPORT section 4) |
| Camera (ISP) | the ADT marks it exclave-assigned; its power domains are `no_ps` | someone shows AP-side ISP power control on T6050, or aurora's T6040 streaming path reaches T6050 |
| Built-in mics | `hpai` sits on the secure ADMAC behind the exclave service `HPMicAudioDriver` | a demonstrated non-exclave route to `leap-s`. The headset mic arrives with T2.2 |
| ALS | AOP is routed through `aop-exclave-mailbox` | T2.2 stage B proves an AP RTKit session coexists with the exclave |
| Privacy-indicator brightness, Touch ID | exclave-owned (`EXBrightPILCore`, SEP) | none planned |
| CPU idle states | WFI/WFIT lose state on M4+; cpuidle-apple writes a locked sysreg | an upstream M4+ idle method |
| Brightness without DCP | the backlight chip is owned by DCP firmware; driving it directly was rejected | none: T2.1 is the path |

## 5. Enabling workstreams

### W1. CONFIG_RUST (needed by T2.2 audio, ALS, any GPU adoption)

Facts:
- The integration `.config` already detects the toolchain (`CONFIG_RUSTC_VERSION=109901`:
  Homebrew rustc 1.99.1, LLVM 23) but has `# CONFIG_RUST is not set`.
- `bindgen` is not installed on the Studio.
- Asahi's DRM driver is Rust, and so are aurora's `aop.rs`, `aop_spkr.rs`, `aop_als.rs` and its
  g17 module.

Two hosts:
- **(a) The Fedora `container` VM (recommended for Rust kernels).**
  - Native aarch64 Linux, case-sensitive filesystem.
  - Distro-matched rustc, rust-src, bindgen-cli and clang/LLVM; no macOS host-tool quirks.
  - The m1n1 Linux build already lives there (`~/Work/m1n1-linuxbuild`). Container CLI 1.6.1 is
    installed; no container is running today.
  - Steps: `dnf install rust rust-src bindgen-cli clang lld llvm`, then `make LLVM=1
    rustavailable`, then turn on `CONFIG_RUST` in the integration tree and build with no Rust
    driver selected (this proves the toolchain), then the `drivers/soc/apple/rtkit` Rust bindings.
  - Effort S (1-2 days).
- **(b) The macOS host.**
  - `cargo install bindgen-cli` against Homebrew libclang, plus `rustup component add rust-src`
    for the exact version the tree wants.
  - Keeps a single build host, but every macOS host-tool issue (Apple make 3.81, sed/stat flags,
    case sensitivity through `/Volumes/linux-cs`) multiplies with Rust's build scripts.
  - Use it only if (a) hits a blocker.
- Either way, the C-only daily kernel keeps building with `CONFIG_RUST=n` until a Rust driver is
  actually needed (audio stage B), so W1 never blocks Tier 1.

### W2. Adopting the aurora-silicon trees (DCP, Thunderbolt, later N1/AOP)

aurora's drm/apple is far from ours (~67k vs 12k lines, dcp REPORT section 2), so do not
cherry-pick into asahi-wip-7.2. Instead:
1. Pin aurora's `integration/aurora` at one commit, and diff its `drivers/gpu/drm/apple`,
   `drivers/thunderbolt`, `drivers/phy/apple` and `drivers/soc/apple` against ours.
2. Build an "aurora-on-ours" branch that imports whole directories, not single commits, and
   re-applies our T6050 patches (0001-0017) on top.
3. Gate every imported driver behind a separate DTB (the pattern already used for usbhost and
   audio).
4. Track license and authorship (GPL; keep their trailers).

The DCP ABI gate (T2.1) is answered read-only before any write path. Re-pairing the stub to
another macOS build swaps *every* coprocessor firmware. Do it only if aurora's table matches a
released build and not 26C5035r, and then re-verify NVMe, SMC and the trackpad.

Effort: M for the import mechanics, then per feature.

### W3. The USB host port as the gateway

T1.4 -> T1.5 -> T1.6 is the cheapest route both to "network without the Studio" and to "Wi-Fi/BT
now":
1. USB 2.0 host (1a) first, with a powered hub so VBUS does not matter.
2. An Ethernet dongle (needs no firmware).
3. A Wi-Fi/BT dongle (mt7921au class, firmware into the root). The wireless REPORT's dongle table
   names candidates.

1b (PD controller: VBUS, replug without a rebind) is needed for bus-powered devices and hot-plug.
USB3 needs ATC/PIPE work (USB REPORT "Later").

### W4. Installer/distro plumbing (`contrib/distro/`)

The GAPS "shortest path" (items 1-4 and 6-8, then 5 and 12) is about 4-6 weeks. Changes from this
plan:
- `mk-stage1.py` gains `--fallback-path` and `--wdt` (diff in `patches/`).
- `m5pro-update-payload` and `m5pro-boot-ok.service` become the packaged form of `m5-deploy.sh`
  steps 2-4 and `m5-boot-slot`, with the same file names (`boot.bin`, `boot.bin.prev`, `TRIAL`).
  DESIGN's `fallback.bin` maps to `boot.bin.prev`.
- DESIGN option D ("boot counting: not now") becomes possible without new persistent state,
  through the PMU counter (FRICTION P1).
- GAPS #17 (no automatic fallback) closes with m1n1 0016 plus the root-side demotion.
- GAPS #18 (the 1TR rescue has never been shown to work) is still worth one deliberate test, now
  cheap because stage-1 clears the counter.

## 6. Hardware rounds (from Sunday 2026-11-08)

### Before Sunday (no hardware; agents)

Builds:
- A/B stage-1: `mk-stage1.py stage1 --fallback-path m1n1/boot.bin.prev --wdt 150`.
- "B2-debug": B2 plus `m5-debug.config` plus the netconsole initramfs, with `initcall_blacklist`
  kept.
- "B2-power-bisect": the same, plus `MACSMC_POWER=m`, the `dev_info` patch and the module in the
  initramfs.
- The cpufreq and platform stage-A DTB payloads.

Studio side:
- A persistent eem-vm guest and the netconsole listener (LaunchAgents).
- `macvdmtool reboot` added to `sudoers-m5pro`.
- `m5-deploy.sh --dry-run` against the payloads.
- Buy or mount the webcam (P7).

### R1, Sunday 2026-11-08: Rolando present, about 2.5 h

Physical: the fixed cabling (FRICTION "Physical setup"), MagSafe, camera.

1. In macOS: `sudo host/macos/stage1-install.sh <A/B stage-1>`, with the current stage-1 copied to
   the stub as the rollback. Set Startup Disk back to the stub, then power-hold -> Omarchy ->
   step2. This is the one ceremony.
2. Boot B2: the unchanged kernel, already on the ESP once Rolando restores it. Run A/B tests 1-2
   (FRICTION P1).
3. `m5-deploy.sh B2-debug`: netconsole lines arrive on the Studio, the lockup detectors are
   present, and the watchdog is fed.
4. A/B tests 3-5. Test 3 deliberately boots the macsmc-power hang, which also gives the first
   netconsole and ramoops evidence.
5. The pstore retention probe (3 boots).
6. 10 minutes for the power-off test (T1.7), which needs a finger on the power button.

Rolando can leave once step 4 passes; everything after that is unattended.

### R2, Sunday evening to Monday: unattended (agents through `m5-deploy.sh`)

- T1.1 macsmc-power bisect, through to a fix.
- T1.2 cpufreq stages 1-2.
- T1.3 SMC fans, hwmon, thermal stage A, keyboard backlight.

Each deploy rolls back on its own. Rolando is called only when `m5-deploy.sh` exits 3.

### R3, the next time Rolando is at the desk: about 1 h

Physical: a passive USB-C to USB-A adapter, a powered hub, an AX88179 or RTL8153 dongle, a flash
drive, an inline USB-C power meter.

1. T1.4 step 0 needs the stage-1 proxy. With A/B, moving only `boot.bin` aside just boots
   `boot.bin.prev`, so move both aside (`.hold`). After the proxy session, a tethered
   `m5.sh boot-linux` puts them back.
2. Steps 1-5, including the replug tests that need hands.
3. T1.5: SSH over Ethernet from macOS.
4. Whatever power key and lid checks are left.

### R4, unattended once Ethernet works

- T1.6 Wi-Fi/BT dongle.
- T1.8 m1n1 ramoops node, if the probe passed.
- T2.1 DCP TEST-PLAN read-only steps 0-4.
- T2.2 audio stage A DTB.
- GPU `gfx-fw-read.py` (DRAM reads only), to record the firmware identity for the trigger watch.

### R5+, after W2 lands

T2.1 DCP bring-up (brightness first), then T2.4 Thunderbolt on the right port. Both can fail with
an SError or a black panel, so both run only with P1-P5 in place.

### R6+, after W1

T2.2 audio stage B.

### Later

T2.3 N1, T2.5 s2idle, and the Tier 3 triggers.

## 7. Dependency picture

```
W0 = FRICTION P1..P5 (R1) ──┬─> T1.1 macsmc-power ──> T1.3 thermal B ──> T2.5 s2idle
                            ├─> T1.2 cpufreq ────────┘
                            ├─> T1.4 USB host ─> T1.5 Ethernet ─> T1.6 Wi-Fi dongle
                            │                   (P8a: Studio-free network)
                            └─> W2 aurora import ─┬─> T2.1 DCP ──> T2.3 N1 (also m1n1 apcie work)
                                                  └─> T2.4 TB (right port only)
W1 CONFIG_RUST (Fedora container) ──> T2.2 audio stage B (also needs AOP/exclave coexistence)
W4 distro: needs W0 + T1.5; packages FRICTION P1/P4 as m5pro-boot
Tier 3: external triggers only
```


## Addendum 2026-11-05 evening (community feedback, see docs/community-2026-11-05.md)
- R1 (Sun 11-08) adds: the PMP window double dump for Joshua/Aurora (tethered, read-only, fault-tolerant).
- Next kernel adds CONFIG_ZRAM=y (+zstd backend); cpufreq stage 1 may start on schedutil (validated on J714c).
- USB rounds: evaluate Omacom m1n1 160b644c's T6050 USB-PD setup instead of our patch 0005 skip (port power).

- Community update 23:48 UTC (J714c): keyboard backlight, SMC input/RTC, battery+charger, sensors, s2idle, lid lock,
  notch and firewall all work on edimoldovan's tree. Re-prioritise R1/R2: (1) try his 200 ms SMC AP-power-ACK wait
  against our macsmc-power probe hang before any bisect; (2) bundle for the next kernel: ZRAM, netfilter for ufw,
  `apple,internal-panel` eDP connector, show-notch, xhci wakeup-source; (3) s2idle moves from "last" to R2 once (1)
  passes, still with the PMGR-sleep guard (patch 0042) and the root read-only; (4) A/B stage-1 gets a proxy window.
