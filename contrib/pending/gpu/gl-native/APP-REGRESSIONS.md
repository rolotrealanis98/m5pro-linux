# Native Gallium GL on the G17S: why real apps broke (2026-11-08)

**Result.** Both failures are driver bugs, and both are fixed and verified offline. Neither is a gap in the native draw profile. Alacritty's draws passed every profile check; glmark2's shader compiled up to a single folded instruction.

1. **Alacritty (black windows).** The text shader's fragment program was never built. The uniform layout put a sysval range at an odd uniform half, and the M5 program builder only accepts dword-aligned ranges. That layout rule was enabled for G17P only. Every draw in the frame was refused, so the whole render, clear included, was dropped.
2. **glmark2 (`persp_mul_agx3`).** A `mediump` smooth varying is lowered to fp16. The optimizer then folded the f32-to-f16 move into the native projective multiply, which has no 16-bit destination form, so the packer refused it. This hits every GLES fragment shader with a default-precision perspective varying, and G17S/G17C take this path.

Fixes: `app-fixes/0006`–`0008`, on top of the 5-patch series. On the drm-shim M5 gate, every Alacritty and glmark2 repro step builds and submits, with nothing refused. `meson test --suite asahi` gives 67/69; the 2 failures are the known G17P blit ones, and the Vulkan tests are not built in this tree. `agx_tests` gives 520/520, including a new regression test.

These have not been run on the GPU yet; see "Hardware check" below.

## 1. Where each message comes from (`g17s-gallium-native`, 043a4c58080)

| Message | Code path | Meaning |
|---|---|---|
| `G17G Gallium could not build the native fragment program` | `agx_state.c:8206`, `agx_encode_g17g_state()` → `agx_build_pipeline()` → `agx_build_agx3_graphics_program()` returned 0 | The program builder refused. Its reason (`M5_PROGRAM_REJECT ...`) prints only under `AGX_DBG_FAULTTRACE`, which had no `ASAHI_MESA_DEBUG` name (fixed by 0008). For Alacritty it was **`push range shape`** (`agx_state.c:5375`: `start & 1`). |
| `asahi: dropping a render whose 2 draws were all outside the native profile on G17S` | `agx_batch.c:1129`, `agx_batch_submit()` | A consequence, not a cause. Every draw in the batch was refused (`draws_refused && !draws`), so the render is dropped. A render with no draws would be an EINVAL in UAPI translation. |
| `asahi: dropping work: batch 1 used state with no proven native encoding on G17S; nothing was submitted` | `agx_batch.c:1183` | A consequence. With no compute work either, `native_rejected` is set and nothing is submitted. The clear goes with it, so the window shows a never-written buffer (black). |
| `the AGX backend cannot encode this FS shader ...: AGX3 binary packer refused persp_mul_agx3 at line 10795` (glmark2; the verifier summarised it as "shader the AGX backend refused") | `agx_state.c:2081`, `agx_compile_variant()`; refusal in `agx3_pack_binary.c:10795` | `persp_mul_agx3 [d16:reg4 s0=32:reg2 s1=32:reg0]`. The packer requires `agx3_vary_reg32(dest)`. The draw is dropped via `agx_drop_for_unusable_program()` ("dropping work: the fragment program is unusable"). |
| `Experimental M5 HAL300 integration enabled; general rendering is unqualified` | `agx_device.c:919` | Informational. It is printed whenever `ASAHI_M5_BRINGUP=1` admits the device. |
| `Mesa: error: GL_INVALID_ENUM in glGetString(GL_EXTENSIONS)` | Mesa's GL frontend; not the driver | Harmless, see section 4. |

The draw-profile gate (`M5_DRAW_OUTSIDE`, "G17G Gallium draw exceeds the native triangle profile: ...") never fired for Alacritty, either on the machine or in the repro. The profile already admits Alacritty's varying layout; its comments name Alacritty.

## 2. Root causes

### 2a. Uniform ranges not dword-aligned on M5 (Alacritty)

`agx_compile_nir()` (`agx_state.c:2021`) calls `agx_nir_layout_uniforms(..., dword_ranges = agx_native_graphics(dev))`. `agx_native_graphics()` is true for G17P only. `agx_build_agx3_graphics_program()`, which G17G, G17S and G17C use, still moves uniforms as dwords. It pads an odd *length* itself but refuses an odd *start*.

The push ranges of Alacritty's text fragment shader, captured with `NEO_AGX_UNIFORM_DIAGNOSTICS=1`:

