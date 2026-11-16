# j716s-next: move the daily kernel to current upstream (handoff, 2026-11-12)

For the agent that continues this in `~/Documents/GitHub/m5pro/m5pro-linux` (public) and
`~/Documents/GitHub/m5pro/m5pro-linux-re` (private).

## The task

The MacBook (J716s, 16-inch M5 Pro, firmware 27.3) runs a "daily" kernel: 269 private commits on an upstream base
of 7 November. `j716s-next` replaces that with **current upstream plus 25 commits**. It boots and the main things
work, but it is **not the daily yet**. The job is to finish the port, test it, and promote it, without losing
anything the daily does today. The owner's GPU and display work must not regress.

## State (updated 2026-11-15): three things built, none booted yet

The MacBook was busy on 2026-11-15, so everything below is built and packed but not booted.

- **`j716s-next2`** (`e4fc1f3d43ba`, on the fork): `j716s-next` moved onto `integration/aurora` `07ade53fd116`
  (557 upstream commits newer, among them T6050 suspend to RAM for the J714s, the T6050 GPU mailbox interrupt,
  the AVE 27.3 admission, the ALS setup-port fix and the T6050 WFxT/vGIC errata). 19 commits: the dead
  `APPLE_RTKIT_PLACED_BUFFERS_UNACKED` flag and the three aop_t8140 commits with their reverts were dropped (no
  user left). Conflicts kept both sides: the J714s A407 swap (27.0 table only) beside our 27.3 swap record, K114c
  beside J716s in the adopted-link s2idle list and the ATC2 router guards, upstream's `spk_fixed_ceiling` beside our
  `max_vol`, upstream's tiled-display mode context beside our VRR fallback. Builds clean (`kbuild-next2`, all 125
  modules). Packed as `next2-oldloader-20261115-c956167b.bin` (today's loader).
- **`j716s-s2r`** (`e8a25915a7ac`, on the fork, on top of `j716s-next2`; builds clean, `kbuild-s2r`; packed with the
  aura stage 2 as `s2r-aura-nohw-20261115-3c636fe6.bin`): the J716s taken into every T6050 deep-sleep gate
  (`apple_t6050_sleep_board()`), the J716s tree includes `t6050-j714s-sleep.dtsi` and describes the MagSafe's `hpm5`.
  The display's firmware 27 sleep stays J714s-only (it is built on the 27.0 table). **Blocked on the loader:** the
  kernel needs the SoC sleep data (commit schedule, SMC sleep policy, register sequences, `apple,seq-*`) from the boot
  loader, and no public loader produces it (aura main fills only the wake sources and skipped pins, #214). Without
  it the default sleep stays s2idle, so the branch is safe to boot.
- **aura stage 2** (`/Volumes/m5pro/aura`, branch `j716s` `8609ceb6`, 8 commits on aura main `52af355c`; bundle in
  `m5pro-linux-re/git-bundles/aura-j716s.bundle`): replaces the m1n1 stage 2 inside `boot.bin`; stage 1 stays.
  The port table and first-boot risks are in `contrib/pending/boot-aura/PORT.md`. Built `aura-j716s.bin` and
  `aura-j716s-nohostwait.bin` (0x3b0000); aura's host tests pass apart from the failures aura main has in the same
  container. `mk-next-test.py` takes it with `NEXT_M1N1=PATH`; packed as `next2-aura-nohw-20261115-a5ad4dd9.bin`.
  Brings aura #173 (clears iBoot's failed-boot count on T6050, unmaps the TZ carve-outs: candidates for the early
  reset), no stop on a missing `sep` alias, the SIO tables and the sleep wake sources.

**Test order on the machine** (each a self-reverting `boot.bin`, `boot.bin.prev` untouched):
1. `next2-oldloader`: the rebase alone; same checks as the 2026-11-12 boot (display 120 Hz, VRR, GPU, Wi-Fi, BT,
   sound, backlight, battery, 18 CPUs).
2. `next2-aura-nohw`: aura without the USB window. Then read `/chosen/asahi,t6050-dcp-handoff`, the loader log
   for "handoff refused", and check the N1 came up (aura trains it itself now).
3. The aura image with the 4 s USB window (`aura-j716s.bin`), then the `j716s-s2r` kernel (expect s2idle only).

## State on 2026-11-12, evening (before the rebase above)

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
3. **Tether:** at the daily's level, which is not a working link. The cable is in (left-back port to the Mac
   Studio); "not attached" only meant that no gadget was bound. On `j716s-next` and on the old daily alike, after a
   fresh boot: a configfs NCM gadget bound to `2a2280000.usb` reaches `configured` at high speed and the Mac Studio
   lists it (480 Mb/s), but macOS creates no interface for it (no network interface; no serial device for ACM), and
   `usb0` stays without carrier. An unbind logs `dwc3: wait for SETUP phase timed out` and `ep0 data phase end
   transfer failed: -110`, and no later bind attaches. No data has crossed the link under Linux on either kernel.
   Does not block promotion; the control-endpoint fault is its own item (scripts: `m5pro-linux-re/tooling/tether/`).
