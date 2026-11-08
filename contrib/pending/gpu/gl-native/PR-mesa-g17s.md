# asahi: native Gallium GL on the M5 Pro and M5 Max (G17S, G17C)

Base: `agx3c` @ a8e86a80cdc (the current head when this was prepared). Five patches; 17 files, +1037/−117.

## Why

On the M5 Pro (G17S, T6050), the Gallium asahi driver admits the device under `ASAHI_M5_BRINGUP=1`, but GL renders nothing. Every render is refused by the kernel:

```
DRM_IOCTL_ASAHI_SUBMIT render failed: Invalid argument (256x256 tile 32x32 ...)
aurora 2300000000.gpu: [File 6 Queue 1]: IOCTL: submit failed! (... err: EINVAL)
```

So far GL on this machine has gone through zink on the Borealis Vulkan driver. This series makes the native driver work instead. It fixes five things the Gallium driver lacked for G17S/G17C.

1. **The M5 path was gated on G17G by name.** About 100 sites in `gallium/drivers/asahi` tested `chip == AGX_CHIP_G17G`: tile programs, the Ioto program generators, Gen10 descriptors, Gen5 samplers, HAL300 initial PPP state, compact VDM pointers, the per-layer and per-attachment splits, and the CPU fallbacks. G17S fell through every one of them to the AGX2 encoders. Before any submit, it could not even compile a fragment shader: the AGX3c packer refuses the constant program a preamble needs, and the no-preamble compile was G17G-only.
   - The three M5 parts share the instruction encoding, command stream, descriptor and sampler generations, and Honeykrisp already uses `agx_chip_g17_m5()` everywhere. The Gallium driver now does the same.
   - `agx_zls_pixels()` and `agx3_g17p_fragment_blend_constant_base()` follow.
   - Kept G17G-only: the one-dispatch-per-ioctl compute split, which answers the M5 kernel runtime's single-command submit path, and the compiler's G17G workarounds.
2. **No program storage lists.** G17S/G17C run on the G17 kernel runtime (`DRM_ASAHI_FEATURE_RENDER_RESOURCES`). It sizes each render's firmware pools from the programs the render runs, and refuses any render that isn't preceded by `DRM_ASAHI_SET_RENDER_RESOURCES(_V2)` (EINVAL in `g17/runtime/backend.rs` prepare_command). The driver now builds and sends the same records Honeykrisp sends:
   - one record per linked vertex or fragment program, the tile (background/end-of-tile) record, and compute dispatch profiles via `SET_COMPUTE_RESOURCES`;
   - each recorded single-dispatch compute stream as its own command of the submission, waiting on the ones before it;
   - the render command through the high resource-specifier words;
   - depth clear 1.0 when the render has no depth/stencil storage;
   - `DRM_ASAHI_RENDER_SHADER_WRITES` when a program writes memory.

   All of this is keyed on the feature bit, which the G17G runtime does not report.
3. **Tile-dirty epilog case.** As on G17P, a covered fragment that stores nothing still dirties the tile. A draw with all colour channels masked off left (0,0,0,0) where the clear had been. The fix enables the epilog's existing `preserve_zero_mask` (a tile load/store pair) on G17S/G17C, in Gallium only. G17G and the Vulkan epilog policy are unchanged.
4. **GBM map race (not M5-specific).** A CPU map synced only the writers in its own context. `gbm_bo_map()` maps through the GBM device's own context, so it read a window-system buffer before the GPU had written it (gbm-scanout-test read black). The map now waits for the syncobj the writing submission left on the BO and, for exported BOs, for their implicit fences. It only adds waits.
5. **Timer queries.** They are advertised on G17S/G17C, where the G17 runtime maps timestamp objects and stamps M5 work. Desktop GL 3.3 needs `ARB_timer_query`; without it the context stopped at GL 3.2. They stay off on G17G.

## Patches

1. `asahi/drm-shim: model the M5 Pro kernel's submission checks`
2. `asahi: drive the M5 Pro and M5 Max through the Gallium M5 path`
3. `asahi: send the program storage lists the M5 Pro kernel requires`
4. `asahi: keep the tile under fully masked draws on the M5 Pro`
5. `asahi: wait for writers on other contexts before a CPU map`

## Offline test: the drm-shim M5 gate

