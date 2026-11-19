# camera-denoise

The built-in camera looks grainy on Linux because macOS cleans every camera frame after the ISP, and Linux did not.
macOS runs a motion-compensated temporal noise filter (VideoToolbox, on the video encoder's MCTF) on every camera stream.
The ISP itself is set up the same way on both systems: same firmware, same setfile, and the firmware's own module
calibration, defect-pixel, lens-shading, MBNR and temporal filters. This item installs Aurora's PipeWire filter that
does what macOS does: `aurora-camera-denoise`, the upstream alarm-aurora package (`pkg/`, pinned to camera-denoise
`aa7a42f`, plus one local patch, see "Post stage").

- Scope: `generic` (any Apple silicon Mac with apple-isp). Status: installed on the J716s 2026-11-17.
  Upstream: already in aurora-silicon/alarm-aurora; the J716s needs no board data (see below).
- What you get: a second camera, "FaceTime HD Camera", which is the filtered one and the PipeWire default. The raw camera
  stays as "FaceTime HD Camera (V4L2)". The filter opens the camera only while an app streams from it.
- Measured on the J716s (same frames, still scene, room light, mean luma 117): luma temporal noise p50 14.5 -> 2.1,
  frame-to-frame pixel noise 9.5 -> 0.5, chroma 2.8/2.4 -> 0.7/0.6. That is the same drop upstream measured on the
  M4 Pro against macOS (13.6 raw, 2.1 macOS, 2.4 filter). 29 fps through PipeWire, 9% of one CPU core.
  Report: `/Volumes/m5pro/bench/requests/camera-2.md`.

## Post stage and 60 Hz anti-flicker (pkgrel 10, staged 2026-11-19, not yet run on the camera)

The temporal filter leaves three things the owner saw on 2026-11-19 (camera-2 report): random black specks (1.3% of pixels per frame,
dark impulses, not fixed pixels), corners 4x noisier than the middle (lens-shading gain), coloured blotches at the edges.
`pkg/0001-post-stage-and-power-line.patch` adds a spatial stage after the temporal one, in place on the output frame (`src/post/`):

1. Speck removal: a pixel more than `post-impulse` (24) below the 2nd-darkest of its 8 neighbours becomes the middle of its 4 direct
   neighbours. Thin dark lines survive.
2. Radial luma denoise: edge-clipped mean over 13 taps; the clip level rises from `post-luma-clip-center` (6) to `post-luma-clip-edge` (22)
   with the cube of the distance from the centre, so the noisy corners are smoothed more and the middle keeps its detail.
3. Chroma denoise: 7x7 box blur of U and V, each sample moves towards it by an amount that fades to zero as the difference reaches the
   local clip level (`post-chroma-clip-center` 8 to `-edge` 24), so coloured edges stay.

Cost, measured offline with `aurora-camera-denoise-post-bench` (Mac Studio, arm64 NEON, 1920x1080 NV12, 200 frames): 0.44 ms speck
removal, 1.15 ms luma, 1.27 ms chroma, 2.8 ms all three, about 8% of one core at 30 fps (the temporal filter measured 9% on the J716s,
so about 17% together). Single thread, no extra latency beyond that. The J716s figure is in the camera-2 test (the filter logs
`ms post` per frame with `-v`).

Anti-flicker: `power-line = 60` in `/etc/aurora-camera-denoise/denoise.conf` (installed by the package, `backup`ed so edits survive
upgrades). The filter sets `V4L2_CID_POWER_LINE_FREQUENCY` before every stream; the control keeps its value for direct-V4L2 apps until
`apple_isp` reloads. No udev rule: a rule would have to open `/dev/video0` at device add, which is untested on apple-isp (it may power the
sensor and light the camera); the filter already opens the device at stream start for `exposure_dynamic_framerate`. Direct-only
use without the filter: `v4l2-ctl -d /dev/video0 --set-ctrl=power_line_frequency=2` once per boot.

Every number is a key in `denoise.conf` (`post`, `post-impulse`, `post-luma`, `post-luma-clip-center|edge`, `post-chroma`,
`post-chroma-clip-center|edge`, `power-line`); defaults are in `/usr/share/aurora-camera-denoise/examples/denoise.conf`.
Tuning: grainy corners left, raise `post-luma-clip-edge` (30); plastic skin or soft detail, lower `post-luma` (0.7) or the clip levels;
coloured blotches left, raise `post-chroma-clip-edge`; specks left, lower `post-impulse` (16). Off: `post = off`.
Source tree used for the patch: `/Volumes/m5pro/src/camera-denoise-work/` (pristine upstream next to it). Unit tests: `meson test -C build`
runs `post` (synthetic NV12 frames; impulses, radial noise, edges, NEON == scalar) and `config`.

## Which apps get the clean picture

- **PipeWire apps** (through the camera portal, PipeWire or GStreamer `pipewiresrc`): yes, by default.
- **Chrome / Chromium**: only with the PipeWire camera on: `chrome://flags/#enable-webrtc-pipewire-camera` → Enabled,
  relaunch. Without it Chrome opens `/dev/video0` itself and gets the raw picture.
- **Apps that open `/dev/video0` directly** (Monologue: Qt Multimedia's FFmpeg backend; `v4l2-ctl`, ffmpeg): no. They
  bypass PipeWire, so they keep the raw, grainy picture.

## Install

    makepkg -f        # in pkg/, as the desktop user (the check() step runs the upstream tests and the new `post` test)
    sudo pacman -U aurora-camera-denoise-0.1.0-10-aarch64.pkg.tar.xz
    systemctl --user start aurora-camera-denoise    # the package's preset enables it for every user at login

## Check

- `pw-dump` / `wpctl status` lists two Video sources: "FaceTime HD Camera" (`aurora_camera_denoise.*`) and
  "FaceTime HD Camera (V4L2)".
- `journalctl --user -u aurora-camera-denoise` at the first stream: `temporal cpu, low light none` and `no gain report
  from /dev/video0, triggering on measured noise only`. Both are expected on the J716s: its kernel has no AVE MCTF
  device, so the filter runs on the CPU, and the T6050 driver does not report the sensor gain.
- `sudo tools/measure.sh` prints the noise of the raw camera and of the filter node (statistics only, no frame is kept), including
  temporal sd by radius and dark impulse outliers per frame.
- `journalctl --user -u aurora-camera-denoise`: `post stage on` per camera; with `-v` the stats line gives `ms post` per frame.
- `v4l2-ctl -d /dev/video0 --get-ctrl=power_line_frequency` is 2 after the first stream (1 was the 50 Hz default).

## Undo

    systemctl --user mask --now aurora-camera-denoise     # off for you
    sudo pacman -R aurora-camera-denoise                  # off for everyone
    # only the post stage and 60 Hz off, keeping the temporal filter: in ~/.config/aurora-camera-denoise/denoise.conf
    #   [denoise]  post = off  /  power-line = off     then: systemctl --user reload aurora-camera-denoise
    # back to the previous package (no post stage): sudo pacman -U aurora-camera-denoise-0.1.0-9-aarch64.pkg.tar.xz

## Notes

- No J716s section in `boards.conf`: without one the filter runs the temporal stage on every frame and nothing else.
  The low-light stage needs a backend that the J716s lacks (no `/dev/accel` Neural Engine device), and its gain trigger
  needs `V4L2_CID_GAIN`, which apple-isp exposes on T8140/T6040 only.
- `low-light-frame-rate = on` (the default) sets `exposure_dynamic_framerate=1` on the camera before it streams, so auto
  exposure may drop to 15 fps in the dark as on macOS. The control keeps that value for later direct-V4L2 apps until the
  driver reloads.
