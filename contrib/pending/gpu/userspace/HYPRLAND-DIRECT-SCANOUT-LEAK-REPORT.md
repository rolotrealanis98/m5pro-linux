# Draft upstream report: direct-scanout retry storm reconfigures the output swapchain and modesets on every client frame when KMS cannot import the client buffer (48 GB allocated in 7 s, OOM)

Status: DRAFT, not posted. Review with Rolando first. Evidence (private, Studio):
`~/Work/agents/gpu-recovery/oom-1254/wedge-oom-1254/` (`hyprland-1794141955.log`,
`dmesg.txt`, `verify/`). Analysis: `contrib/validated/integration/RESULTS.md`
entries 2026-11-08 12:43 and 13:15.

Target repository: **hyprwm/Hyprland**. The per-frame retry and the swapchain
reconfigure inside the direct-scanout *test* are in Hyprland's `CMonitor` /
`CMonitorState` (`src/output/Monitor.cpp`). aquamarine is involved in two
smaller ways (a TRACE-only rejection and no way to tell the compositor a buffer
is permanently unimportable); those are listed in a short section the
maintainers can split off to hyprwm/aquamarine if they prefer.

Upstream state checked 2026-11-08: no commit on Hyprland `main` after v0.57.1
touches `src/output/Monitor.cpp` or `src/output/OutputCommitCoordinator.cpp`;
the three `src/render/Renderer.cpp` commits (2c04812b2, ab6141897, 0457ce7de)
are unrelated. aquamarine `main` after v0.16.0: nothing in
`src/allocator/Swapchain.cpp`; `src/backend/drm/DRM.cpp` has only #478
(CRTC recheck) and #486 (log typo); open PRs #479/#484/#485 do not touch this
path. No existing issue matches (searched both repos for "direct scanout",
"swapchain", "leak", "Reconfigured a swapchain", "drmModeAddFB2WithModifiers
unsupported", "AQ_NO_MODIFIERS", "Cannot commit when a page-flip is
awaiting"). Related but different: Hyprland #16710 (redundant modeset on
fullscreen enter/exit since 0.57.0, closed), aquamarine #453/#463 (max_bpc flip
on direct scanout forces a modeset, fixed), aquamarine #441 (dumb-buffer prime
fd leak, closed, different allocator).

---

## Issue text (ready to paste)

### Summary

When a fullscreen client offers a dmabuf that the KMS backend cannot import
(here: a tiled modifier on a device driven without modifiers), Hyprland
0.57.1 keeps the window as a direct-scanout candidate and re-tests it on every
client frame. Each test reconfigures the output swapchain to the client's
format (3 new full-size buffers), the test fails, and the following composed
commit reconfigures the swapchain back (3 more buffers) and modesets because
the output format changed. Six 31 MB buffers and one modeset per frame. In our
session the replaced buffers were not released: 1557 buffers, 48 GB, in about
7 s, until the kernel OOM-killed the session. Direct scanout never succeeded
once.

### Environment

- Hyprland 0.57.1 (tag v0.57.1, acc1aa0bfd4bd575dcb0f76c35ccf12b660a1ab9),
  aquamarine 0.16.0, hyprutils 0.14.3, hyprgraphics 0.6.0
