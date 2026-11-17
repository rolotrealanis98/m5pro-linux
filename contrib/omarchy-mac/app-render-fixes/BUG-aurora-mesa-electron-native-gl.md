# asahi (G17S, native Gallium GL): Electron 43 / Chrome 150 window intermittently shows a large black rectangle on Wayland; zink is clean

Draft for aurora-silicon/mesa. Not filed.

## Environment
- Hardware: MacBook Pro 16" M5 Pro (J716s, T6050), GPU "Apple M5 Pro (G17S B1)", 2 clusters.
- Kernel: 7.3.0-gec5f49f167be (Aurora DRM UAPI). `ASAHI_M5_BRINGUP=1`.
- Mesa: aurora-silicon/mesa `aurora-wip` db928e79933d25302a356c1bfd9c598556ee352b, built at -O2 and installed to a prefix. GL/GLES go to the native Gallium asahi driver (`GL_RENDERER` "Apple M5 Pro (G17S B1)", "OpenGL ES 3.2 Mesa 26.3.0-devel (git-db928e7993)"). Vulkan is Borealis from the same tree.
- Compositor: Hyprland 0.57.1 (native GL, same Mesa). Output is eDP 3456x2234 at scale 2.
- App: Obsidian 1.15.1, with bundled Electron 43.8.9 / Chrome 150.0.7871.250, ANGLE on the system EGL/GLES. It runs as a native Wayland client (`ELECTRON_OZONE_PLATFORM_HINT=wayland`). Chrome presents through GBM dmabufs (`zwp_linux_dmabuf_v1`) with explicit sync (`wp_linux_drm_syncobj_surface_v1` acquire/release points on every commit). No subsurfaces are used.
- For comparison: the same app with `MESA_LOADER_DRIVER_OVERRIDE=zink` (zink over Borealis, same tree) is clean.

## Steps
1. Start Obsidian with a fresh profile and a one-note vault on a native-GL Wayland session:
   `obsidian --user-data-dir=/tmp/obs-test 'obsidian://open?vault=test&file=Welcome'`
   The note uses headings, lists, a task list, a fenced code block and a table.
2. Let the window map. Then resize it once: a tiled-to-floating switch (here 845x1056 tiled, then 1000x700 floating) or an ordinary tiling resize.
3. Wait about 8 s without touching it, then look at the window.

## Expected / actual
- Expected: the whole window shows the note, as it does under zink.
- Actual, intermittently: a large rectangle of the window is pure black (0,0,0) and stays black until the next repaint of that area. Logged on the machine:
  - 2000x1400 buffer: black region (706,0) to (1998,912), 42% of the window.
  - With `--disable-gpu-rasterization`: a black rectangle of about 850x600 logical inside the content area.

  The rest of the frame is correct: text, the sidebar and the code block render properly around the hole.
- Rate: 2 of 10 on-screen native-GL launches; 0 of 2 on zink. A pure-black pixel count of each window-only capture identifies the hole, since the theme never uses #000.

## What the driver logs
`MESA_DEBUG=1 ASAHI_MESA_DEBUG=faulttrace` reports nothing in any run, good or bad: no `dropping work`, `could not build`, `refused` or `draw exceeds the native triangle profile` lines. `dmesg` shows no GPU fault, timeout or recovery. Every render submits. For example, in the bad run:

```
M5_RENDER 2000x1400 cbufs=1 zs=PIPE_FORMAT_NONE zls=0 pixels=0 clear=0x3f800000 ... load=0x4 clear_mask=0     resolve=0x3fc   (27x, partial-damage frames)
M5_RENDER 2000x1400 cbufs=1 zs=PIPE_FORMAT_NONE zls=0 pixels=0 clear=0x3f800000 ... load=0x4 clear_mask=0x4   resolve=0x3fc   (23x, full repaints)
```

So no draw is dropped. Either a frame's pixels were not fully in the buffer when the compositor showed it, or the buffer contents that a partial-damage frame loads were wrong.

## Narrowing
| Run (native GL unless noted) | On-screen result |
|---|---|
| default flags | black rectangle in 1 of 8 runs (3 of the 8 were followed by four extra resizes) |
| zink (`MESA_LOADER_DRIVER_OVERRIDE=zink`) | clean, 2 of 2 |
| `--disable-gpu-rasterization` | black rectangle (one of the 2 above) |
| `--disable-gpu` | clean |
| `--ui-disable-partial-swap` | clean, 1 of 1. Every window-sized render then clears (`load=0x4 clear_mask=0x4` 37 of 37); with partial swap about half are loads (`clear_mask=0`) |
| Same app, frame read back with DevTools `Page.captureScreenshot` (viz CopyOutputRequest, waits for the GPU) | clean, 20 of 20 captures across 4 runs at 2200x1518 and 3388x2112 |

The rendered content is right whenever it is read back after GPU completion. The hole appears only in what the compositor shows, and only on the asahi driver.

## Suspected cause (not proven)
There are two candidates. Both are in the path that zink does not share with native.

1. **The presentation fence signals early.** Chrome passes `eglDupNativeFenceFDANDROID()` as the `wp_linux_drm_syncobj` acquire point. On asahi that is `agx_flush()` (`agx_pipe.c:1865`) → `agx_fence_create()`, which exports a sync file of `ctx->syncobj`, the last batch submitted by *this* context (`agx_fence.c:138`). Suppose the dmabuf's last render was flushed from another context in the same screen: ANGLE-GL and Chrome's GPU threads use several native contexts. Or suppose the render for the frame is still in a batch that `agx_flush_all()` did not reach. Either way the exported fence can signal before the tiles are stored, and the compositor latches a partly written buffer. A tile renderer that is interrupted mid-frame leaves a rectangular unwritten region.
2. **A partial-damage frame loads stale contents.** Without `--ui-disable-partial-swap`, Chrome redraws only the damaged rect and relies on the buffer's previous contents (buffer age). The asahi render then uses `load` for the colour buffer. If that load reads something other than the last stored contents, everything outside the damage rect is wrong. Possible ways: the imported dmabuf's compression metadata, a shadowed BO (`agx_shadow`), or contents treated as undefined after `glInvalidateFramebuffer`. A buffer reallocated by a resize would show exactly this: black outside the first damage rect.

`--ui-disable-partial-swap` removes (2) entirely and makes (1) less visible, because every frame rewrites the whole buffer. Chrome 157 on the same session renders correctly per `chrome://gpu` and owner use. It was not run under the same on-screen A/B, so it is not known whether it is immune or just less exposed.

## Suggested checks for the driver side
- With the window visible, repeat with `ASAHI_MESA_DEBUG=sync`. Every submission is then waited on the CPU, so if (1) is the cause the hole disappears.
- `ASAHI_MESA_DEBUG=nocompress` and `ASAHI_MESA_DEBUG=noshadow` test (2).
- Log in `agx_fence_create()` which batch and `ctx->syncobj` back each exported fence. Check that the dmabuf's last writer (`bo->writer`) is the same syncobj, or is ordered before it.

## Workaround
- Run the app on zink: `MESA_LOADER_DRIVER_OVERRIDE=zink obsidian` (installed on this machine).
- Candidate on native GL, not yet verified often enough to recommend: `obsidian --ui-disable-partial-swap`.
