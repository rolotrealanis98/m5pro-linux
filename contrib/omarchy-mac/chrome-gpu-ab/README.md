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

## Recommendation

Switch `~/.config/chrome-flags.conf` to `chrome-flags.conf.vulkan` once (1) the AVD next-boot test shows VA-API decode still
works with the Vulkan flags (its `vk` Chrome variant), and (2) a day of normal use in the test profile shows no GPU recovery.
Gains: WebGL call-heavy pages ~2.7x, Canvas 2D +13%, WebGPU on. Cost: fill-bound WebGL ~18% slower. Risk: Vulkan in the
Chrome compositor puts Borealis in the path of every page; a Vulkan fault would hit all of Chrome, not only WebGL.

Apply (owner, then restart Chrome): `cp ~/.config/chrome-flags.conf ~/.config/chrome-flags.conf.gl && cp chrome-flags.conf.vulkan ~/.config/chrome-flags.conf`.
Undo: `mv ~/.config/chrome-flags.conf.gl ~/.config/chrome-flags.conf`, restart Chrome.

Results: `/home/rolo/gpu-ab/chrome-ab/{r1,ws5}/` on the Mac (JSON with the full chrome://gpu text per run).