- Apple M5 Pro MacBook, Arch Linux ARM, kernel 7.3.0 (Asahi-style stack)
- Display: `apple-drm` (DCP), `/dev/dri/card1`, eDP-2 3456x2234@120, VRR
  capable. Render: Aurora GPU driver on `/dev/dri/card0` / `renderD128`,
  Mesa 26.3.0-devel, GL via **zink**. Two devices: KMS-only display node plus
  a separate render node (aquamarine logs "No matching render node for
  display-subsystem, falling back to sole renderD").
- aquamarine runs without modifiers: `AQ_NO_MODIFIERS=1` (the display
  controller scans out linear only; the client's tiled buffers cannot be
  added as framebuffers). Swapchain buffers are therefore linear dumb buffers
  allocated through GBM on the KMS node (`drm_gem_dma_create`).
- Config: `render:direct_scanout = 1`, `misc:vrr = 1`,
  `cursor:no_hardware_cursors = 1`, `cursor:inactive_timeout = 3`,
  `debug:vfr = true`, `render:new_render_scheduling = false`. Explicit sync:
  supported (KMS IN_FENCE_FD/OUT_FENCE_PTR, EGL native fence).
- Client: `glmark2-es2-wayland --fullscreen` (GLES on zink; the surface's
  dmabuf has a non-linear modifier, format ARGB8888).

### Reproduction

1. Any machine where KMS cannot import the client's buffer. The easy way to
   force it anywhere: `AQ_NO_MODIFIERS=1 Hyprland` on a GPU whose client
   buffers are tiled (most desktop GPUs; aquamarine then refuses every
   buffer with an explicit non-linear modifier at
   `src/backend/drm/DRM.cpp:3483`).
2. `render:direct_scanout = 1`. Let the cursor hide (software cursor on,
   `cursor:inactive_timeout`), or use a hardware cursor, so the candidate is
   not blocked by `DS_BLOCK_SW`.
3. Run a fullscreen dmabuf client, e.g. `glmark2-es2-wayland --fullscreen`
   or a fullscreen `vkcube`/`mpv --fs --gpu-context=wayland` whose buffers
   are tiled.
4. Watch `hyprland.log`: `Swapchain: Reconfigured a swapchain` alternating
   between the client's format and the output format, `GBM: Allocated a new
   buffer` three times per reconfigure, `drm: Modesetting <output>` once per
   client frame. Watch `ls /proc/$(pidof Hyprland)/fd | wc -l` and free
   memory. Expected: one failed test, then the client is composited.
   Observed: the cycle repeats for every client frame.

Windowed clients and clients that are composited for another reason never
trigger it (no candidate). The condition is only visible when the first test
fails; when the import succeeds, direct scanout engages and the cycle stops.

### Log excerpt (one client frame; the pattern repeats 260 times)

```
GBM: Allocated a new buffer with size [3456, 2234] and format AR24 with modifier 0x0 : LINEAR   (x3)
Swapchain: Reconfigured a swapchain to [3456, 2234] AR24 of length 3
ERR drm: drmModeAddFB2WithModifiers unsupported and buffer has explicit modifiers   \
ERR drm: Failed to submit a buffer to KMS                                            > first 4 cycles only (one per client buffer)
ERR drm: Buffer failed to import to KMS                                             /
GBM: Allocated a new buffer with size [3456, 2234] and format XR24 with modifier 0x0 : LINEAR   (x3)
Swapchain: Reconfigured a swapchain to [3456, 2234] XR24 of length 3
[Monitor::CMonitorState::ensureBufferPresent] no buffer or mismatched format, attaching one from the swapchain for modeset being possible
drm: Modesetting eDP-2 with 3456x2234@120.00Hz
```

After the first four cycles the three ERR lines stop: each of the client's
four buffers now carries aquamarine's `CDRMBufferUnimportable` attachment and
`CDRMOutput::commitState()` rejects it at TRACE level
(`DRM.cpp:2583-2587`), so at the default log level the test fails silently
while the allocations and modesets continue.

Session start (for completeness): `drm: AQ_NO_MODIFIERS enabled, disabling
modifiers for DRM buffers.`, `drm: Explicit sync supported`, `connector eDP-2
crtc is capable of vrr`. The two `Cannot commit when a page-flip is awaiting`
lines are the usual session-start pair, not part of this cycle.

### Numbers (one session, glmark2 fullscreen step of about 7 s)

| what | count |
|---|---|
| `Swapchain: Reconfigured a swapchain` | 519 (260 to AR24, 259 back to XR24) |
| `GBM: Allocated a new buffer` | 1557 (= 519 x 3) |
| `drm: Modesetting eDP-2` | 260 (one per client frame) |
| `Buffer failed to import to KMS` | 4 (one per client buffer, then cached as unimportable) |
| buffer size | 3456 x 2234 x 4 = 30,883,840 bytes (linear dumb buffer on the KMS node) |
| total allocated | 1557 x 30,883,840 = 48.1 GB |
| Hyprland open fds (from IPC "accepted fd N") | 131 before the client -> 1659 at death (+1528, one per buffer) |
| displayed frames | 26.5/s (page-flip trace); the client rendered 63 fps |
| machine | 48 GB RAM; OOM killer at uptime 113.8 s killed the session's services; Hyprland exited; memory came back only then |

The OOM report showed 19 MB free with LRU + slab + shmem under 1.1 GB: the
dumb buffers are `dma_alloc` pages owned by the KMS driver and appear in no
`/proc/meminfo` bucket, which made this look like a kernel leak at first.

### Code path (v0.57.1 / aquamarine v0.16.0)

Per frame, `renderMonitor` (`src/render/Renderer.cpp:2317-2329`):

1. `canAttemptDirectScanoutFast()` (`src/output/Monitor.cpp:2158-2160`) is
   true whenever `m_solitaryClient` is set, which `recheckSolitary()` sets to
   the fullscreen window (`Monitor.cpp:1818-1829`). `isDSBlocked()`
   (`Monitor.cpp:1901-1998`) has no "this candidate already failed" reason;
   `DS_BLOCK_FAILED` exists in the enum (`Monitor.hpp:214`) but nothing sets
   it.
2. `attemptDirectScanout()` (`Monitor.cpp:2000-2141`): the client buffer's
   format differs from the output format, so it sets
   `m_drmFormat = params.format` and `m_output->state->setFormat()`
   (`Monitor.cpp:2066-2070`), sets the client buffer, then runs
   `NEEDS_TEST && !m_state.test()` (`Monitor.cpp:2078`).
3. `CMonitorState::test()` (`Monitor.cpp:2618-2624`) first calls
   `updateSwapchain()` (`Monitor.cpp:2626-2649`): the swapchain's format
   (XR24) no longer matches `m_drmFormat` (AR24), so it calls
   `CSwapchain::reconfigure()` -> `fullReconfigure()` (aquamarine
   `src/allocator/Swapchain.cpp:49, 74-95`), which allocates three new
   buffers (`src/allocator/GBM.cpp:245-247`, each also imported once into
   the renderer by `clearBuffer()` at `GBM.cpp:249-253`) and drops the old
   vector. The swapchain is irrelevant to the buffer under test, which is the
   client's.
4. `m_output->test()` -> `CDRMOutput::commitState(true)`
   (`src/backend/drm/DRM.cpp:2370-2383, 2515`). First time per client
   buffer: `CDRMFB::import()` -> `submitBuffer()` refuses a non-linear
   modifier when `supportsAddFb2Modifiers` is false (`DRM.cpp:3483-3486`,
   forced false by `AQ_NO_MODIFIERS` at `DRM.cpp:745-747`), logs the three
   ERR lines (`DRM.cpp:3380, 2756`) and tags the buffer
   `CDRMBufferUnimportable` (`DRM.cpp:3381`). Every later time:
   `commitState()` returns false at `DRM.cpp:2583-2587` with a TRACE-only
   message.
5. Back in `attemptDirectScanout()` the test failure returns false
   (`Monitor.cpp:2078-2081`); the scope guard (`Monitor.cpp:2056-2064`)
   restores `m_drmFormat`, the state format and the previous buffer. Nothing
   remembers that this candidate/buffer failed. The `COutputCommitCoordinator`
   failure path that resets `m_lastScanout`
   (`src/output/OutputCommitCoordinator.cpp:219-243`) is not involved: no
   commit was submitted.
6. `renderMonitor` falls through to compositing. `beginRender` takes
   `swapchain->next()` (`Renderer.cpp:1915`), which is now one of the AR24
   buffers, and renders the frame into it.
7. `CMonitorState::commit()` (`Monitor.cpp:2604-2616`) calls
   `updateSwapchain()` again: `m_drmFormat` is XR24 again, so the swapchain
   is fully reconfigured back to XR24 (three more buffers; the three AR24
   buffers, including the one just rendered, are dropped). Then
   `ensureBufferPresent()` (`Monitor.cpp:2585-2602`) sees the state buffer
   (the rendered AR24 one) mismatching `m_drmFormat` and replaces it with a
   fresh, never-rendered XR24 swapchain buffer (the DEBUG line in the log).
   The rendered frame is discarded; the panel gets a cleared buffer.
8. `CDRMOutput::commitState()` sees `AQ_OUTPUT_STATE_FORMAT` committed
   (`setFormat()` marks it, `src/output/Output.cpp:205-208`;
   `needsReconfig()` includes it, `Output.cpp:93-95`) and modesets
   (`DRM.cpp:2591-2606`, the "Modesetting" line), although the mode is
   unchanged and the format on the plane is the same XR24 as before.
9. The client's next frame damages the output; back to step 1.

So per client frame: 6 allocations of a full-screen buffer, one discarded
render, one modeset, zero direct scanout.

### Where the replaced buffers should be released

`CSwapchain::fullReconfigure()` replaces `buffers` (`Swapchain.cpp:92`); the
old `SP<IBuffer>`s should hit zero and `~CGBMBuffer` (`GBM.cpp:257-268`)
should close the dma-buf fd and `gbm_bo_destroy()` the dumb buffer. We found
no remaining strong holder in either codebase: `CDRMFB::buffer` is a weak
pointer (`include/aquamarine/backend/DRM.hpp:91`), Hyprland's `IRenderbuffer`
holds a weak pointer and erases itself on the buffer's destroy signal
(`src/render/Renderbuffer.hpp:20`, `src/render/Renderer.cpp:3323`), the
output state holds only the current buffer (`Output.hpp:86`), and
`CGBMAllocator::buffers` is a weak-pointer tracking list. Yet the process
kept one fd per allocated buffer and the memory until exit. Either a holder
we missed keeps the `CGBMBuffer` alive, or the release below aquamarine does
not free the dumb GEM object on this stack (Mesa GBM on a KMS-only node with
the buffer imported into zink by `clearBuffer()` and the compositor's
renderbuffer). We can run `AQ_TRACE=1` and `/sys/kernel/debug/dma_buf/bufinfo`
on request. Independently of where the retention is, the per-frame
reconfigure plus modeset is the trigger and is a bug on its own (it also
reproduces the 0.57 "modeset on fullscreen" class of reports).

### Proposed fix direction

1. Stop retrying a candidate whose buffer the backend cannot import. When
   `m_state.test()` fails in `attemptDirectScanout()`, remember the failed
   buffer (or set `DS_BLOCK_FAILED` for the candidate) and skip direct scanout
   for that window until its buffer, format or modifier changes, or until it
   leaves fullscreen. aquamarine already knows the buffer is permanently
   unimportable (`CDRMBufferUnimportable`); exposing that (a public
   attachment check or a result code from `test()`) would let Hyprland stop
   after the first failure instead of per-frame.
2. Do not reconfigure the output swapchain to test a client buffer. The DS
   test commits the client's buffer, so `CMonitorState::test()` should not
   call `updateSwapchain()` (or `attemptDirectScanout()` should only change
   `m_drmFormat` after the test passes, right before the commit). That removes
   the AR24 allocations and the XR24 reallocation on the way back.
3. Do not modeset when the format reverts to what is already on the plane.
   `handleDSleave()` already avoids `setFormat()` when unchanged
   (`Monitor.cpp:2150-2151`); the rollback path in step 5 and the
   `commit()` path in step 7 should do the same, or aquamarine should not
   treat a `setFormat()` to the current format as `needsReconfig()`.
4. aquamarine: log the `CDRMBufferUnimportable` rejection in
   `commitState()` above TRACE (`DRM.cpp:2585`) so a silent per-frame failure
   is visible in a normal log.
5. If a holder of the replaced swapchain buffers is found, release them; if
   not, the fixes above cap the damage to one reconfigure per fullscreen
   enter.

### Workaround

`render:direct_scanout = 0` whenever aquamarine runs without modifiers (we
set it from the session launcher when it exports `AQ_NO_MODIFIERS=1`). Direct
scanout could never engage on this path anyway, so nothing is lost. Our
verifier now fails on more than 4 swapchain reconfigures during a fullscreen
glmark2 run.

---

## Notes for the reviewer (not part of the issue)

- Line numbers were taken from fresh clones at the exact tags
  (Hyprland `acc1aa0`, aquamarine `b77d676`), scratch copies under the
  session scratchpad; nothing was committed.
- Hyprland's own `attemptDirectScanout` TRACE lines are absent from the log
  because the session ran with `HYPRLAND_TRACE`/`AQ_TRACE` off; the per-frame
  sequence is reconstructed from the DEBUG/ERR lines plus the code.
- The 4 import failures match a 4-buffer client swapchain (glmark2 on
  Mesa's Wayland EGL).
- The leak attribution (Hyprland/aquamarine vs Mesa GBM/zink/Aurora) is the
  open point. If we want it nailed before posting: rerun the trigger with
  `AQ_TRACE=1 HYPRLAND_TRACE=1`, a 2 GB memory cap, and sample
  `/proc/<pid>/fd` (dmabuf links) and `/sys/kernel/debug/dma_buf/bufinfo`
  (exporter, attached devices) every second. Needs a session on the M5, not
  done here (read-only task).
- `M5PRO_DCP_DIRECT_SCANOUT` / `m5pro-dcp.lua` / `hypr-gpu-session` live in
  `contrib/pending/gpu/userspace/mesa-aurora/session-dcp/`.
