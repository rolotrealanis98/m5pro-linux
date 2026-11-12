# j716s-next: the daily moved to current upstream (parked 2026-11-12)

State when parked: the kernel boots the J716s on firmware 27.3 with display, GPU, Wi-Fi, Bluetooth and
both sound cards. It is **not** the daily yet. The MacBook's `boot.bin` and `boot.bin.prev` are the old
daily (`629fc84c`).

## Where everything is

| What | Where |
|---|---|
| Branch `j716s-next` (25 commits on `aurora-silicon/linux` `integration/aurora` `107b3619a1bc`, tip `bf857188d078`) | repo `/Volumes/linux-cs/linux`, worktree `/Volumes/prv-build/wt-next` (**both on the 8TB drive**) |
| Copy that survives the 8TB format | `~/Documents/m5pro-next-park/` (internal disk, 100 MB, `SHA256SUMS.park`) |
| - the branch | `j716s-next.bundle` (needs upstream `107b3619a1bc`) and `patches/0001..0025` |
| - working kernel and modules | `kbuild-next/` (release `7.3.0-26630-g8bd0ee1b59b3`) |
| - working device tree | `dt/t6050-j716s-next-working.dtb` (`d5d733326d86d409`), built from the branch tip |
| - boot ingredients | `ingredients/` (the daily's loader slot, initramfs, `mk-daily.py`, the daily itself) |
| - scripts | `tools/` (`build-next.sh`, `mk-next-test.py`, `boot-next.sh`, DT `build.sh` / `mkvar.sh`) |
| - boot logs | `logs/run-next/` (this work), `logs/run-1174/`, `logs/run-1242/` |

Restore after the format: fetch `aurora-silicon/linux` `integration/aurora` into a kernel clone on a
**case-sensitive** volume, `git fetch ~/Documents/m5pro-next-park/j716s-next.bundle j716s-next:j716s-next`,
then put the scripts back (they hard-code `~/Work/agents/pr-verify`, `/Volumes/prv-build/wt-next`,
`/Volumes/prv-build/out-next`, and the bindgen at `/Volumes/linux-cs/wt-daily-dcp/tools/aurora-bindgen/build/bin/bindgen`;
`tools/aurora-bindgen/build.py` in the tree rebuilds it).

## What the branch is

Current upstream plus only what upstream does not have:

- **Display, firmware 27.3:** the full IOMFB method table and the 27.3 swap record on top of the merged
  #1174 (which refuses 27.3 with its 20 traced entries). EDR words are not sent on the 27.3 swap.
- **GPU, firmware 27.2 / 27.3:** the 26B123 and 26C5035 builds in upstream's per-build graph, the `J716S`
  board selected by the machine compatible, `aurora.m5_pause_timeout_us`, the #1242 recovery log.
- **Device tree:** `t6050-j716s.dts` with the J714s feature set (ProRes, JPEG, video decode and encode,
  camera, ANE, AOP with ALS and lid angle, external displays, the right port's USB4 router), the 16-inch
  panel and display engine, the GPU for this loader's hand-off, speakers and jack, boot NOR/NVRAM, the
  USB tether on the left-back port.
- **Small ones:** J716 macaudio entry with a -30 dB ceiling, s2idle with the adopted N1 link, the
  never-booted N1 guard, the SMC `gP` bank on T6050, the config fragment.

Build: `tools/build-next.sh` (`defconfig asahi.config j716s.config j716s-gpu.config`, needs `openssl` in the
container for module signing). Boot a test: `tools/boot-next.sh LABEL DTB` (installs as `boot.bin` only,
self-revert on); `NEXT_NOGPU=1` / `NEXT_NODISPLAY=1` drop a hand-off, `NEXT_EXTRA=" panic=0"` holds a panic
on screen.

## Verified on the machine (2026-11-12, one boot, a few minutes)

Display 3456x2234 at 120 Hz on 27.3; GPU InitData acknowledged by both coprocessors, `vkcube` and
`glmark2-es2-wayland` (score 983) clean; `wlan0` up; Bluetooth controller present; `aop_audio` and
`macaudio` cards with speakers enabled; backlight, battery, fans, Hyprland session.

## Findings worth keeping

- **This machine's loader stops at a `sep` alias** ("FDT: sep not found in devtree" -> "Failed to prepare
  FDT", proxy, watchdog fallback). No `sep` alias, SEP mailbox or `ps_sep` until the loader hands the SEP over.
- **The loader's GPU hand-off needs exactly four states** (`gpx`, `afr`, `cs`, `gfx`) in the GPU's PMGR node
  and one power domain labelled `gfx`; upstream describes three. Any mismatch leaves the GPU disabled, silently.
- **`apple,clpc` on the GPU node with `APPLE_CLPC=m`** makes the built-in GPU driver fail at "session" with
  ENODEV. The branch deletes the link for J716s (the daily has none).
- **Upstream bugs found** (candidates for PRs, check for ones in flight first):
  1. `t6050-j716s.dts` includes `t6050-peripherals.dtsi` last, which disables the N1's power states again.
  2. `mfd: macsmc` never registers `apple,smc-gpio` on T6050, so the J716s N1 `pwren-gpios` never resolves
     (no Wi-Fi on upstream J716s).
  3. `rust/bindings` duplicate and `DRM_ASAHI_M3_T8122` needing `APPLE_PMP`: only hit with our fragment.
- The exact #1174 head booted on the third try this morning; two earlier fast resets were never explained.

## Left to do, in order

1. **VRR on the internal panel** (`appledrm.fw27_panel_vrr`): not ported. Upstream rewrote `dcp_flush` and
   `iomfb_modeset`; anchors are in the display analysis (swap watchdog, `dcp_modes_replace`, `dcp_get_modes`).
2. **Frame timing check:** upstream scales swap timestamps to 24 MHz; the daily used a deadline override on
   this machine. No timeout seen in the short test; watch under load.
3. **Tether:** the controller is there (`2a2280000.usb`, "not attached"); test with the USB-A to C cable.
4. **Audio in userspace:** PipeWire profile and speakersafetyd for the new card (`contrib/validated/desktop/audio/j716-profile`).
5. **Not exercised:** suspend, external displays, USB4, camera, video decode/encode, ANE, ALS, lid angle.
6. **Decide:** CLPC (`APPLE_CLPC=y` plus the link) and the two idle parameters (`m5_idle_standby_us`,
   `m5_idle_hold`), neither ported.
7. **Needs J716s ADT values, not copied from J714s:** SD card reader, Touch ID, PMP and its tunables.
8. **Soak**, then promote: rebuild as a daily payload (no self-revert), keep the old daily as `boot.bin.prev`.
9. **`e2fsck` the root** (mounts "with errors").

## Ledger rows this moves (contrib/community/gap-map.csv, not edited: nothing is the daily yet)

`dist.upstream` (private stack drops from 269 commits on a Nov 7 base to 25 on current upstream);
`camera.isp`, `ane`, `video.decode`, `video.encode`, `video.jpeg`, `video.prores`, `display.external`,
`usb.thunderbolt`, `sensors.als`, `sensors.motion`: described in the device tree now, untested;
`audio.speakers`, `audio.jack`: on upstream's driver now, userspace open; `gpu.recovery`: #1242's log in.

## PRs

- `aurora-silicon/linux` #1174: merged 2026-11-12 (boot report: exact head refuses 27.3 at probe).
- #1242: open, not validated on hardware this round (9 min of stress produced no fault).
- #1173: draft; needs traced values. The branch carries its content privately.
- Before opening any new PR, check that nobody has the same change in flight.
