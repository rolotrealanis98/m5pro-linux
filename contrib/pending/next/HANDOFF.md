# j716s-next: move the daily kernel to current upstream (handoff, 2026-11-12)

For the agent that continues this in `~/Documents/GitHub/m5pro/m5pro-linux` (public) and
`~/Documents/GitHub/m5pro/m5pro-linux-re` (private).

## The task

The MacBook (J716s, 16-inch M5 Pro, firmware 27.3) runs a "daily" kernel: 269 private commits on an upstream base
of 7 November. `j716s-next` replaces that with **current upstream plus 25 commits**. It boots and the main things
work, but it is **not the daily yet**. The job is to finish the port, test it, and promote it, without losing
anything the daily does today. The owner's GPU and display work must not regress.

## State

- Branch `j716s-next`, tip `bf857188d078`, on `rolotrealanis98/linux` (public fork). Base: `aurora-silicon/linux`
  `integration/aurora` at `107b3619a1bc`.
- Booted once on the machine on 2026-11-12, for a few minutes: display 3456x2234 at 120 Hz, GPU (`vkcube`,
  `glmark2-es2-wayland` 983), Wi-Fi, Bluetooth controller, both sound cards, backlight, battery, fans, Hyprland.
- The MacBook's two boot slots both hold the old daily (`629fc84c`). Nothing permanent was changed on it.
- No kernel tree, build output or toolchain exists on the Mac Studio any more: the external drive was erased and is
  now APFS at `/Volumes/8TB`, empty.

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

1. Ask the owner where on `/Volumes/8TB` the kernel work goes. The kernel tree needs a **case-sensitive** volume;
   an added APFS volume (case-sensitive) on the drive's container is the simplest. Nothing bulky on the internal disk.
2. Clone `rolotrealanis98/linux` there, add `aurora-silicon/linux` as a remote, check out `j716s-next`. Fetch
   `linux-cs-local-branches.bundle` too (`refs/heads/*:refs/heads/*`): `j716s-daily` is the reference for
   everything still to port.
3. Rebuild bindgen with `tools/aurora-bindgen/build.py` from the tree.
4. Copy the scripts from `m5pro-linux-re/tooling/pr-verify/` to the bench and fix their paths (table in that README).
5. Build with `build-next.sh` (`defconfig asahi.config j716s.config j716s-gpu.config`; Fedora 43 container, clang,
   rustc 1.99.1; needs `openssl` for module signing). Expect release `7.3.0-26630-g…` and a device tree equal to
   the parked one before changing anything.
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

1. **VRR on the internal panel** (`appledrm.fw27_panel_vrr`): not ported. Upstream rewrote `dcp_flush` and
   `iomfb_modeset`; port from `j716s-daily` (swap watchdog, `dcp_modes_replace`, `dcp_get_modes`).
2. **Frame timing:** upstream scales swap timestamps to 24 MHz; the daily used a deadline override on this
   machine. No timeout in the short test; check under load.
3. **Tether:** the controller is there (`2a2280000.usb`, "not attached"). Test with the USB-A to C cable from the
   Mac Studio (USB-C to C fails).
4. **Audio in userspace:** PipeWire profile and speakersafetyd for the new card
   (`contrib/validated/desktop/audio/j716-profile`). Audio is not wired up correctly on the old daily either, so
   it does not block promotion.
5. **Never exercised on this branch:** suspend, external displays, USB4, camera, video decode/encode, ANE, ALS,
   lid angle.
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

## Also open in this checkout

Uncommitted changes that predate this work, left as they are for the owner to decide: six modified files under
`contrib/` (distro config, the aurora `j716s.config`, the audio profile) and untracked
`contrib/pending/boot-ab/firstboot/mk-stage1-0017-vars.diff` and `contrib/pending/input/`.
