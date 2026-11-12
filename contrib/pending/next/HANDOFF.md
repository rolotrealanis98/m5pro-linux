# j716s-next: move the daily kernel to current upstream (handoff, 2026-11-12)

For the agent that continues this in `~/Documents/GitHub/m5pro/m5pro-linux` (public) and
`~/Documents/GitHub/m5pro/m5pro-linux-re` (private).

## The task

The MacBook (J716s, 16-inch M5 Pro, firmware 27.3) runs a "daily" kernel: 269 private commits on an upstream base
of 7 November. `j716s-next` replaces that with **current upstream plus 25 commits**. It boots and the main things
work, but it is **not the daily yet**. The job is to finish the port, test it, and promote it, without losing
anything the daily does today. The owner's GPU and display work must not regress.

## State (updated 2026-11-12, evening)

- Branch `j716s-next`, tip `8ab10100a4c1`, on `rolotrealanis98/linux` (public fork): `aurora-silicon/linux`
  `integration/aurora` at `34a447be54ea` plus 26 commits. The tip before the rebase (on `107b3619a1bc`, with the VRR
  commit) is kept as `j716s-next-on-107b3619` (`f3793aa08bce`).
- The work drive is back: case-sensitive APFS volume `/Volumes/m5pro` on the 8TB container (layout in its
  `README.md`): kernel clone with all old branches, worktree `wt/next`, output `out/next`, bindgen, bench output.
- The reference rebuild of `bf857188d078` gave the parked config and device tree bit for bit.
- Booted on the machine on 2026-11-12: `f3793aa08bce` (VRR port) and `8ab10100a4c1` (rebased). On both: display
  3456x2234 at 120 Hz, GPU, Wi-Fi, Bluetooth controller, both sound cards, backlight, battery, 18 CPUs, Hyprland.
- **VRR is ported** (`appledrm.fw27_panel_vrr=1`): Hyprland's and `vrrflip`'s VRR_ENABLED select the mode again, the
  firmware logs `minRR = 0x180000` / `VRR=YES` and `minRR = 0x0` / `VRR=NO`. The flip-event cadence does not tell on
  from off on this kernel (50 fps flips are 20.83 ms apart in both); the swap-complete measurement of the daily needs
  the `dcp` trace events, and this config has no tracing (`/sys/kernel/tracing/events/dcp` is absent).
- **Frame timing under load:** 7 minutes of `stress-load.sh` (3 vkcube, glmark2, two Qt windows, Chromium WebGL) on
  `f3793aa08bce` with VRR on: no swap timeout, no GPU error, no display fault.
- The "swap failed! status 4294967295" at a DRM client's exit is gone after the rebase (upstream `f9d1a63f12f3`).
- The MacBook was left running `8ab10100a4c1` from a self-reverting test file in `boot.bin` (`62c2e690`);
  `boot.bin.prev` is the old daily (`629fc84c`). Modules of both test kernels are installed.
- The first boot of the rebased test file reset before Linux and the old daily came up (`fallback-after-failure`,
  `pmu-scrpad` `300100`); the same file booted cleanly a minute later. Second sighting of the unexplained early reset.

## Where things are

| What | Where |
|---|---|
| The branch | `rolotrealanis98/linux`, branch `j716s-next` |
| Build and boot scripts, test recipes, the booted kernel's config, machine access | `m5pro-linux-re/tooling/pr-verify/` (read its `README.md` first) |
| Payload packer | `m5pro-linux-re/tooling/loop-safety/mk-daily.py` |
| Booted kernel, modules, device tree, boot ingredients, boot logs | `~/Documents/m5pro-next-park/` (Mac Studio internal disk, local only) |
| Every other old kernel branch (`j716s-daily` and 102 more) | `m5pro-linux-re/git-bundles/linux-cs-local-branches.bundle` |
| Old VRR tools and the display analysis | `m5pro-linux-re/tooling/vrr/`, `m5pro-linux-re/findings/dcp/` |
| What the old work folder was, directory by directory | `m5pro-linux-re/WORK-AREA-INVENTORY-20261112.md` |

## First steps

1. The kernel work lives on `/Volumes/m5pro` (see its `README.md`); scripts run from `m5pro-linux-re/tooling/pr-verify/`.
2. To restore the clone from nothing: clone `rolotrealanis98/linux`, add `aurora-silicon/linux` and
   `rolotrealanis98/linux-aurora` as remotes, fetch `236788cd2602` from `linux-aurora` by hash, then the bundle
   (`refs/heads/*:refs/heads/*`). The installed daily is `0933f881d736` (local branch `j716s-daily`).
3. Rebuild bindgen with `build-bindgen.sh` (runs `tools/aurora-bindgen/build.py` in the build container).
4. The scripts take `M5` (work volume), `WT` (worktree name) and `KBUILD` (result folder).
5. Build with `build-next.sh` (`defconfig asahi.config j716s.config j716s-gpu.config`; Fedora 43 container, clang,
   rustc 1.99.1; needs `openssl` for module signing). The release is `7.3.0-g<commit>` (the clone has no tag for a count).
   Install the modules tarball on the machine before the boot (`tar -C / --zstd -xf`, `depmod`).
6. Ask the owner before touching the MacBook. Boot tests with `boot-next.sh LABEL DTB`: it installs as `boot.bin`
   only, with self-revert on. `NEXT_NOGPU=1` / `NEXT_NODISPLAY=1` drop a hand-off, `NEXT_EXTRA=" panic=0"` holds a
   panic on screen.

## What the branch carries

