# camera-v4l2-bridge

Gives apps that open `/dev/videoN` themselves (Monologue: Qt Multimedia's FFmpeg backend; `ffmpeg -f v4l2`; Chrome without
`#enable-webrtc-pipewire-camera`) the denoised picture from `../camera-denoise/`, without the camera or its green light staying on
while nobody uses it. It adds a second V4L2 camera, "FaceTime HD Camera (Clean)", that is fed from the PipeWire filter node
only while an app is streaming from it.

- Scope: `generic` (Apple silicon Mac with apple-isp and aurora-camera-denoise). Status: **staged, written offline, not run on a Mac**.
  Upstream target: aurora-silicon/alarm-aurora (a `v4l2-relayd` aarch64 package plus a `camera-denoise` option or unit); the loopback
  module is the open question (below).
- Everything below marked "unverified" was written without the Mac: confirm it with the test plan in
  `/Volumes/m5pro/bench/requests/camera-2.md`.

## How it works

    app --(open + STREAMON)--> /dev/video10  "FaceTime HD Camera (Clean)"   (v4l2loopback, exclusive_caps=1)
                                   ^ writer, always open, 1920x1080 YUY2
      v4l2-relayd  <- idle: black placeholder frame  |  active: pipewiresrc -> "FaceTime HD Camera" (aurora-camera-denoise)
                                                                                 -> /dev/video0 (only while streamed)

- Design copied from Intel's `v4l2-relayd` (IPU6): the relay holds the loopback's writer side open and subscribes to the module's
  `V4L2_EVENT_PRI_CLIENT_USAGE` event. The module sends it with count 1 when a reader does `VIDIOC_STREAMON` on the capture side and
  0 on `STREAMOFF`/close (checked in v4l2loopback 0.15.4 source: `client_usage_queue_event`). Merely opening the device does not
  count, so Qt/Chrome device enumeration (which opens every `/dev/video*`) does not start anything.
- Count 1 -> the relay sets its `pipewiresrc` pipeline to PLAYING: a PipeWire stream appears, `aurora-camera-denoise` opens
  `/dev/video0` and the light turns on. Count 0 -> pipeline NULL, the stream disappears, the filter closes the camera (its documented
  behaviour: it opens the camera only while an app streams) and a black placeholder frame is pushed.
- **Camera light:** off while idle (the relay never touches `/dev/video0`; only a PipeWire stream does). On from the first reader's
  STREAMON until its STREAMOFF/close, plus the filter's own close delay. Expect about 1 s from start to the first clean frame; a
  reader sees the black placeholder until then (unverified how long the last placeholder is held; the test plan checks).
- The relay is a per-user unit (PipeWire is per user). It needs the loopback device, so the clean camera exists only while the
  user is logged in and the unit runs. Before that the device node exists but does not list as a camera (`exclusive_caps=1`).
- `files/etc/wireplumber/wireplumber.conf.d/51-m5pro-camera-v4l2-bridge.conf` hides the loopback from PipeWire so portal apps do not
  see a duplicate and the bridge cannot feed itself. The property names it matches are unverified (WirePlumber 0.5 syntax).

## What the install needs (nothing is installed by `install.sh`)

| Need | Source | Note |
|---|---|---|
| `v4l2-relayd` | `pkg/PKGBUILD` (the AUR recipe, aarch64) | `makepkg -si` in `pkg/`; not built yet. AUR's own package is x86_64-only |
| `gst-plugin-pipewire`, `jq`, `pipewire` (`pw-dump`) | pacman | `pipewiresrc` is the camera input |
| `aurora-camera-denoise` | `../camera-denoise/` | installed on the J716s |
| **`v4l2loopback` kernel module** | see next section | **the one real blocker** |

### The kernel module

- `CONFIG_V4L2_LOOPBACK` does not exist: v4l2loopback is out of tree and not in mainline; `drivers/media` of `j716s-next7`
  has no copy (checked with `git grep`). So there is nothing to switch on in `j716s.config`, and no kernel build is needed *if* an
  out-of-tree module can be built for the running kernel.
- The kernel here has `CONFIG_MODULES=y` and the media core as modules (`CONFIG_MEDIA_SUPPORT=m`, `CONFIG_VIDEO_APPLE_ISP=m`), so a
  `v4l2loopback.ko` loads like `apple_isp` does.
