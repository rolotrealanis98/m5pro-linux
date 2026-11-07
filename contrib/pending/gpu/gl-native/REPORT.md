# Native Gallium OpenGL on the G17S (2026-11-07) — built, not yet run on the GPU

Three patches on aurora-silicon/mesa agx3c a8e86a80cdc (replace the decline patch in ../gl-fix; do not stack both):
1. `asahi/drm-shim: model the M5 Pro kernel's submission checks` — shim identity `ASAHI_SHIM_CHIP=g17s-kernel` matching
   the live GET_PARAMS, gate `asahi_m5_submit_gate.c` copying the kernel's structural checks (Borealis passes it: 470k
   submits, 0 refused).
2. `asahi: drive the M5 Pro and M5 Max through the Gallium M5 path` — every `chip == AGX_CHIP_G17G` test becomes
   `agx_chip_g17_m5()`; helpers `agx_zls_pixels`, `agx3_g17p_fragment_blend_constant_base`; timer queries off on M5;
   G17G-only pieces kept (one-dispatch-per-ioctl compute split, compiler G17G workarounds).
3. `asahi: send the program storage lists the M5 Pro kernel requires` — per-program storage with Borealis's formulas
   (primary = max(scratch, SPECTPR), vertex secondary = 2 × staging, fragment imageblock + multisample, bg/eot tile
   record), sent as SET_RENDER_RESOURCES V2 (cmd 7) or V1 (cmd 5) before each render, deduplicated; compute profiles
   and SET_COMPUTE_RESOURCES; render command sized for the high resource-specifier words; RENDER_SHADER_WRITES.

Root cause widened: besides the missing resources list (backend.rs:197 EINVAL), the Gallium M5 path keyed ~100 sites on
G17G so G17S fell to the AGX2 encoders (a fragment shader could not even compile offline). Live GET_PARAMS on the
MacBook: G17S rev 17, chip 0x6050, 2 clusters x 10 cores, features 0x23cfe7c06 (RENDER_RESOURCES, RESOURCES_V2,
COMPUTE_RESOURCES, SHADER_WRITES, STAGE_PREFIXES_V2, WHOLE_ATTACHMENT, MSAA compression, TASK_MESH_STORAGE; no
SOFT_FAULTS). No kernel relaxation needed.

Offline evidence: 12-scene GLES 3.1/3.2 smoke on the g17s-kernel shim: after patch 2 the gate refuses the first render
with the hardware's exact EINVAL; after patch 3, 15 submits (13 renders, 3 compute), 0 refused. meson asahi suite
108/110 (the 2 failures are G17P blit tests failing at the base too).

Build: native aarch64 in an Arch Linux ARM container (same llvm-libs 23.1.4, libclc, libdrm 2.4.134 as the MacBook),
same meson options as /root/build/build-mesa-aurora.sh, prefix /opt/mesa-aurora-gl; recipe scripts/build-container.sh;
output ~/Work/agents/gpu-gl-native/out/{stage/opt/mesa-aurora-gl, mesa-aurora-gl.tar.gz, bin/gl-native-smoke,
agx3c-gl-native.bundle}.

Test plan (MacBook, root, GPU kernel): install the tarball under /opt/mesa-aurora-gl (nothing global changes), run
scripts/gl-native-ab.sh (eglinfo -B surfaceless, gl-native-smoke, egl-offscreen-test, gbm-scanout-test, gpubench-gl)
for the native and the zink trees; pass = renderer `Apple M5 Pro (G17S B1)` without "zink", `RESULT: PASS`, no `submit
failed` in dmesg; then gpu-first-frame.sh with MESA_AURORA_PREFIX=/opt/mesa-aurora-gl MESA_AURORA_GL=asahi; then the
session with scripts/session-gl.env (rollback: the saved zink env). Triage: EINVAL/EOPNOTSUPP = kernel refusal (replay
on the shim); accepted but wrong pixels or GPU timeout = encoder misbehaviour on the G17 runtime (AGX_MESA_DEBUG=faulttrace).
Risks: the Gallium M5 encoders have only run on G17G's runtime; internal dispatches record no compute profile; tile budget
stays 32 KiB; Hyprland needs native GBM LINEAR scanout.

## Update 2026-11-07 22:50 UTC: all three hardware failures fixed, verified on the machine

- Stencil-blend alpha: the test expectation was wrong (GL blends alpha too: bf808080 is right; zink was right), but a
  real bug sat underneath: on G17S, as on G17P, a covered fragment that stores nothing still dirties the tile, and the
  epilog's tile load/store fix was enabled for G17P only -> patch 0004 enables it for G17S/G17C.
- gbm-scanout black: a read-before-write race, not rendering: `gbm_bo_map` maps through GBM's own context and read
  before the GPU finished -> patch 0005 waits for the writer on any other context plus the implicit fences before a CPU
  map (applies to G17G too; Hyprland's scanout copy already waits on the implicit fences).
- GL 3.2 instead of 3.3: timer queries had been disabled on all M5 parts in patch 0002; re-enabled for G17S/G17C (the
  kernel supports timestamps); GL 4.6 core now.
Re-run on the machine with the new libgallium: gl-native-probe PASS (8 blend/mask cases + window surfaces),
gl-native-smoke 12/12, gbm-scanout-test PASS, eglinfo GL 4.6 core, gpubench-gl render.light runs (timer_queries true),
no GPU errors. Offline: shim gate clean, 108/110 asahi tests (same two G17P blit failures as the base).
Rebuilt: MESA_COMMIT 043a4c58080c4951fea3797fe45fc6898ce77632, out/mesa-aurora-gl.tar.gz 78014d19…1904d34b; patches
0001-0005 (timer-query and compute-timestamp changes folded into 0002/0003). Debug env is `ASAHI_MESA_DEBUG=batch,resource`
(no faulttrace switch). Next: install as /opt/mesa-aurora-gl, re-run the A/B, then the session phase (session-gl.env).