Current upstream plus only what upstream does not have:

- **Display, firmware 27.3:** the full IOMFB method table and the 27.3 swap record, on top of the merged #1174
  (which on its own refuses 27.3). EDR words are not sent on the 27.3 swap.
- **GPU, firmware 27.2 / 27.3:** the 26B123 and 26C5035 builds in upstream's per-build graph, the `J716S` board
  selected by the machine compatible, `aurora.m5_pause_timeout_us`, the #1242 recovery log.
- **Device tree:** `t6050-j716s.dts` with the J714s feature set (ProRes, JPEG, video decode and encode, camera,
  ANE, AOP with ALS and lid angle, external displays, the right port's USB4 router), the 16-inch panel and display
  engine, the GPU for this loader's hand-off, speakers and jack, boot NOR/NVRAM, the USB tether on the left-back port.
- **Small ones:** J716 macaudio entry with a -30 dB ceiling, s2idle with the adopted N1 link, the never-booted N1
  guard, the SMC `gP` bank on T6050, the config fragment.

## Left to do, in order

1. ~~VRR on the internal panel~~: ported and booted (see State). Open: a swap-complete cadence measurement, which
   needs tracing in the config (`CONFIG_FTRACE` and the `dcp` events).
2. ~~Frame timing~~: clean in a 7 minute load; the soak (item 8) is the longer check.
3. **Tether:** the controller is there (`2a2280000.usb`, "not attached"). Test with the USB-A to C cable from the
   Mac Studio (USB-C to C fails).
4. **Audio in userspace:** on the new card the `j716-convolver` chain is linked to `RawSpeakers` and speakersafetyd
   runs with `j716.conf` (it panicked once at its first start, `main.rs:298`, and ran on the restart). Nobody has
   listened yet (`contrib/validated/desktop/audio/j716-profile/LISTENING-TEST.md`). Does not block promotion.
5. **Never exercised on this branch:** suspend (no RTC alarm, so it needs a person to wake it), external displays,
   USB4, camera, ANE, lid angle. Seen in the boot log: the two JPEG encoders probe; video decode fails for a missing
   `apple/avd-fw-v5-t2.bin`; the encoder has "no preloaded firmware"; ProRes has no init file; ALS stays off ("no ALS
   calibration named in the device tree"); only the eDP connector exists.
6. **Decide:** CLPC (`APPLE_CLPC=y` plus the link) and the two idle parameters (`m5_idle_standby_us`,
   `m5_idle_hold`); none ported.
7. **Needs J716s ADT values, not copied from J714s:** SD card reader, Touch ID, PMP and its tunables.
8. **Soak**, then promote: rebuild as a daily payload (no self-revert), keep the old daily as `boot.bin.prev`.
9. **`e2fsck` the MacBook's root** (it mounts "with errors").

## Traps already found

- **The loader stops at a `sep` alias** ("FDT: sep not found in devtree", then "Running proxy", then the watchdog
  falls back). No `sep` alias, SEP mailbox or `ps_sep` in the device tree.
- **The loader's GPU hand-off needs exactly four states** (`gpx`, `afr`, `cs`, `gfx`) in the GPU's PMGR node and
  one power domain labelled `gfx`; upstream describes three. A mismatch leaves the GPU disabled, silently.
- **`apple,clpc` on the GPU node with `APPLE_CLPC=m`** makes the GPU driver fail at "session" with ENODEV. The
  branch deletes the link for J716s.
- **Do not cherry-pick the daily's `aop_t8140` audio commits**: they collide with upstream's audio driver
  (duplicate `rust/bindings` symbol). `DRM_ASAHI_M3_T8122` needs `APPLE_PMP`, so the fragment turns it off.
- macOS `cpp` cannot preprocess a DTS; use `clang -E -P … -x assembler-with-cpp` (`dt/build.sh`).
- The exact #1174 head reset twice within 10 s before booting cleanly on the third try. Never explained.

## Pull requests

- `aurora-silicon/linux` #1174: merged 2026-11-12 (boot report: the exact head refuses 27.3 at probe).
- #1242: open. Not validated on hardware: 9 minutes of stress produced no fault to recover from.
- #1173: draft. The maintainers accept only values observed in traces, not ones derived from firmware; the branch
  carries its content privately until traced values exist.
- **Two upstream bugs found, no PR opened:**
  1. `t6050-j716s.dts` includes `t6050-peripherals.dtsi` last, which disables the N1's power states again.
  2. `mfd: macsmc` never registers `apple,smc-gpio` on T6050, so the N1 `pwren-gpios` never resolves (no Wi-Fi on
     upstream J716s).
- Rules: open nothing upstream without the owner asking, and first check that nobody has the same change in flight.

## Ledger rows this moves (`contrib/community/gap-map.csv`, not edited: nothing is the daily yet)

`dist.upstream` (269 private commits on a 7 November base become 25 on current upstream); `camera.isp`, `ane`,
`video.decode`, `video.encode`, `video.jpeg`, `video.prores`, `display.external`, `usb.thunderbolt`, `sensors.als`,
`sensors.motion`: described in the device tree, untested; `audio.speakers`, `audio.jack`: on upstream's driver,
userspace open; `gpu.recovery`: #1242's log in.

## Also open in this checkout (closed 2026-11-12)

Committed and pushed on 2026-11-12 (three commits): six modified files under
`contrib/` (distro config, the aurora `j716s.config`, the audio profile) and untracked
`contrib/pending/boot-ab/firstboot/mk-stage1-0017-vars.diff` and `contrib/pending/input/`.