- Option A, preferred (no kernel rebuild): build the module for the running kernel. `linux-m5pro` removes the `build` symlink, so
  `v4l2loopback-dkms` has nothing to build against unless the Mac has the kernel tree of the exact running release. Use
  `tools/build-v4l2loopback.sh` with `KDIR=` set to that prepared tree (same `.config`, `make modules_prepare`, same
  localversion), then it installs into `/usr/lib/modules/$(uname -r)/extra/` and runs `depmod`. The vermagic must match `uname -r`.
- Option B (when a kernel is built anyway): carry `v4l2loopback.c` (GPL-2.0) as `drivers/media/test-drivers/v4l2loopback/` in the
  j716s series with a `config V4L2_LOOPBACK` (`tristate`, `depends on VIDEO_DEV`) and `=m` in `j716s.config`. A pure module, no `=y` needed
  (the root file system needs no module for it, it loads after login/boot via `modules-load.d`).
- Option C: ask aurora-silicon/alarm-aurora to ship `v4l2loopback-dkms` with its kernel headers package.

## Which camera Monologue shows

Qt 6.8 FFmpeg backend (`qv4l2cameradevices.cpp`): walks `/dev` sorted by name (`video0`, `video1`, `video10`, ...), opens each
`video*` read-only, keeps those with `V4L2_CAP_VIDEO_CAPTURE` + `V4L2_CAP_STREAMING` that are not metadata nodes and list at least
one format it knows (YUYV is one), names each by its `card` string and marks the **first one as default**. The id is the device path.

- So "FaceTime HD Camera (Clean)" (`/dev/video10`) appears in Monologue's camera list by that name, next to the raw "FaceTime HD
  Camera" (`/dev/video0`). Pick it once in the app. The raw one stays the default (it sorts first), so a fresh Monologue profile
  still starts raw.
- Hiding `/dev/video0` is **not required**. It is also not free: the filter and every other user need it, and Qt skips a device only when `open()`
  fails. `video_nr` was set to 10 so the clean device never collides with the ISP's numbering; making it sort first would need
  `video_nr=0` and the module loaded before `apple_isp`, which is fragile and not done.
- Unverified: that Qt's format enumeration accepts the loopback's single YUYV 1920x1080 format and that `QV4L2Camera` negotiates it.

## Install / undo

    # prerequisites above, then on the Mac:
    sudo bash install.sh [USER] --dry-run
    sudo bash install.sh [USER]
    systemctl --user restart wireplumber        # applies the hide rule
    journalctl --user -u m5pro-camera-v4l2-bridge -n 20

    sudo bash install.sh --uninstall [USER]     # stops and disables, restores backups, unloads the module if unused

Installed: `/etc/modprobe.d/m5pro-camera-v4l2-bridge.conf`, `/etc/modules-load.d/m5pro-camera-v4l2-bridge.conf`,
`/etc/m5pro-camera-v4l2-bridge.conf` (settings: format, size, source), `/etc/systemd/user/m5pro-camera-v4l2-bridge.service`
(enabled for all users with `systemctl --global`), `/etc/wireplumber/wireplumber.conf.d/51-m5pro-camera-v4l2-bridge.conf`,
`/usr/local/libexec/m5pro-camera-v4l2-bridge`. Replaced files are kept once as `*.before-camera-v4l2-bridge`.
Quick off without uninstalling: `systemctl --user disable --now m5pro-camera-v4l2-bridge`.

## Notes and limits

- One fixed format (default 1920x1080 YUY2 30 fps), set in `/etc/m5pro-camera-v4l2-bridge.conf`; 1280x720 saves CPU.
  Cost on top of the filter's 9% of a core: NV12 to YUY2 conversion and two copies.
- `KEEP_FORMAT=0` (default, as Intel ships it): the device lists as a camera only while the bridge runs. `1` keeps format and listing
  across a bridge restart, but then the device also lists while the bridge is down and delivers no frames.
- v4l2loopback options are module-wide; OBS's virtual camera would need `devices=2` and its own `card_label` in the modprobe file.
- If the PipeWire node disappears while streaming (filter restart) the relay's input pipeline stops; `PartOf=` restarts the bridge
  with `aurora-camera-denoise`, the app must reopen the camera.
