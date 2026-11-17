# chrome-gpu-ab

Scope: t6050 (any Aurora Mesa session with Borealis Vulkan). Status: staged (measured 2026-11-17; nothing changed in the
owner's Chrome profile or `~/.config/chrome-flags.conf`). Queue doc: `/Volumes/m5pro/bench/requests/gpu-video-2.md`.

Chrome 157 (google-chrome 157.0.8103.78) on the J716s, session Mesa `/opt/mesa-aurora-20261117` (aurora-wip db928e79933d,
native Gallium GL + Borealis Vulkan), Hyprland 0.57.1. Throwaway profile `/home/rolo/gpu-ab/chrome-test`.

## Files

- `bench.html`: offline benchmarks, each 1 s warm-up + 6 s counted with requestAnimationFrame (Chrome runs with
  `--disable-gpu-vsync --disable-frame-rate-limit`): WebGL2 3000 draw calls/frame, WebGL2 fragment-heavy fill (1280x720),
  Canvas 2D (paths, gradients, images, text), 700 CSS layers (radius, shadow, transform, opacity), WebGPU 3000 draws/frame.
- `cdp.py`: stdlib DevTools client; waits for the bench, reads `chrome://gpu`, closes the browser.
- `run-ab.sh OUT ROUNDS CONFIG...`: one window per run on Hyprland workspace 5, silently (owner rule), started by Hyprland
  (Lua: `hyprctl dispatch 'hl.dsp.exec_cmd("CMD", {workspace = "5 silent"})'`) so it gets the session env; serialized with
  other agents through `flock /home/rolo/gpu-ab/.gpu-window.lock`; dmesg checked after every run.
- `video-ab.sh OUT "VARIANTS" "CLIPS"`: Chrome video decode A/B (libva driver x Chrome flags): AVD nodes held by the GPU
  process, WebCodecs hardware support, CPU of the whole test Chrome, dropped frames, a frame colour sample; `picture-cmp.py`
  compares the colour samples against software decode.
- `chrome-flags.conf.vulkan`: the proposed `~/.config/chrome-flags.conf` (Chrome uses only the LAST `--enable-features`
  line, so the Vulkan features are merged into the existing one).

## Results (fps; 4 runs per config for gl and vk, 2 visible + 2 on workspace 5)

| | gl (today: ANGLE on GL, Ganesh GL) | vk (`--use-angle=vulkan` + `Vulkan,DefaultANGLEVulkan,VulkanFromANGLE`) |
|---|---|---|
| chrome://gpu | Vulkan: Disabled, Skia Backend GaneshGL, Display ANGLE_OPENGL | Vulkan: **Enabled**, Skia Backend **GaneshVulkan**, Display ANGLE_VULKAN |
| WebGL renderer | ANGLE (Mesa, AGX G13/G14, OpenGL ES 3.2) | ANGLE (Mesa, Vulkan 1.4.363 (Apple M5 Pro (G17S B1)), Borealis) |
| WebGL draw calls | 237 / 315 / 275 / 282 (median ~278) | 749 / 748 / 739 / 797 (median ~748, **2.7x**) |
| WebGL fill | 874 / 919 / 798 / 870 (~872) | 723 / 721 / 717 / 675 (~719, **-18%**) |
| Canvas 2D | 185 / 180 / 169 / 176 (~178) | 203 / 206 / 201 / 196 (~202, **+13%**) |
| CSS layers | 96 / 142 / 122 / 107 | 92 / 103 / 213 / 110 (noise; no difference shown) |
| WebGPU | no adapter (chrome://gpu says "Hardware accelerated", but `webgpu_on_vk_via_gl_interop` is blocklisted, so pages get none) | **works**, 1200 to 1250 fps |
| GPU faults / crashes | none | none |

- Skia Graphite: `--enable-features=SkiaGraphite` alone is ignored (still Ganesh). Forcing it with `--enable-skia-graphite`
  (with ANGLE GL or Vulkan) crashes the GPU process 3 times at start (exit 133, SIGTRAP: a CHECK; the three core dumps at
  12:48:38 UTC were this), then Chrome falls back with WebGL unavailable and Vulkan disabled. **Graphite is not usable** on
  this driver/Chrome.
- `vk-graphite` (feature only) = vk within noise (Graphite stayed off).
- Not measured: power/battery, long-session stability, video decode with Vulkan (the AVD test checks it: `avd-video/`).

## With hardware video decode (next7 boot, AVD up; 2026-11-17 afternoon)

`video-ab.sh` (muted clips, test profile `/home/rolo/gpu-ab/chrome-test-video`, workspace 5) and `picture-cmp.py` (mean RGB of a
4x4 grid of the frame at t=2 s against software decode):

| config | AVD used (GPU process holds /dev/media0, WebCodecs hw) | Chrome CPU, 1080p30 | picture vs software |
|---|---|---|---|
| gl (today) | yes for H.264/HEVC/VP9; AV1 falls back (`vaEndPicture failed`, 84% of a core) unless the #330 driver | 2-3% | **off: green channel up to 23/255** (all codecs) |
| vk (`--use-angle=vulkan` + `Vulkan,DefaultANGLEVulkan,VulkanFromANGLE`) | **no**: Chrome disables VA-API with Vulkan (WebCodecs hw=false, 29% CPU) | 29% | n/a |
| vk-forced (vk + `VaapiIgnoreDriverChecks,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL`) | **yes**, all four codecs with the #330 driver | 1-2% | **matches** (max 2/255) |
| angle-vk (`--use-angle=vulkan`, no Vulkan feature) | yes | 1% | not measured |

Graphics with those configs (2 runs each, fps): gl WebGL draws 247/286, fill 933/927, canvas 179/179; **vk-forced** 814/816,
724/725, 200/201, WebGPU 1270/1264 (same as vk); angle-vk 512/505, 759/748, 191/203, no WebGPU. No GPU faults or kernel lines.

The GL-path colour error is a separate bug: Chrome's VA-API frames imported as NV12 dma-bufs into native GL come out with a
different YUV->RGB conversion than software decode, while the Vulkan path matches. Suspect the EGL dma-buf import's colour
space/range hints in Mesa asahi (`EGL_YUV_COLOR_SPACE_HINT_EXT`/`EGL_SAMPLE_RANGE_HINT_EXT`, BT.601 vs BT.709 — the size and
the green-heavy shift fit a 601/709 matrix swap) or Chrome's GL import path. Not filed.

## Recommendation

Switch `~/.config/chrome-flags.conf` to `chrome-flags.conf.vulkan` (vk-forced: Vulkan flags plus the three VA-API features,
merged into the single `--enable-features` line; Chrome reads only the last one), together with the #330 VA driver
(`avd-video/README.md`). Evidence: hardware decode on all four codecs at 1-2% CPU with correct colours (the current GL path is
off by up to 23/255 in green), WebGL call-heavy pages 2.8x, Canvas 2D +12%, WebGPU on; cost: fill-bound WebGL -22%. Risk:
Borealis sits under the whole Chrome compositor, so a Vulkan fault takes all of Chrome; `VaapiIgnoreDriverChecks` is a
"manual testing" feature in Chrome. Soak a day before relying on it. Skia Graphite: not usable (crashes, above).

Apply (owner, then restart Chrome): `cp ~/.config/chrome-flags.conf ~/.config/chrome-flags.conf.gl && cp chrome-flags.conf.vulkan ~/.config/chrome-flags.conf`.
Undo: `mv ~/.config/chrome-flags.conf.gl ~/.config/chrome-flags.conf`, restart Chrome.

Results: `/home/rolo/gpu-ab/chrome-ab/{r1,ws5,next7,video1,video2,video3}/` on the Mac (JSON with the full chrome://gpu text per run).
