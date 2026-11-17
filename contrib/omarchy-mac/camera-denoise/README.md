# camera-denoise

The built-in camera looks grainy on Linux because macOS cleans every camera frame after the ISP, and Linux did not.
macOS runs a motion-compensated temporal noise filter (VideoToolbox, on the video encoder's MCTF) on every camera stream.
The ISP itself is set up the same way on both systems: same firmware, same setfile, and the firmware's own module
calibration, defect-pixel, lens-shading, MBNR and temporal filters. This item installs Aurora's PipeWire filter that
does what macOS does: `aurora-camera-denoise`, the upstream alarm-aurora package (`pkg/`, pinned to camera-denoise
`aa7a42f`).

- Scope: `generic` (any Apple silicon Mac with apple-isp). Status: installed on the J716s 2026-11-17.
  Upstream: already in aurora-silicon/alarm-aurora; the J716s needs no board data (see below).
- What you get: a second camera, "FaceTime HD Camera", which is the filtered one and the PipeWire default. The raw camera
  stays as "FaceTime HD Camera (V4L2)". The filter opens the camera only while an app streams from it.
- Measured on the J716s (same frames, still scene, room light, mean luma 117): luma temporal noise p50 14.5 -> 2.1,
  frame-to-frame pixel noise 9.5 -> 0.5, chroma 2.8/2.4 -> 0.7/0.6. That is the same drop upstream measured on the
  M4 Pro against macOS (13.6 raw, 2.1 macOS, 2.4 filter). 29 fps through PipeWire, 9% of one CPU core.
  Report: `/Volumes/m5pro/bench/requests/camera-2.md`.

## Which apps get the clean picture

- **PipeWire apps** (through the camera portal, PipeWire or GStreamer `pipewiresrc`): yes, by default.
- **Chrome / Chromium**: only with the PipeWire camera on: `chrome://flags/#enable-webrtc-pipewire-camera` → Enabled,
  relaunch. Without it Chrome opens `/dev/video0` itself and gets the raw picture.
- **Apps that open `/dev/video0` directly** (Monologue: Qt Multimedia's FFmpeg backend; `v4l2-ctl`, ffmpeg): no. They
  bypass PipeWire, so they keep the raw, grainy picture.

## Install

    makepkg -f        # in pkg/, as the desktop user (the check() step runs the 10 upstream tests)
    sudo pacman -U aurora-camera-denoise-0.1.0-9-aarch64.pkg.tar.xz
    systemctl --user start aurora-camera-denoise    # the package's preset enables it for every user at login

## Check

- `pw-dump` / `wpctl status` lists two Video sources: "FaceTime HD Camera" (`aurora_camera_denoise.*`) and
  "FaceTime HD Camera (V4L2)".
- `journalctl --user -u aurora-camera-denoise` at the first stream: `temporal cpu, low light none` and `no gain report
  from /dev/video0, triggering on measured noise only`. Both are expected on the J716s: its kernel has no AVE MCTF
  device, so the filter runs on the CPU, and the T6050 driver does not report the sensor gain.
- `sudo tools/measure.sh` prints the noise of the raw camera and of the filter node (statistics only, no frame is kept).

## Undo

    systemctl --user mask --now aurora-camera-denoise     # off for you
    sudo pacman -R aurora-camera-denoise                  # off for everyone

## Notes

- No J716s section in `boards.conf`: without one the filter runs the temporal stage on every frame and nothing else.
  The low-light stage needs a backend that the J716s lacks (no `/dev/accel` Neural Engine device), and its gain trigger
  needs `V4L2_CID_GAIN`, which apple-isp exposes on T8140/T6040 only.
- `low-light-frame-rate = on` (the default) sets `exposure_dynamic_framerate=1` on the camera before it streams, so auto
  exposure may drop to 15 fps in the dark as on macOS. The control keeps that value for later direct-V4L2 apps until the
  driver reloads.