| Range | Table | Offset | Uniform | Halves | What |
|---|---|---|---|---|---|
| 0 | FS stage | 0 | 0 | 4 | texture_base (replaced by the resource pair) |
| 1 | root | 592 | 4 | 8 | blend_constant |
| 2 | root | 0 | 12 | 4 | tables |
| 3 | FS stage | 16 | 16 | 4 | ubo_base[0] (`renderingPass`) |
| 4 | FS stage | 1744 | 20 | **1** | `lod_bias[0]`, a single fp16 half (any sampled texture) |
| 5 | root | 628 | **21** | 2 | `no_epilog_discard` + `provoking_vertex` |

Range 5 lands at odd uniform 21, so the program is refused and every draw that uses it is dropped. The trigger is a sampled texture plus a 16-bit root sysval after it. The sysval comes from `discard` (`no_epilog_discard`) or from flat inputs (`provoking_vertex`). Removing the flat qualifiers and the discard (repro step `text-all-smooth`) makes range 5 disappear and the program builds. The rect programs have no texture, so they always built.

Fix **0006**: pass `dword_ranges` for `agx_chip_g17_m5()` too. Only the layout changes. Already-aligned ranges are untouched, and G17P behaviour is identical.

Scope: G17S and G17C. By code reading, G17G as well: same builder, same flag. G17G could not be run offline because the shim has no G17G identity (`g17g` falls back to G13G).

### 2b. Narrowing move folded into persp_mul_agx3 (glmark2)

`agx_emit_load_vary_agx3()` (`agx_compile.c:749`) takes the native projective sequence `persp_rcp_agx3` / `persp_mul_agx3` on every AGX3C chip except G17G. Its comment states the hazard: "the native f32mul has no 16-bit destination form, which fp16 varyings need". It then narrows explicitly with an `fmov` to 16 bits.

`agx_optimizer_fmov_rev()` (`agx_optimizer.c:599`) folds that `fmov` into its producer's destination. The result is `persp_mul_agx3` with a 16-bit destination, which the packer refuses. glmark2-es2 emits `precision mediump float;` in every fragment shader by default, and its `build` and `texture` scenes read a smooth `vec4 Color`. Patch 0002 kept the compiler's G17G-only choices, so G17S gets the native sequence, and with it the fold.

Fix **0007**: never fold a 16-bit narrowing move into `PERSP_MUL_AGX3`, on either AGX3 encoding. The code becomes `persp_mul_agx3` (32-bit) followed by `fadd d16, s32, -0`, a single rounding.

A regression test, `Optimizer.NativePreservesNarrowingAfterProjectiveMultiply`, covers AGX3B and AGX3C. It fails without the fix and passes with it.

G17G is unaffected (it takes the generic `interp`/`rcp`/`fmul` path). Vulkan on G17S shares the optimizer; the change only adds a move where the fold was unencodable anyway.

### 2c. Diagnostics gap

`AGX_DBG_FAULTTRACE` (bit 23) gates every `M5_DRAW_REJECT` / `M5_PROGRAM_REJECT` reason, but `agx_debug_options` had no entry for it. On the machine, "could not build the native fragment program" therefore never said why. Fix **0008** adds `ASAHI_MESA_DEBUG=faulttrace`.

## 3. Which Alacritty features and GL state are inside or outside the gate

The source is alacritty `aa5d942` (2026-11-06), from `res/glsl3/*`, `res/rect.*`, `src/renderer/{mod.rs,rects.rs,text/glsl3.rs,text/atlas.rs}`. Status is on the shim, production tree vs. with 0006–0008.

| Feature | Where | Status |
|---|---|---|
| GL 3.3 core context, `#version 330 core` | renderer selection | fine |
| Instanced quads: `glDrawElementsInstanced`, 5 attributes with divisor 1 (u16x2, i16x4, f32x4, u8x4, u8x4), `gl_VertexID` corners | text VS | fine |
| Mixed varyings: smooth `vec2 TexCoords` + `flat vec4 fg`, `flat vec4 bg` | text VS/FS | admitted by the draw profile ("flat beside interpolated"). The flat inputs pull in the `provoking_vertex` sysval, half of the 2a trigger. |
| `uniform int renderingPass` branching, `discard`, early `return` | text FS | fine. `discard` pulls in `no_epilog_discard`, the other trigger. |
| Glyph atlas: RGBA8 1024², `texture()` with LINEAR/CLAMP_TO_EDGE (no `texelFetch`) | text FS, atlas.rs | the sampler's `lod_bias` half is the other half of 2a |
| Dual-source blending: `layout(location=0, index=1)`, `glBlendFunc(SRC1_COLOR, ONE_MINUS_SRC1_COLOR)` | text pass | fine with 0006. Blending is done in the shader epilog (`agx_nir_prolog_epilog.c`); dual-source alone was never the problem (steps `text-alpha-blend`, `text-noblend` and `text-single-output` failed the same way). |
| `glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, SRC_ALPHA, ONE)` | rect pass | fine |
| Rect FS: `gl_FragCoord.xy`, `floor`/`mod`/`cos`/`sqrt`/`pow`, flat colour | undercurl, dotted, dashed | fine on both trees |
| `glDepthMask(GL_FALSE)`, no depth/stencil, `glViewport` with padding offset | state | fine |
| sRGB framebuffer, scissor | not used by Alacritty | n/a |

