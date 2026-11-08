# HDR10 / EDR and 10-bit output on the J716s XDR panel (T6050, DCP firmware 27.3)

Status (2026-11-08): study + kernel series + test payload; nothing has run on hardware yet. Study only: no ssh, no
MacBook access, nothing pushed or committed in this repository. The kernel branch `j716s-hdr` (on `j716s-video-observe`
@ 0933f881d736 = the daily's kernel 7.3.0-g0933f881d736) carries the three patches in `patches/`. Private runner,
payload and build under `~/Work/agents/hdr/`.

Build volume note: the branch was first checked out as the worktree `/Volumes/linux-cs-gpurec/wt-hdr`, as asked. At
15:09 UTC the gpurec disk image (`gpu-recovery/vol/linux-cs-gpurec.sparsebundle`) stopped serving data: every read on
the volume (all worktrees, host and container) returns ENXIO "Device not configured", `fsck_apfs -n` cannot freeze it,
`diskutil unmount` is dissented by kernel_task, and only the DiskImages daemon holds it. Cause: four concurrent container
builds (this one plus other sessions' `kavd`, `ksep`, `ktbr2`, `hlfix`) drove the system file table to `kern.maxfiles`
(524288; the build log has eight "Too many open files in system" retries), and a sparsebundle's DiskImages daemon does
not recover from ENFILE. A private sparsebundle (`~/Work/agents/hdr/vol/linux-cs-hdr.sparsebundle`) died the same way on
the retry; the home volume is case-insensitive (13 netfilter files collide). The build therefore runs on a **named
container volume** `hdr-build` (`container volume create -s 48G hdr-build`: a disk inside the VM, mounted at `/build`),
with the worktree checked out inside the container at the branch tip. A force detach of the gpurec image is Rolando's
call (not done); the dead `wt-hdr` records (`/Volumes/linux-cs-gpurec/wt-hdr`, `/Volumes/linux-cs-hdr/wt-hdr`) in
`/Volumes/linux-cs/linux/.git/worktrees/` wait for `git worktree remove --force` once those volumes are back or gone.

## 1. Where the gate is (question 1)

Aurora's HDR/EDR work is **already in our base**. `git log integration/aurora..` shows the merges of #764 (HDR10 static
metadata, 437edfa19494), #777 (panel EDR, a20c29ae72db), #789 (GNOME HDR: PQ_REFERENCE_LUMINANCE, SDR on master exit,
InfoFrame stop, 9d04a2245218), #796 (external HDR hints, c869c99968b0) and #986 (EDR cap at the ADT headroom,
43f112d09ac0). No cherry-pick is needed. Our connector shows no properties because **every HDR path is keyed to the
desktop 26.x firmware enum, and the J716s runs `DCP_FIRMWARE_V_27_0`**:

| Gate | Where | Test | fw 27 result |
|---|---|---|---|
| Connector properties `Colorspace`, `HDR_OUTPUT_METADATA`, `PQ_REFERENCE_LUMINANCE` | `apple_drv.c:950-979` `apple_connector_attach_hdr(conn, panel_edr)`; `panel_edr = dcp_fw_compat_is_desktop(dcp)` (`apple_drv.c:1022`) | eDP returns early unless `panel_edr`; `dcp_fw_compat_is_desktop()` (`dcp.c:3443`) is `fw_compat == DCP_FIRMWARE_V_26_6_DESKTOP` | **no properties** (the sysfs listing you saw) |
| PQ colour element at a mode set | `iomfb.c:2551 dcp_hdr_output_supported()` | 26.6 desktop or H17P external | SDR only |
| PQ content as EDR on the panel | `iomfb.c:2563 dcp_panel_edr_supported()` | 26.6 desktop && panel && `peak_nits` | off |
| Panel peak luminance (`iomfbep_max_panel_brightness`, A128) | `iomfb_template.c` `res_max_panel_brightness()`/`init_3()` under `#if DCP_FW_DESKTOP_26` | compiled only for the desktop template | `peak_nits` stays 0, so the synthesised EDID (`dcp.c:1080`) has no HDR block either |
| ADT EDR ceiling (`EDRPotentialHeadroom`) | `dcp.c:921 dcp_panel_adt_identity()` | `if (desktop)` | not read |
| EDR swap fields (brightness x headroom, scale, headroom used, limit) | `iomfb_template.c` `dcp_edr_prepare()` under `#if DCP_FW_DESKTOP_26`, fields in the desktop swap record (`iomfb_template.h:78-101`) | desktop swap record only; `struct dcp_swap_v27` (`iomfb_v27.h`) has `brightness_update`/`brightness_nits` at the same offsets (0x354/0x35e) and the rest reserved | never sent |
| `max bpc` | nowhere: the driver never attaches it | the link depth is the firmware's highest-scored SDR RGB element (`parser.c parse_color_modes()`, `fill_color_mode()` keeps the best score with depth <= 10) | 8-bit "Default RGB" (`depth:8 format:0 colorimetry:16 eotf:0`) |