4. **Audio in userspace:** on the new card the `j716-convolver` chain is linked to `RawSpeakers` and speakersafetyd
   runs with `j716.conf` (it panicked once at its first start, `main.rs:298`, and ran on the restart). Nobody has
   listened yet (`contrib/validated/desktop/audio/j716-profile/LISTENING-TEST.md`). Does not block promotion.
5. **Never exercised on this branch:** suspend (s2idle; deep sleep is `j716s-s2r`, blocked on loader data; the
   PMU RTC alarm is now described there, so `rtcwake` may work), external displays,
   USB4, camera, ANE, lid angle. Seen in the boot log: the two JPEG encoders probe; video decode fails for a missing
   `apple/avd-fw-v5-t2.bin`; the encoder has "no preloaded firmware"; ProRes has no init file; ALS stays off ("no ALS
   calibration named in the device tree"); only the eDP connector exists.
6. **Decide:** CLPC (`APPLE_CLPC=y` plus the link) and the two idle parameters (`m5_idle_standby_us`,
   `m5_idle_hold`); none ported.
7. **Needs J716s ADT values, not copied from J714s:** SD card reader, Touch ID, PMP and its tunables.
8. **Soak**, then promote: rebuild as a daily payload (no self-revert), keep the old daily as `boot.bin.prev`.
9. **`e2fsck` the MacBook's root** (it mounts "with errors").

## Traps already found

- **2026-11-16, aura stage 2 first boot:** "pcie-t6050: STOP: ANS is not running (before)" -> "refusing T6050 handoff after
  the apcie0 port 2 bring-up stopped" -> "No valid payload found" -> proxy, and its `m1n1.wdt=keep` handling let the
  watchdog lapse, so the machine sat in the proxy. **A power-button cycle does not make stage 1 fall back** (only a
  watchdog reset counts as a failed boot), so it booted the same `boot.bin` again. Recovery: power-hold picker ->
  Macintosh HD -> Continue; in macOS `sudo diskutil mount disk0s4` (plain `mount -t msdos` fails: the msdosfs kext no
  longer loads on 27.3), copy `m1n1/boot.bin.prev` over `m1n1/boot.bin`, check the hash, `diskutil unmount`, reboot
  (the startup disk stayed Omarchy; `sudo bless --mount /Volumes/Omarchy --setBoot` set it, non-interactively, from ssh).
  Never boot a loader whose watchdog behaviour is unproven without someone at the machine.

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
- Both upstream bugs above are still open on `integration/aurora` `07ade53fd116` (2026-11-15); our branch carries
  the fixes.
- Upstream in flight that touches ours: #1816 (joshuaswarren) fills the 27.3 method table too (overlaps our
  `drm/apple: firmware 27.3` commit); aurora-silicon/m1n1#65 was asked to move to aura (the `j716s` aura branch now
  carries the equivalent); omacom/m1n1 #33-#37 have had no review since 2026-11-10.
- Aurora's device-support page lists J716s Touch ID, speakers, SDXC and video decoding as working from a general M5
  statement; none of these has run on a J716s.
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