## 4. `glGetString(GL_EXTENSIONS)` → GL_INVALID_ENUM

The error is harmless and the frontend raises it by design. In a core profile, `GL_EXTENSIONS` is not a valid `glGetString` name (GL 3.0 deprecated it; core requires `glGetStringi`), so Mesa raises INVALID_ENUM and returns NULL.

Alacritty calls it on purpose:
- `Renderer::supports_robustness()` → `GlExtensions::load_extensions()` (`mod.rs:364`) tries `glGetString(GL_EXTENSIONS)` first.
- On NULL it falls back to `GL_NUM_EXTENSIONS` + `glGetStringi`.

`MESA_DEBUG=1` just prints the error. It is the same on zink and every other Mesa driver, and the repro shows it on both trees.

## 5. Offline reproduction (Studio, no GPU)

The environment is the Arch Linux ARM build container `mesagl` (Apple `container`), not Fedora. It is the one `scripts/build-container.sh` creates; only `/out` (= `~/Work/agents/gpu-gl-native/out`) is mounted.

Harnesses, added uncommitted under `tests/`:
- **`tests/alacritty-repro.c`** replays Alacritty's glsl3 text renderer and the four rect programs. It uses the verbatim shader files on a surfaceless GL 3.3 core context with Alacritty's exact GL state. It adds one-feature-removed variants: no SRC1 blend, blend off, no index-1 output, no discard, no flat qualifiers.
- **`tests/glmark2-build-repro.c`** replays glmark2-es2's default `build` scene (light-basic) and its `texture` scene (light-basic-tex). It uses glmark2's precision header under a perspective projection, in mediump and highp.

```
# inside the container (run-shim-p.sh = tests/run-shim.sh with P overridable)
cc -O2 -o alacritty-repro alacritty-repro.c -lEGL -lOpenGL
cc -O2 -o glmark2-build-repro glmark2-build-repro.c -lEGL -lGLESv2
MESA_DEBUG=1 bash run-shim-p.sh g17s-kernel ./alacritty-repro <alacritty/res>
MESA_DEBUG=1 bash run-shim-p.sh g17s-kernel ./glmark2-build-repro
# reasons: ASAHI_MESA_DEBUG=faulttrace (needs 0008), AGX_MESA_DEBUG=shaders
```

| Step | Production tree (5 patches) | + 0006–0008 |
|---|---|---|
| Alacritty `text` (verbatim) | the machine's exact four messages; `M5_PROGRAM_REJECT stage=4 push range shape` | built, submitted, gate 0 refused |
| `text-alpha-blend` / `-noblend` / `-single-output` / `-nodiscard` | same refusal | built |
| `text-all-smooth` (no flat, no discard) | built | built |
| `rect`, `rect-undercurl`, `rect-dotted`, `rect-dashed` | built | built |
| glmark2 build, mediump (default) | `refused persp_mul_agx3 at line 10795` | built |
| glmark2 texture, mediump | same | built |
| glmark2 build/texture, highp | built | built |
| 12-scene `gl-native-smoke` (gate shape only, shim pixels are zero) | 15 submits / 13 renders / 0 refused | identical |
| `meson test --suite asahi` (no Vulkan in this tree) | n/a | 67/69, the 2 known G17P blit failures |
| `agx_tests` | n/a | 520/520 |

The noop shim cannot validate pixels: every pixel reads back 0, and "export failed" is the shim lacking syncobj export. These runs prove that the programs build and that the submissions pass the kernel's structural checks. They do not prove correct rendering.

Container state, kept for re-runs:
- `/root/gl-native/diag`: a worktree at 043a4c58080 plus 0006–0008 as local commits.
- `/root/gl-native/diag-build`: an asahi-only build with tests, installed to `/opt/mesa-diag`.
- The production build and the staged tree are untouched.

## 6. Ranked fixes and effort