Not a Kconfig, not an EDID read, not the `fw27_*` parameters (those only touch VRR). It is the per-firmware enum. The
firmware-27 port (d41eec728de7) and the VRR patch (bd53915f2ef1) added no colour handling.

Two facts for reading the DCP log: the colour-mode line's `eotf` is the DCP enum (`parser.h:57`): **0 = SDR gamma, 1 =
"HDR gamma", 2 = ST 2084 (PQ), 3 = HLG**, so an HDR10 link shows `eotf:2`, not 1. `colorimetry:16` is "Default RGB";
BT.2020 RGB is 9. `format:0` is RGB.

## 2. What the firmware offers this panel (question 2)

The driver never lists the colour elements in dmesg: each `TimingElements` entry carries a `ColorModes` array (keys
`Colorimetry`, `Depth`, `DynamicRange`, `EOTF`, `ID`, `PixelEncoding`, `Score`, `IsVirtual`), parsed once when the
firmware publishes the mode list at boot (`iomfb.c dcp_modes_replace()` -> `enumerate_modes()`), and each element only
reaches the `dcp:iomfb_color_mode` tracepoint. The parser keeps per timing: `sdr_rgb` (best-scored RGB SDR, depth <= 10),
`sdr_444`, `sdr`, `best`, and `pq` (a PQ element that is BT.2020 RGB full-range or BT.2020 YCbCr 4:4:4, 10-bit
preferred, not in the timing's `UnsafeColorElementIDs`/`DSCRequiredColorElementIDs`). What we know today: for the
3456x2234@120 timing the chosen `sdr_rgb` is **depth 8**, so either no 10-bit RGB SDR element exists or it scores lower
than the 8-bit one. Whether a PQ element exists is unknown.

How to find out (either):
- the test payload boots with `appledrm.log_color_modes=1` (patch 0001): dmesg lists `colour element <id>: score ..
  depth .. colorimetry .. eotf .. range .. encoding ..` for every element and a `timing <id>: WxH R Hz .. colour sdr_rgb
  <id> (depth N) sdr_rgb10 <id> .. pq <id> (depth N)` summary per timing;
- without the new kernel: the daily kernel with `trace_event=dcp:iomfb_color_mode,dcp:iomfb_timing_mode tp_printk`
  added to the bootargs prints the same tracepoints into dmesg (payload rebuild, no kernel build).

macOS side (`~/Work/studio-artifacts/macos-27.3/m5-ioreg-l.txt`, names only): the panel's ADT backlight node has
`EDRPotentialHeadroom = <00001000>` = 16.0 in 16.16, the XDR's EDR ceiling (`dcp_edr_ceiling()` would make that 16.000);
the ioreg dump has no per-element colour-mode list (`ColorElements` appears once as a key name only).

EDID: no dump exists under `~/Work/studio-artifacts/`. The connector's EDID is **synthesised by the driver**
(`dcp-display-metadata.c dcp_panel_edid()`, "APP" + P3 primaries from `apple,color-gamut`), and the CTA extension with
the BT.2020 colorimetry and HDR static metadata blocks is only appended when `peak_nits` is known, so today's EDID has
none. The runner dumps `/sys/class/drm/<card>-eDP-*/edid` to `remote/edid.bin` and runs `edid-decode` on both sides if
installed; by hand: `cat /sys/class/drm/card1-eDP-2/edid > edid.bin; edid-decode edid.bin`.

## 3. Hyprland 0.57.1 / aquamarine 0.16.0 / Mesa (question 3)

Read from the tags (`hyprwm/Hyprland` v0.57.1 acc1aa0b, `hyprwm/aquamarine` v0.16.0 b77d6764):

- **Config is Lua; there is no `hyprctl keyword`** (`src/ipc/s1/Commands.cpp` registers `eval`, not `keyword`).
  `hyprctl eval 'hl.monitor({ output = "eDP-2", bitdepth = 10 })'` applies live: `hl.monitor` merges the fields into the
  existing rule for that output and schedules a monitor-state refresh (`LuaBindingsConfigRules.cpp hlMonitor()`).
  `hyprctl reload` re-reads `hyprland.lua` and the profile, undoing an eval override.
- Monitor rule fields (`LuaBindingsConfigRules.cpp:113-175`): `bitdepth` (8|10), `cm` = `auto|srgb|wide|edid|hdr|hdredid|
  dcip3|dp3|adobe`, `sdr_eotf`, `sdrbrightness` (1.0), `sdrsaturation` (1.0), `supports_wide_color` (-1/0/1 override of the
  EDID BT.2020 flag), `supports_hdr` (-1/0/1 override of the EDID PQ flag), `sdr_min_luminance` (0.2), `sdr_max_luminance`
  (80), `min_luminance`, `max_luminance`, `max_avg_luminance`, `icc`, `vrr`.
- Global: `render:cm_enabled` (default true, "requires restart"; gates the `wp_color_management_v1` protocol),
  `render:cm_auto_hdr` (0 off, 1 switch to `hdr` when the fullscreen surface is HDR, 2 `hdredid`), `render:send_content_type`,
  `misc:screencopy_force_8b`. **`render:cm_fs_pass` and `experimental:xx_color_management_v4` do not exist in 0.57.1**
  (the experimental protocol is gone; the stable one is on).
- 10-bit: `bitdepth = 10` sets aquamarine `maxBpc` 10 (8 otherwise) and tries `XRGB2101010` then `XBGR2101010` with a
  TEST_ONLY commit (`Monitor.cpp:924-931`, log `output eDP-2 (succeeded|failed) basic test on format DRM_FORMAT_XRGB2101010`),
  else falls back to 8-bit. `hyprctl monitors -j` shows it as `currentFormat`.
- HDR: `cm = hdr` builds a PQ/BT.2020 image description and sends `HDR_OUTPUT_METADATA` + `Colorspace` BT2020_RGB
  (`Renderer.cpp handleFullscreenSettings()`), **only if `supportsHDR()`**: EDID BT.2020 (or `supports_wide_color = 1`) and
  EDID HDR static metadata with PQ (or `supports_hdr = 1`). A fullscreen HDR surface (mpv with the colour-management hint)
  supplies its own metadata when direct scanout is active, else `cm_auto_hdr` switches the output. "Wide color gamut is
  enabled but the display is not in 10bit mode" is logged when `cm` is wide/hdr at 8 bits.
- aquamarine (`Props.cpp`, `impl/Atomic.cpp:233-251`): reads `max bpc`, `Colorspace`, `HDR_OUTPUT_METADATA` from the
  connector and commits them **only when the connector has them**; otherwise it logs `failed to commit hdr metadata: no
  HDR_OUTPUT_METADATA prop support` and the output stays SDR. `AQ_NO_MODIFIERS=1` (`DRM.cpp:745, 1671`) keeps every plane
  format with LINEAR + INVALID modifiers, so `XRGB2101010` (offered by apple-drm on fw 27: `supports_xrgb2101010` is true for
  everything but H17P, `apple_drv.c:1072`, `plane.c:664`) is offered; explicit sync is independent of the format.
- Mesa: the session renders through zink on Honeykrisp (Aurora Mesa `agx3c`); the scanout buffers are GBM allocations
  on the render node imported into the apple card. Whether Honeykrisp/GBM gives an `XR30` LINEAR scanout buffer and a
  10-bit render target is not verified anywhere on the Studio (no vulkaninfo dump mentions `A2R10G10B10`). Hyprland's
  format test answers it in one commit; the runner reads the result.
- mpv: `--vo=gpu-next --target-colorspace-hint=yes` (Wayland colour management needs mpv >= 0.40 built with libplacebo);
  the runner falls back to `--vo=gpu`. mpv/ffmpeg are not in `contrib/pending/gpu/userspace/packages.txt`; the runner
  checks and reports.

What exists today without any kernel change: the 10-bit **framebuffer** half of rung (a) (`bitdepth = 10` through
`hyprctl eval`, format test included), on an 8-bit link; no HDR (no properties, so aquamarine refuses the metadata).

## 4. The ladder (question 4)

| Rung | Kernel | Hyprland | Verify | Risk |
|---|---|---|---|---|
| **0** colour elements | patch 0001 + `appledrm.log_color_modes=1` | none | dmesg `colour element`/`timing` lines; connector props in `/sys/kernel/debug/dri/<n>/state`; EDID dump | none (log only) |
| **(a)** 10-bit SDR link | patch 0002 + `appledrm.fw27_panel_depth10=1`: `max bpc` 8-10 on the eDP connector; max bpc >= 10 selects the timing's 10-bit SDR RGB element (`sdr_rgb10`) | `hl.monitor({ output = "eDP-2", bitdepth = 10 })` -> aquamarine sets `max bpc` 10 (a mode set, DRM core) and the XRGB2101010 swapchain | `set_digital_out_mode() color mode depth:10 format:0 colorimetry:.. eotf:0`; `hyprctl monitors -j` `currentFormat` XRGB2101010; `hyprland.log` `succeeded basic test on format DRM_FORMAT_XRGB2101010` | the mode set is the same call as today with another colour id; a refused id fails the commit (Hyprland falls back to 8-bit, the old mode stays). If no 10-bit element exists the link stays 8-bit and only the framebuffer is 10-bit (the DCP dithers) |
| **(b)** HDR10 | patch 0003 + `appledrm.fw27_panel_hdr=1`: connector props; a PQ commit selects the PQ element if listed (`eotf:2`), else is refused unless EDR; RGB surfaces tagged BT.2020 + PQ (`DCP_XFER_FUNC_PQ`); A128 peak query; ADT ceiling; EDID HDR block when the peak comes back | `hl.monitor({ output = .., bitdepth = 10, cm = "hdr", supports_wide_color = 1, supports_hdr = 1 })` (the overrides stand in for the EDID block until the peak is known); mpv `--vo=gpu-next --target-colorspace-hint=yes --fs` on a PQ/BT.2020 `testsrc2` clip | `eotf:2` in the mode-set line (true PQ link) **or** `output_edr` path (SDR link, PQ surfaces); `[CM] Updating HDR metadata` in `hyprland.log`; no `failed to commit hdr metadata`; photo of the pattern | each HDR on/off is a mode set (~385 ms dark, as a VRR toggle). A PQ element the firmware lists but refuses wedges the mode set -> `set_digital_out_mode timed out`; the payload is self-reverting and the runner restores the daily. A128 unknown to fw 27 = an error reply, peak stays 0, EDR stays off |
| **(c)** EDR headroom | patch 0003 + `fw27_panel_edr=1` at runtime (`/sys/module/appledrm/parameters/fw27_panel_edr`): requires the A128 peak; EDR fields in the fw-27 present record at the desktop offsets (0x358 flags, 0x376 limit, 0x37e scale, 0x3e6 headroom; 27.3's gaps move them with the rest) | HDR off/on again (cm srgb -> hdr), the clip again | `panel peak luminance N nits` at boot; brighter highlights than SDR white on the pattern (photo); **no** `swap failed`/`swap timed out`; the present rate while idle stays low (a brightness fight between the H17P backlight state machine and the EDR override would show as a present storm, which the runner counts) | **experimental**: the fields are unverified on fw 27 (reserved bytes in the record macOS 27.3 uses). A rejected swap is retired by the present-failed path; the worst case is a dark panel until the self-revert |

Cost: one kernel build (done by `build-kernel-hdr.sh`, ~12 min in the container), one payload, one attended boot with
two reboots (test, restore) of about 2-8 min each. Rungs (a)-(c) run inside that one boot.

**Rung (a) without a reboot: no for the link, yes for the framebuffer.** The link depth is the firmware's score until
patch 0002 exists on the running kernel, and the daily has no `max bpc`. `run-hdr-test.sh --session-only` does the
Hyprland half on the current daily (bitdepth 10, then cm hdr to see the refusal) and reverts; no payload, no reboot.

## 5. The series (question 5) and the test payload

`patches/` (branch `j716s-hdr`, `git format-patch 0933f881d736..`; `checkpatch --strict`: 0 errors, 0 warnings, two
pre-existing style checks):

1. `0001 drm/apple: Log the colour elements of each timing when asked` - `appledrm.log_color_modes` (0644).
2. `0002 drm/apple: Offer a 10-bit SDR link on the firmware 27 panel through max bpc` - `appledrm.fw27_panel_depth10`
   (0644; the property is created at probe, the preference is read at each mode set). Parser keeps `sdr_rgb10`; the
   generic IOMFB mode set picks it when `depth10_requested` (connector `max_requested_bpc >= 10`); a PQ request wins. The
   property is created directly (`drm_connector_attach_max_bpc_property()` writes a connector state that
   `drm_mode_config_reset()` has not made yet at connector creation); a fresh state reads 0 = 8. The fw-27 VRR re-select
   goes through the same mode set, so it keeps the depth.
3. `0003 drm/apple: Open the HDR and EDR paths on the firmware 27 panel, opt-in` - `appledrm.fw27_panel_hdr` (0444) and
   `appledrm.fw27_panel_edr` (0644, runtime). The EDR step logic moves from `dcp_edr_prepare()` into `dcp_edr_plan()`
   (shared), the binary64 helpers into `dcp-edr.h`; `dcp_edr_present_v27()` writes the plan into `dcp_swap_v27`;
   `dcp_backlight_present_nits()` gives the SDR level a present stands on. Desktop 26.x behaviour is unchanged (same
   values, same fields). The DCPAV HDR-metadata path (`dcp->desktop`) stays NULL on fw 27, so the InfoFrame calls are
   no-ops, as they should be for a panel.

Nothing in the series changes the DT or the config; the DTB of the build is byte-identical to the daily's.

Built 2026-11-08 15:40 UTC: kernel `7.3.0-g7cf4279b444b` (Image.gz sha256 8ab0ff05..., the daily config unchanged, 20
build warnings = the daily's, none in apple-drm, DTB 4a8cfe25 = the daily's video-observe DTB), modules
`modules-7.3.0-g7cf4279b444b.tar.zst`, payload `hdr-test-20261108-41539cf4.bin` (sha256 41539cf4..., 42 MB, loader
fb29185c, initramfs abb47165, bootargs = the daily's + `appledrm.log_color_modes=1 appledrm.fw27_panel_depth10=1
appledrm.fw27_panel_hdr=1`, `m5.selftest=1`, battery on). Run: `~/Work/agents/hdr/run-hdr-test.sh
~/Work/agents/hdr/hdr-test-20261108-41539cf4.bin` (attended: the payload has the battery driver, and the photo windows).

Private files (`~/Work/agents/hdr/`, 0600/0700, not in this repository):
- `build-kernel-hdr.sh` - the container build (template `video-observe/build-kernel-video.sh`): worktree
  `/build/wt-hdr` and object dir `/build/wt-hdr-out` on the named volume `hdr-build`, results `kbuild-hdr/`, config = the daily's `kbuild-video/config` with an
  empty diff enforced, 5 GiB guard on the volume, a wait while `kern.num_files` is near the limit, modules tarball from the daily list, `appledrm-params.txt` lists the built-in
  parameters.
- `mk-hdr-test.py` - the payload (template `mk-video-observe2-test.py`): label `hdr-test`, loader
  `m1n1-plain-n1-dt-gpu-dcp-phfix-ave.bin` (fb29185c, pinned), the daily's initramfs and bootargs plus
  `appledrm.log_color_modes=1 appledrm.fw27_panel_depth10=1 appledrm.fw27_panel_hdr=1`, `m5.selftest=1` (self-revert
  to `boot.bin.prev` if the network is not up in 90 s), battery on (attended boot). It refuses a build whose release is
  the daily's or whose DTB differs from the daily's.
- `run-hdr-test.sh` - the runner (template `run-video-observe2.sh`): modules install if missing, `esp-put.sh` write,
  reboot + probe, then the MacBook-side `hdr-rungs.sh` as root (Hyprland instance found as `hypr-dcp-verify` does):
  rung 0 facts (colour elements, connector props, EDID, `hypr-dcp-verify --static`), (a) `bitdepth = 10`, (b) `cm = "hdr"`
  + the PQ clip (ffmpeg `testsrc2` + `zscale` to PQ/BT.2020, 1280x720 12 s; libx265, then libx264 10-bit, then ProRes;
  mpv gpu-next with the hint, then gpu without), (c) `fw27_panel_edr=1`, HDR again, the clip again, present-rate and
  swap-failure counts, back to 0; revert of the monitor rule; restore of the daily
  `daily-dcp-rec-video-20261108-26ca25f0.bin` (sha256 pinned) and reboot. `PHOTO NOW (n s)` lines mark the windows.
  `--session-only` runs rungs (a)/(b) on the running kernel without a payload.

## 6. Open points

- Whether the fw-27 panel lists a 10-bit SDR element and a PQ element: rung 0 answers; both patches 0002/0003 degrade
  to "nothing selected" without them.
- A128 on firmware 27: the method tag is pushed like any other; an unknown tag answers with an error and the peak stays
  0 (EDR off, EDID without the HDR block; Hyprland then needs the two `supports_*` overrides, which the runner sets).
- The EDR fields' validity on fw 27 and the interaction with the H17P backlight state machine (the EDR plan overrides
  the nits the state machine put in the present). If rung (c) shows a present storm or a dim desktop, the next step is
  a macOS 27.3 swap capture of an HDR session on the J716s, not more guessing.
- Direct scanout stays off in the session (`AQ_NO_MODIFIERS=1`), so the mpv HDR surface is composited: Hyprland's own
  PQ metadata path (`cm = hdr`) is what is tested, not the surface's metadata.
- True Tone / ALS and Night Shift are outside this (gap map row "HDR/EDR, 10-bit output").
