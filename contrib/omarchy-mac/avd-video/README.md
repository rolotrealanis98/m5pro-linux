# avd-video

Scope: t6050 (the libva alias is generic for Aurora kernels). Status: installed 2026-11-17, waiting for the first boot with
the AVD firmware (`/usr/lib/firmware/apple/avd-fw-v5-t2.bin`, see `INVENTORY.md` "AVD firmware v5-t2" and
`/Volumes/m5pro/bench/requests/avd-1.md`). Queue doc: `/Volumes/m5pro/bench/requests/gpu-video-2.md`.

## The path

`apple-avd` (kernel, `2309080000.avd`, t6050 variant with `AVD_QUIRK_NO_RECOVERY_RESET`) is a **stateless V4L2 decoder**
(Media Request API: `/dev/videoN` + `/dev/mediaN`, H.264, HEVC, VP9, AV1). Userspace reaches it through VA-API:

    mpv / Chrome / ffmpeg -> libva -> v4l2_request_drv_video.so (omacom/libva-v4l2_request, AVD fork) -> /dev/media + /dev/video (avd)

- libva picks the driver from the render node's DRM driver name. On Aurora kernels that is `aurora`, so it loads
  `aurora_drv_video.so`. Omarchy's `libva-v4l2_request-avd` (1.3.r11.r169.gc653eaa) only ships the `asahi_` and
  `v4l2_request_` names, which is why Chrome logged `vaInitialize failed: unknown libva error` (no driver at all, before the
  AVD firmware even matters). alarm-aurora's package ships the `aurora_` alias (alarm-aurora#142).
- mpv: `/etc/mpv/mpv.conf` (Omarchy) already has `hwdec=auto-safe`, which includes `vaapi`, so once the driver loads mpv
  uses the AVD with no config change.
- Chrome 157: VA-API is on by default on Linux; with the alias the GPU process gets the driver (omarchy-mac#763 shows Chrome
  156 on an M1 Pro using `VaapiVideoDecoder` with stock Omarchy flags). AV1 in Chrome needs omacom/libva-v4l2_request#114
  (alarm-aurora#330): without it Chrome's AV1 decode fails at `vaEndPicture` and falls back to dav1d; YouTube serves AV1.
- Not used: ffmpeg's own `v4l2request` hwaccel (stock ALARM ffmpeg 9.0 does not have it; alarm-aurora#82 `ffmpeg-avd`/`mpv-avd`
  was closed), `h264_v4l2m2m` (stateful API, AVD is stateless), GStreamer `v4l2slh264dec` (in `gst-plugins-bad-libs`, but the
  parsers are in `gst-plugins-bad`, not installed).

## What is installed on the Mac

| Path | What | Undo |
|---|---|---|
| `/usr/lib/dri/aurora_drv_video.so` | symlink -> `v4l2_request_drv_video.so` (owned by no package; survives package updates) | `rm` it |
| `/opt/libva-avd-av1/dri/v4l2_request_drv_video.so` | alarm-aurora#330 build (Chrome AV1 fixes), side by side; used only with `LIBVA_DRIVERS_PATH=/opt/libva-avd-av1/dri LIBVA_DRIVER_NAME=v4l2_request` | `rm -r /opt/libva-avd-av1` |
| `pkg:libva-utils` | `vainfo` (pacman -S --needed) | `pacman -R libva-utils` |
| `/home/rolo/gpu-ab/avd/` | `avd-next-boot.sh`, `play.html`, `clips/` (silent synthetic H.264/HEVC/VP9/AV1, made by `gen-clips.sh`), the built package `libva-v4l2-request-avd-1.3.r11-2-aarch64.pkg.tar.xz` | `rm -r` it |

## After the next boot (attended, silent)

    sudo bash /home/rolo/gpu-ab/avd/avd-next-boot.sh          # or one stage: kernel | vainfo | ffmpeg | mpv | chrome

Gates in order, stopping at the first AVD error in dmesg (`recover`, timeout, firmware error): kernel probe and the avd node
with its OUTPUT formats; `vainfo` with automatic discovery; ffmpeg VA-API vs software frame MD5 for each codec (plus AV1 with
the #330 driver); mpv windowed 8 s per clip with `hwdec=vaapi` and `hwdec=no` (CPU time for each; watch for green frames);
Chrome in a test profile playing `play.html` muted (decoder in the log, GPU-process CPU, `/dev/media` open in the GPU process).
Result: `/home/rolo/gpu-ab/avd/run-*/summary.txt`.

### Result (first boot with the firmware, 2026-11-17)

AVD up (`booting hw version: 40020`, open-queue transport, 7 frames in flight, `/dev/video13` + `/dev/media0`), vainfo by
automatic discovery: H.264 CB/Main/High, HEVC Main/Main10, VP9 0/2, AV1 0. ffmpeg VA-API output pixel-identical to software
for every clip with both drivers; mpv `hwdec=vaapi` (and the default auto-safe) uses the AVD at ~1/10 the CPU. Chrome
(`chrome-gpu-ab/video-ab.sh`, test profile, workspace 5): H.264/HEVC/VP9 on the AVD with the packaged driver (2-3% of a
core); AV1 falls back (`vaEndPicture failed`, 84% of a core). With the #330 driver: AV1 on the AVD (2%), H.264/HEVC/VP9
unchanged, 0 dropped frames.

### Making the #330 driver Chrome's (recommended; owner's call, not done)

Install the package: it `replaces` Omarchy's `libva-v4l2_request-avd` and ships the same `aurora_` alias, so remove the hand
alias first (pacman would report a file conflict):

    sudo rm /usr/lib/dri/aurora_drv_video.so
    sudo pacman -U /home/rolo/gpu-ab/avd/libva-v4l2-request-avd-1.3.r11-2-aarch64.pkg.tar.xz
    # then restart Chrome; check chrome://media-internals on a muted YouTube AV1 video: VaapiVideoDecoder
    # undo: sudo pacman -S libva-v4l2_request-avd && sudo ln -s v4l2_request_drv_video.so /usr/lib/dri/aurora_drv_video.so

System-wide (mpv/ffmpeg get it too; ffmpeg is pixel-identical on all codecs with it). It stays installed across updates
(local package; `provides` covers anything depending on the Omarchy name). Chrome-only alternative without a package change:
a `~/.local/share/applications/google-chrome.desktop` copy whose `Exec=` starts with
`env LIBVA_DRIVERS_PATH=/opt/libva-avd-av1/dri LIBVA_DRIVER_NAME=v4l2_request` (works only for launches through the
desktop file; chrome-flags.conf cannot set environment). When omacom/libva-v4l2_request#114 merges and Omarchy ships it,
go back to Omarchy's package.

## Build

`build-libva-avd.sh`: alarm-aurora `packages/libva-v4l2-request-avd` at PR #330 head `a872d7ac5d3d` in an Arch Linux ARM
container on the Studio, plus `provides/conflicts/replaces=libva-v4l2_request-avd`. 244/244 meson tests. Recipe and output:
`/Volumes/m5pro/bench/avd/libva-av1/` (`SHA256SUMS`: package `d889c95b…`, driver `4e47adcb…`).

Upstream: the alias belongs in Omarchy's `libva-v4l2_request-avd` package (omacom/omarchy-pkgs: add `aurora_drv_video.so`
like alarm-aurora#142); the AV1 fixes are omacom/libva-v4l2_request#114.
