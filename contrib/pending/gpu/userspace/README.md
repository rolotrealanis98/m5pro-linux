# Software-rendered desktop on the J716s (no GPU driver)

Nothing here has run on the M5 yet. Written 2026-11-04 against Omarchy 4
(omacom/omarchy `quattro`, Hyprland 0.56 Lua config), Arch Linux ARM and the
omarchy-m5 kernel (simpledrm on the m1n1 framebuffer, no modules in the root).

## What the stack is

```
app (GL/GLES/Vulkan) -> Mesa llvmpipe / lavapipe (CPU, all 18 cores)
       |  wl_shm or linux-dmabuf (udmabuf)
Hyprland (aquamarine) -> GBM + EGL on card0 = simpledrm -> Mesa kms_swrast + llvmpipe
       |  dumb buffer, atomic commit
simpledrm -> CPU copy of the damaged rectangles into the iBoot framebuffer
       |  (scanned out by DCP, which iBoot left running)
panel: one fixed mode, 3456x2160 (29,859,840-byte framebuffer at 0x10bd16edc00)
```

Mesa needs no setting to get here: simpledrm has no Mesa driver, so GBM falls
back to `kms_swrast` and llvmpipe. Omarchy 4 then detects the llvmpipe
renderer at session start (`omarchy-hw-software-rendering`) and turns
animations, blur and shadows off for that session.

## Files and install paths on the Arch root

| file here | install to | what it does |
|---|---|---|
| `packages.txt` | (pacman list) | `sudo pacman -S --needed $(grep -v '^#' packages.txt \| awk '{print $1}')` |
| `uwsm/env.d/90-m5-softrender` | `~/.config/uwsm/env.d/90-m5-softrender` | pins llvmpipe and lavapipe for the uwsm-started Hyprland session |
| `environment.d/90-m5-softrender.conf` | `/etc/environment.d/90-m5-softrender.conf` | same variables for sessions not started by uwsm (sway from a TTY) |
| `hypr/m5-softrender.lua` | `~/.config/hypr/m5-softrender.lua` + `require("hypr.m5-softrender")` after `require("hypr.looknfeel")` in `~/.config/hypr/hyprland.lua` | scale 2, software cursor, render on damage only, no animations/blur/shadows |
| `sway/config.d/50-m5-softrender` | `~/.config/sway/config.d/50-m5-softrender` | fallback session layout |
| `bin/sway-softrender` | `/usr/local/bin/sway-softrender` (0755) | starts sway with `WLR_RENDERER=pixman` |
| `bin/m5-softrender-check` | `/usr/local/bin/m5-softrender-check` (0755) | read-only inventory; `--bench` inside the session |

Kernel side (omarchy-m5 patch `../patches/omarchy-m5/0001-*`):
`configs/omarchy-softrender.config` sets `UDMABUF=y` and
`DMABUF_HEAPS_SYSTEM=y` (both were off or `=m`, and the root has no modules).
Build with
`KCONFIG="defconfig asahi.config omarchy-bringup.config omarchy-storage-net.config omarchy-smc.config omarchy-softrender.config" scripts/build-kernel.sh`.
Nothing in the desktop depends on it: without it, clients fall back to wl_shm copies.

## Compositor choice

1. **Hyprland (Omarchy), the default.** Runs on llvmpipe through kms_swrast.
   Costs more CPU per frame than a CPU-native renderer because every
   composite goes through GL emulation, but it is the session Omarchy is built
   around, and it renders only on damage.
2. **sway with pixman, the low-CPU fallback.** The wlroots pixman renderer
   composites with CPU 2D code and no GL at all. Good for a long battery
   session or when Hyprland's CPU use is too high. No Omarchy shell.
3. **GNOME / Plasma: not recommended here.** Both run on llvmpipe, but their
   shells animate constantly and they are not what this project ships.

## Known limits of simpledrm (not configurable)

- One mode, set by iBoot. No resolution or refresh changes, no external
  display, no brightness control (that needs DCP; see the DCP report).
- No vblank. Page flips complete as soon as the copy is done, so frames are
  not paced to the panel and tearing is possible. A client that redraws
  continuously (video, a game) makes Hyprland render as fast as it can.
- No cursor plane: the pointer is drawn in the frame (`no_hardware_cursors`).
- The framebuffer's pixel format is unknown until measured (m1n1 writes
  x8r8g8b8 or x2r10g10b10). With the 10-bit format simpledrm converts every
  copied pixel; `m5-softrender-check` shows which one is in use.

## Per-toolkit renderers (measure before keeping)

- Firefox: no setting. It blocklists llvmpipe for GPU WebRender and uses its
  multithreaded software WebRender.
- Chromium / Electron: no setting. They see a software GL and use their own
  software compositing (SwiftShader for WebGL).
- GTK4: `GSK_RENDERER=cairo` draws on the CPU instead of through llvmpipe;
  usually faster for ordinary windows, worse for heavy transforms.
- Qt Quick: `QT_QUICK_BACKEND=software` avoids llvmpipe, but Omarchy 4's
  Quickshell shell uses Qt Quick effects that the software backend may not
  draw. Try per application, not globally.
- Terminals: foot draws into shared memory on the CPU; Alacritty/Ghostty go
  through llvmpipe and cost more per frame.

## What to measure on first boot (no published numbers exist for M-series)

No one has published llvmpipe or glmark2 numbers for an M-series Mac without
its GPU driver; the only public data point is Asahi's 2022 note that software
rendering on M1 was "surprisingly usable" in a composited Plasma session.
Record, per compositor:

1. `m5-softrender-check` (inventory, framebuffer format).
2. `m5-softrender-check --bench`: idle desktop CPU and a windowed glmark2 score.
3. Typing in a terminal and scrolling a long web page: watch `btop`; note any
   stutter.
4. 1080p video in Firefox: CPU and dropped frames.