1. **Take 0006 + 0007 + 0008 into the series** (done offline, about 15 changed lines plus a test). They fix the actual faults rather than routing around them. Remaining work is about 30 minutes of hardware validation; see below.
2. **App shader corpus on the shim** (1–2 days). This catches the next "cannot encode" or "could not build" before the desktop does. Run the same harness pattern over:
   - glmark2's full default benchmark: all scenes and their shader permutations, not just `build`;
   - Hyprland's and aquamarine's shaders;
   - foot, kitty and ghostty;
   - GTK4's GL renderer, WebRender (Firefox), Chromium's GL and mpv.

   Fail on any refusal message. The machinery is all here: the shim gate, faulttrace, `AGX_MESA_DEBUG=shaders`.
3. **Session policy until 2 is clean** (about an hour). Keep zink as the session default and opt in to native per session, or the reverse with a per-app zink list (`MESA_LOADER_DRIVER_OVERRIDE=zink` in the launcher for apps on the list). This is a band-aid, but it is the only fallback that actually exists; see 5.
4. **Widen the draw profile.** Not needed for these apps: the gate admitted Alacritty's layout and glmark2's. Do it only when the corpus shows `draw exceeds the native triangle profile: <reason>`. The cost depends on whether a reason needs new hardware witnesses (stencil ops, layered renders) or only plumbing.
5. **Keep the clear when every draw is refused** (0.5–1 day). Instead of dropping the whole render, reduce the batch to its clear/load/store shape (an ordinary clear batch already submits). The window would show the background instead of black, with the text still missing. Low value: it hides faults rather than fixing them.
6. **Per-draw fallback to "the previous path": not feasible.** G17S has no other in-driver encoder: the AGX2 encoders cannot target it, which was the original failure the series fixed. The previous working path is zink, a different driver with its own context and resources. A per-draw handoff would need cross-driver resource sharing and a sync per draw, which is weeks of work and slower than zink outright. Partial batches already submit their accepted draws (the drop only happens when *all* draws are refused), so the driver is already per-draw at the granularity it can be.

## 7. Hardware check (needs the MacBook)

1. Rebuild the tarball with `app-fixes/0006`–`0008` and install it as `/opt/mesa-aurora-gl`. Note that `scripts/build-container.sh` applies `patches/*.patch` only, so copy them there or `git am` them.
2. Headless: re-run `scripts/gl-native-ab.sh`; expect 12/12 as before.
3. In the session: Alacritty with `MESA_DEBUG=1 ASAHI_MESA_DEBUG=faulttrace` should show no refusal lines and render text. Run `glmark2-es2-wayland` with the full default benchmark and confirm the verifier's "skipped draws" warning is gone; the score will drop, because the old FPS counted skipped draws. Also check foot and kitty.
4. Omarchy's crash notifier fired repeatedly with no coredumps. That is not explained offline: Alacritty did not crash, it drew nothing. On the next native session, capture `journalctl --user -b` around the notification to see what triggers it (a unit failing, an app's exit status, or a log pattern).

## 8. Note for PR aurora-silicon/mesa #194 (draft, not posted)

> **App testing on the M5 Pro found two more faults; fixes added as patches 6–8.**
>
> With the native driver as the Hyprland desktop GL, Alacritty's windows stayed black and glmark2-es2 skipped draws. Both are reproduced offline on the `g17s-kernel` shim with harnesses that replay the apps' own shaders and GL state.
>
> 6. `asahi: lay out M5 uniform ranges in dwords, as the M5 program loader needs`: `agx_nir_layout_uniforms` aligned push ranges to dwords for G17P only. `agx_build_agx3_graphics_program` refuses an odd start ("push range shape"). A fragment shader that samples a texture (a 1-half `lod_bias`) and reads `no_epilog_discard`/`provoking_vertex` (discard or flat inputs) got an odd range, so its program was never built and the whole render was dropped. Alacritty's text shader is exactly that. By code reading this also affects G17G, which could not be run here (no shim identity).
> 7. `asahi: keep the narrowing move after the M5 projective multiply`: the optimizer folded the f32-to-f16 move of a mediump smooth varying into `persp_mul_agx3`, which has no 16-bit destination form, so every default-precision GLES fragment shader with a perspective varying was unencodable on G17S/G17C. G17G keeps the generic sequence and is unaffected. A unit test is included.
> 8. `asahi: name the faulttrace debug flag`: `AGX_DBG_FAULTTRACE` gated the M5 refusal reasons but could not be enabled from `ASAHI_MESA_DEBUG`.
>
> Offline: Alacritty's text and rect programs and glmark2's build/texture scenes (mediump and highp) all build and submit through the M5 gate with nothing refused. `meson test --suite asahi` gives 67/69, the same two G17P blit failures as the base. `agx_tests` gives 520/520. Hardware re-run pending.
>
> Separately, `glGetString(GL_EXTENSIONS)` → `GL_INVALID_ENUM` in Alacritty's log is its own deliberate core-profile probe (it falls back to `glGetStringi`) and is not a driver issue.