Patch 1 adds `ASAHI_SHIM_CHIP=g17s-kernel` to the noop shim. The identity mirrors GET_PARAMS of the aurora kernel on a J716s: features 0x23cfe7c06, without the VM-status and independent-queue bits, whose ioctls the shim does not emulate by default; revision 17; 2×10 cores.

Every submit then goes through `asahi_m5_submit_gate.c`, a structural copy of the G17 runtime's checks:
- the command parser
- M5 render and compute validation
- the storage lists and their per-entry demand limits
- the render-requires-a-list rule
- the M5 render admission, including the compressed MSAA Z/S forms when reported

A refusal returns the kernel's errno and names the check. Options: `ASAHI_SHIM_M5_GATE=1|warn|0` and `ASAHI_SHIM_M5_EXPECT_VALID`.

- Honeykrisp passes it: vkmark headless, about 470k submits, none refused.
- Gallium after patch 2: the gate refuses the first render with exactly the error the hardware gives.
- Gallium after patch 3: a 12-scene GLES 3.1/3.2 test makes 15 submits (13 renders, 3 compute commands) and all pass.

## Hardware results

Machine: MacBook Pro 16" M5 Pro (J716s, G17S B1, chip 0x6050). Kernel: aurora-silicon/linux #1173 on top of #1012, built as 7.3.0-g36845aa5f650; GET_PARAMS features 0x23cfe7c06. Mesa: this series, tip 043a4c58080, against agx3c + zink (Borealis) as the reference.

**Headless A/B, both trees: 12/12 steps pass.** Every submit was accepted, and no GPU kernel errors appeared.

| Step | Native Gallium | zink |
|---|---|---|
| eglinfo -B: renderer `Apple M5 Pro (G17S B1)`, no zink | PASS | PASS (zink) |
| 12-scene GLES smoke (depth, texture, MRT, MSAA resolve, compute ± shared memory, stencil+blend, geometry shader, mipmaps, 2048×1536 scissor), pixels checked | PASS | PASS |
| probe: blend and colour-mask alpha, GBM LINEAR buffers, GBM window surface + `gbm_bo_map` | PASS | PASS |
| egl-offscreen-test | PASS | PASS |
| gbm-scanout-test (LINEAR, PRIME into simpledrm) | PASS | PASS |
| gpubench-gl render.light (GL 4.6 core, timer queries) | PASS | PASS |

**Desktop.** Hyprland ran on the native driver. aquamarine's CDRMRenderer got `IMG_context_priority` (high) and `EXT_create_context_robustness`. glmark2-es2-wayland inside the session scored **1278**.

- Earlier zink runs in the same session setup scored 597–890 (default runs every 5 minutes during a soak), against a short build/texture/shading run here, so the numbers indicate direction rather than a like-for-like comparison.
- A 30-minute soak on the native session is running; its result will be added here.

**Unit tests:** `meson test --suite asahi` gives 108/110. The two failures, `asahi-g17p-gallium-blit` and `asahi-g17p-gallium-blit-encode`, fail identically on a8e86a80cdc without this series. They check the G17P (A18 Pro) accelerated-transfer cap and report "Accelerated texture transfers were disabled".

## Open points

- **G17C (M5 Max) has not been run.** It is admitted by the same bring-up gate (chip 0x6050 with 4 clusters) and takes the same paths. Assumed rather than measured: that it shares G17S's tile-dirty behaviour (patch 4) and that its kernel reports the same features. Its 4-cluster topology has not been exercised.
- **The shim identity name `g17s-kernel`** is a placeholder. It may want to carry the kernel or firmware it was taken from (e.g. `g17s-26c5035`), or replace the old `g17s` identity outright.
- **Still behind `ASAHI_M5_BRINGUP=1`.** G17S/G17C keep the experimental gate. Promotion is a separate decision.
- **Not covered yet:**
  - The internal `agx_launch_internal` dispatches record no compute profile; application dispatches do. The kernel uses its default compute policy for them.
  - The tile budget stays at G17G's 32 KiB; the kernel and Honeykrisp allow 64 KiB.
- **Do not stack the downstream decline patch.** `0001-asahi-decline-the-M5-Pro-and-M5-Max…` (m5pro-linux `contrib/pending/gpu/gl-fix/`) makes the driver refuse G17S/G17C so that GL falls back to zink. This series replaces it; applying both would decline the device again.
- **Patch 5 changes behaviour on every chip.** It is a cross-context synchronization fix, not M5-specific.
