# A GPU recovery kills the compositor and can wedge the panel (M5 Pro, G17S)

Status: analysis only. Nothing here is built, applied or tested. Written on the Studio,
from source. Nothing was run on the MacBook.

Trees read:
- kernel `j716s-daily-dcp` @ `bd53915f2ef1` (the daily 7.3.0-gbd53915f2ef1). Paths below are
  under `drivers/gpu/drm/asahi/` unless they say otherwise.
- Mesa `agx3c` @ `a8e86a80cdc` (26.3.0-devel). This is the branch `build-mesa-aurora.sh`
  builds into `/opt/mesa-aurora`. The exact commit in `/opt/mesa-aurora/MESA_COMMIT` was not
  checked, so confirm it matches.

## Incidents

**Incident 1.** An Electron app's GPU process failed GPU work. dmesg shows seven
`recovery fault registers: Ok([0,0,0,0,0,0])`, then the app's EIO and then `ENODATA` for
Hyprland. Both lines say "the client sees a lost device". Hyprland then logged repeated
`eglDupNativeFenceFDANDROID failed` and segfaulted inside zink, under `dri_create_fence_fd`.
The respawned Hyprland failed `eglInitialize`. A later session restart worked.

**Incident 2.** Same pattern: claude-desktop and chromium both failed, Hyprland got ENODATA
and zink segfaulted. This time every respawned Hyprland set up the panel (3456x2234@120,
DPMS on, backlight on) but showed nothing:
- 0 `dcp:iomfb_swap_complete` events;
- aquamarine logged `drm: Cannot commit when a page-flip is awaiting` again and again;
- no `flip_done timed out` lines and no DCP crash lines.

Only a reboot recovered the machine.

---

## 1. Top item: a stuck fence can wedge the display across compositor restarts

### DRM core waits on plane fences with no timeout

`apple-drm` commits with `drm_atomic_helper_commit` (`drivers/gpu/drm/apple/apple_drv.c:560`).
Its commit worker runs the helper's `commit_tail()` first, and only then the driver's own
`apple_atomic_commit_tail` (`apple_drv.c:564-593`).

The helper does this:
- `commit_tail()` calls `drm_atomic_helper_wait_for_fences(dev, state, false)`
  (`drivers/gpu/drm/drm_atomic_helper.c:2064`).
- That call is `dma_fence_wait(new_plane_state->fence, pre_swap=false)`
  (`drm_atomic_helper.c:1861`). The wait is uninterruptible and has **no timeout**.

The plane fence comes from `apple_plane_prepare_fb` → `drm_gem_plane_helper_prepare_fb`
(`apple/plane.c:552-559`). That is the dma-buf's implicit write fence. Zink places the GPU job's
fence there: after every submit it imports the signal semaphore into each exported dma-buf
(`zink_screen_import_dmabuf_semaphore` in `zink_batch.c` `submit_queue`). An explicit
`IN_FENCE_FD` from aquamarine ends up in the same `plane_state->fence`.

So if a GPU fence on a scanout buffer never signals, the commit worker sleeps in D state for
good:
- `commit_planes` never runs, so no swap reaches DCP and there is no swap_complete.
- `drm_atomic_helper_wait_for_flip_done` (`apple_drv.c:592`; its 10 s timeout is at
  `drm_atomic_helper.c:1965`) is never reached, so **no `flip_done timed out` is logged**.
- Every later nonblocking commit gets `-EBUSY` from `stall_checks()`
  (`drm_atomic_helper.c:2397-2404`). That message is only `drm_dbg`, so it is silent.
- aquamarine keeps its own flip-pending flag, because no flip event ever arrives.

That matches incident 2 exactly: 0 swap_complete and no flip_done timeout. If the swap had
reached DCP and been lost, the 10 s flip_done timeout would have fired. So the worker is
blocked before `commit_planes`. The no-timeout fence wait is the likeliest point, and it is the
only one in that path that logs nothing.

### Does the aurora driver signal the fences of commands a recovery fails? Mostly yes, with gaps

Paths that do signal:
- **A failed VM's render work.**
  `settle_render_vm` → `fail_render_vm` → `Pair::quarantine` (`g17/runtime/render.rs:897-919`,
  `:500-521`, `g17/queue/render.rs:1713-1742`) defers `FailedOwned` for every active group.
  `Deferred::finish` → `fail_while_owned` (`g17/completion.rs:787`) → `signal_terminal`. The
  fence signals with the error as soon as the device mutex drops. The command memory stays
  pinned until firmware retires it.
- **Render groups a recovery dropped or failed.** `Retired(.., Err(ENODATA))`
  (`g17/queue/render.rs:2052`, `:2098`) → `complete()` (`g17/completion.rs:711`) signals.
- **Parked render replays.**
  - A closed client, a poisoned VM or a publish failure goes to `fail_replay`
    (`g17/runtime/render/replay.rs:84-136`, `g17/queue/render.rs:2186-2195`), which signals.
  - **But** a replay that stalls for 10 s returns `Err(ETIMEDOUT)` from
    `replay_render_front` (`replay.rs:79-81`) instead of failing the parked groups. The whole
    event service then fails: `run_runtime_events` → `lose_device_quietly` + `stop_runtime`
    (`g17/runtime/events.rs:424-428`). That is a global device loss. It is loud
    (`GPU event service failed`), so check the saved dmesg for it.
- **Non-spared compute.** `quarantine` defers `FailedOwned` right away (`g17/queue/compute.rs:1042-1048`).

The gap, which needs a test: **spared compute is signalled only by a firmware witness.**
- When every active command of a compute queue is spared and the error is ENODATA,
  `spared_deferred` is set (`compute.rs:1036-1038`) and **no** `FailedOwned` is deferred
  (`compute.rs:1043`). The fences wait for `release_witnessed`/exit to produce
  `Retired(ENODATA)` (`compute.rs:1292`, `compute/exit.rs:290-297`).
- The backstop is the compute watchdog, `ComputeQueue::timeout` (`compute.rs:2149-2176`). It does
  settle spared waiters with ETIMEDOUT.
- But `timeout_head()` returns `None` for a quarantined queue that is not `awaiting_witness`
  (`compute.rs:842-844`). `awaiting_witness` requires *every* active entry to hold a ticket
  (`compute.rs:1058-1060`). A quarantined, spared queue with one unticketed entry therefore has
  no watchdog, and its fences can stay unsignalled for good.
- Also: when the watchdog does fire, it reports ETIMEDOUT through `report_failure`
  (`completion.rs:795-797`), which writes the status mirror. Borealis then marks the innocent
  client's device lost (`src/asahi/vulkan/hk_device.c:510-514`).

This analysis cannot say which kernel fence was stuck. The second hypothesis is not ruled out:
after the second recovery the GPU may have stopped completing *new* work. Then the new
Hyprland's own first frame never signals and wedges the same way. Incident 1's respawn failing
`eglInitialize` points that way too.

### What the saved logs can settle (`/root/black-screen-*`)

- `grep -E "blocked for more than|hung_task|dma_fence_default_wait|wait_for_fences"`: a kworker
  stack through `drm_atomic_helper_wait_for_fences` confirms the fence wedge.
- `grep -E "GPU event service failed|restart storm|did not reach state|hw_done timed out|cleanup_done timed out"`.
- All `G17:` lines after the second recovery: `blames queues`, `firmware blamed queue`, and
  "render slot N: ... replaying/failing".
- The `reported at` site on Hyprland's ENODATA line (see §2).

Next time, before rebooting:
- `cat /sys/kernel/debug/dma_buf/bufinfo` lists each buffer's fences, with timeline name, seqno
  and signalled state. It names the stuck fence and its driver.
- `echo w > /proc/sysrq-trigger` dumps D-state stacks.
- `cat /sys/kernel/debug/dri/*/state`.
- Run `vkcube` or `eglinfo` from a TTY to see whether the GPU still finishes new work.

---

## 2. Q1: What one client's fault does to other clients' contexts

**There is no global poisoning.** No code walks every open file and marks it lost.

A VM's status (`g17/status.rs`) becomes sticky only through its own completions:
- `VmStatus::record` (`status.rs:85-94`), or `report_failure` (`status.rs:110-151`), which writes
  the mirror word Borealis polls (`hk_device.c:503-514`).
- The failure is spread per VM only: `settle_render_vm` plus `fail_compute_vm`, matched by
  `Arc::ptr_eq` on the status (`g17/runtime.rs:1791-1811`, `:1879-1883`).

**Why the compositor died anyway.** It is the M5 recovery classification combined with how
ENODATA is treated:
1. The M5 recovery path gets no attribution evidence by design.
   - `InitData::fault_sources` returns `Sources::sample(mask, |_| None)` on M5
     (`g17/initdata.rs:1898-1902`). That is the `sampled 0 known_keys 0`.
   - The M5 reason is read only when the MMU fault status bit is set
     (`g17/runtime/events.rs:146-166`). With all-zero registers that gives `reason None`.
   - So `attribute()` always returns `Attribution::Firmware` (`g17/recovery/attribution.rs:84-89`).
2. `recovery::classify` gives up without classifying anyone in two places:
   - with no guilty or blamed QID (`g17/recovery.rs:391-393`);
   - when a guilty QID has no in-flight owner, or more than 8 VMs are guilty
     (`recovery.rs:427-429`).

   Only past those checks does `classify_work` mark innocents `Spared` (`recovery.rs:436-447`).
3. Work a recovery dropped before it ran comes back with ENODATA: unexecuted after crossing the
   recovery (`g17/queue/compute/retirement.rs:179-193`), or from the replay paths.
   `Completion::poisons(ENODATA)` is **true** for unclassified work (`g17/completion.rs:621-624`).
   It only spares ECANCELED, `Spared`, or interrupted-but-not-guilty.
4. For compute: the poll error goes to `quarantine(ENODATA)` (`compute.rs:1187`). The queue is
   not all-spared, so it defers `FailedOwned(ENODATA)`.
   - `DeferredBatch::push` records it (`g17/runtime.rs:1420-1423`). That is the
     `reported at g17/runtime.rs:1422` site.
   - The queue terminal then records again and fails **every** queue of that VM
     (`runtime.rs:1879-1883`).
   - Borealis sees the mirror and loses the device (`hk_device.c:510-514`). Zink follows.
5. The render side already does this right: groups a restart dropped are classified `Spared`
   before ENODATA (`g17/queue/render.rs:2052`, `:2097-2098`). Consumers of failed producers get
   ECANCELED (`g17/dependency.rs:20-24`). Compute dropped work, and
   `compute_replay.rs:150` `Retired(ENODATA)`, do not.

The message `N commands were in flight; each is retired from its own queue's records` confirms
the M5 branch ran (`recovery.rs:306-312`). On that branch the table only classifies; nothing is
marked interrupted (`recovery.rs:342-364`).

Hyprland's `reported at` site shows which path hit it:
- `g17/runtime.rs:1422`: compute quarantine (item 4).
- `g17/completion.rs:631`: a `Retired(ENODATA)` that was never classified, for example
  `runtime/compute_replay.rs:150`.

If Hyprland's queue was in the M5 table's guilty set, it was classified Guilty. That points at
unreliable M5 guilty flags; the `blames queues` / `firmware blamed queue` lines tell.

**Upstream asahi (G13/G14, the same tree's `gpu.rs`/`workqueue.rs`):**
- Bystanders are killed per command, not per VM.
  - `mark_pending_events` gives non-culprit events `WorkError::Killed` when the timeout names a
    slot (`gpu.rs:1141-1176`).
  - A fault with info kills only commands whose `vm_slot` differs (`workqueue.rs:258-263`).
  - `Killed` maps to ECANCELED (`workqueue.rs:91`). With no fault info at all, every pending
    command gets ENODATA (`workqueue.rs:90`, `gpu.rs:1625-1637`).
- There is no sticky VM poisoning, and the userspace (gallium asahi) does not turn one failed
  command into a lost context.
- Here, the sticky VM status plus Borealis reading any status as device loss means innocents must
  be classified exactly, and the M5 classification has the holes above.

### Kernel fix (A): dropped work never poisons; mirrors what render already does

- `g17/completion.rs:621`, `poisons()`: add `if error == ENODATA { return false; }` first. A
  command that never ran cannot have faulted the GPU. A blamed command fails with EIO through
  `settle_blamed_render` (`runtime/render/settle.rs:126-148`), so a guilty VM is still poisoned.
- `g17/queue/compute.rs:1034-1038`, `quarantine()`: when `error == ENODATA`, classify every active
  completion that is not `guilty()` as `Spared` before computing `all_spared`. The existing
  `!spared()` checks on the terminal (`compute.rs:1050-1055`) and in `fail_while_owned` then
  stop the VM-wide fan-out.
- `g17/runtime/compute_replay.rs:148-151`: `packet.completion.classify(Spared)` (unless guilty)
  before `Retired(.., Err(ENODATA))`.
- Test: a KUnit case in `recovery.rs` with `Attribution::Firmware`, `guilty_qids == 0`, and a
  bystander compute queue whose front is unexecuted after the restart. Expect ENODATA on its
  fence with `VmStatus::get() == 0`. On hardware: a hang test client next to a zink compositor.

### Kernel fix (B): every fence a recovery touches signals within a bound

- Close the compute watchdog hole: arm `timeout_head()` for a quarantined `spared_deferred`
  queue even when an entry has no ticket. A simpler alternative: settle every `spared_deferred`
  waiter with `FailedOwned(ENODATA)`, not ETIMEDOUT, after `timeout::RECOVERY_WAIT_MS`. Spared
  work then fails without a lost device.
- In `replay_render_front`, fail the stalled parked groups with
  `fail_replay(ENODATA, …)` after classifying them `Spared`, instead of returning ETIMEDOUT
  (`replay.rs:79-81`). The latter takes the whole GPU down.
- A generation sweep to catch future gaps: N seconds after a recovery completes, any completion
  retained across it and still unsignalled gets an ENODATA failure, with a warning naming the
  queue.

### Kernel fix (C): read the M5 recovery reason and stamp

`RUNTIME-DIFF-27.2.md` §2 documents both. Status B `+0x4aac` holds the firmware reason (5 = DSF
pause timeout on 27.2+, 6 = sleep forced-idle timeout on 27.3). `+0x4aa8` holds the stamp word of
the faulting command. Read them in the M5 branch of `fault_sources` (`initdata.rs:1901`), log
them, and feed the stamp to blame. This gives real attribution and answers §3's "what did the
app do".

### apple-drm hardening (D): a GPU bug must never black-screen the panel

Replace the helper's unbounded wait. Use a local `atomic_commit` that copies
`drm_atomic_helper_commit` with its own commit work. There, wait each plane fence with
`dma_fence_wait_timeout(fence, false, ~1 s)`. On timeout, `drm_warn` with the fence's driver and
timeline name, drop the fence and scan out anyway (a stale or torn frame instead of a dead
panel). This is about 60 lines.

---

## 3. Q2: Why the Electron/Chromium GPU process faults the G17S

The dmesg cannot say what the app submitted. What it does say:
- **Not an MMU fault.** The M5 fault registers were all zero (`events.rs:146-161`), so this was not
  an out-of-bounds or unmapped access. That makes sampler or descriptor overruns and bad large
  allocations unlikely; those surface as page faults.
- **Firmware-initiated, reason unread.** M5 never reads the reason word, hence `reason None`. Per
  the kext mapping in `RUNTIME-DIFF-27.2.md` §2 the candidates are the hang/timeout class: reasons
  0, 2, 4 and 5 ("DSF pause timeout").
- **`slot_mask 0x25`** is the M5 recovery slot mask (status B `+0x4ab8`). Bits 0, 2 and 5 mean
  three firmware slots were involved, so several clients were running at once. `sampled 0` and
  `known_keys 0` are always zero on M5 (`initdata.rs:1898-1902`) and carry no information.
- **`stampless lifetime total 0`.** No compute command was ever retired without stamp evidence
  (`queue/compute/retirement.rs:125`). That rules out the stampless fallback.
- **The same signature appeared at 449 s and 498 s** with the native-GL test client
  (`/opt/mesa-aurora-gl2`) running next to the zink compositor. That client is not Chromium.
  - So the common factor is a second GPU client running at the same time as the compositor.
  - This points at concurrency or preemption: a firmware scheduling-pause timeout on long
    non-preemptible work, not a Chromium-only feature.
  - It is a hypothesis. The test below confirms or refutes it.

What Chromium adds through zink (the session env exports `MESA_LOADER_DRIVER_OVERRIDE=zink` to
everything Hyprland starts, `userspace/mesa-aurora/session/session.env`). ANGLE's GL backend
reaches Borealis through zink with:
- **A robust context.** ANGLE requests robust access, so zink builds `robust_access` VS variants
  (`zink_compiler.c:4224`). The compositor never builds them.
- **Skia GPU raster.** MSAA render targets and resolves, `glBlitFramebuffer`,
  `glCopyTexSubImage`.
- **Continuous BGRA tile uploads.** Staging buffer → image copies. These run on Borealis transfer
  streams (`hk_cmd_meta.c:4750-4860`), likely on compute queues.
- **GBM/dmabuf buffers for Ozone** and `glReadPixels` readbacks.

None of these is a known G17S defect in this tree's notes (`gl-native/APP-REGRESSIONS.md`).

How to pin it down:
1. Ship fix (C), so the next recovery logs the reason and the faulting command's stamp (render
   vs compute, which queue).
2. Run Electron A/B with `--disable-gpu-rasterization` (GPU compositing kept), then
   `--disable-gpu-compositing`.
3. Run two GPU clients without Electron (for example glmark2 and vkcube under the zink
   compositor) to test the concurrency hypothesis.

---

## 4. Q3: The zink segfault after a lost device

### What should happen, and what does

- **Expected.** A robust GL context gets `PIPE_GUILTY_CONTEXT_RESET` through
  `ctx->reset.reset` (`check_device_lost`, `zink_context.c:276-284`). The state tracker then
  switches the context to the context-lost dispatch, so GL calls become no-ops and
  `glGetGraphicsResetStatus` returns GUILTY.
- **Observed.** Hyprland kept issuing explicit-sync calls:
  - `fence_get_fd` returns -1 once `screen->device_lost` is set (`zink_fence.c:216-220`). That is
    the `eglDupNativeFenceFDANDROID failed`.
  - Then a segfault in zink, reached from `dri_create_fence_fd` (`frontends/dri/dri_helpers.c:117-142`).
  - Frames #7-#9 look like threaded-context `tc_flush`/`tc_create_fence_fd` → `_tc_sync` →
    `tc_batch_execute` (`auxiliary/util/u_threaded_context.c:728-775`, `:3538-3548`). They execute
    queued calls into zink after the loss.

### Null-dereference candidate, from source

This needs the symbolized frames to confirm.
- After `screen->device_lost`, `zink_end_batch` returns before submitting (`zink_batch.c:897-899`).
  The ended state is never marked submitted or completed, so `find_completed_batch_state` cannot
  recycle it (`zink_batch.c:438-450`).
- Every flush therefore takes `get_batch_state` → `create_batch_state` (`zink_batch.c:502`).
  Each one allocates command pools and a descriptor buffer. That means a GEM object and a VM bind
  on a dead device.
- `create_batch_state` returns NULL on any failure (`zink_batch.c:392-400`).
- `zink_reset_batch` assigns that NULL to `ctx->bs` (`zink_batch.c:509-512`). Its `assert` is
  compiled out because the build uses `-Db_ndebug=true` (`build-mesa-aurora.sh:39`).
- `zink_start_batch` then dereferences it: `bs->ctx = ctx` (`zink_batch.c:548`). The next
  `zink_flush` reads `ctx->bs->has_work`.

Secondary issues:
- `post_submit` resets only the submitting context (`zink_batch.c:614-623`).
- `submit_queue` still imports never-signalled semaphores into dma-bufs after a failed
  `vkQueueSubmit` (`zink_batch.c` around 811-830).
- `zink_create_fence_fd` leaks the fence on failure (no `FREE(mfence)`, `zink_fence.c:367-371`).
- `dri_create_fence_fd` does not check its `CALLOC` (`dri_helpers.c:122`).

Symbolize on the MacBook. A release build has no DWARF, so use the symbol table, and subtract 4
for the aarch64 call site:

```sh
f=/opt/mesa-aurora/lib/libgallium-26.3.0-devel.so
readelf -S "$f" | grep -q symtab && echo unstripped
for a in 0xac3da8 0xac7cbc 0xb13fec 0x8a2dd8 0x8a4668 0x8a5200 0x13d9a4; do
  gdb -batch -ex "info symbol $((a - 4))" "$f"
done
```

### Proposed zink fix (upstreamable; same logic in Mesa main as far as checked)

1. `zink_reset_batch` returns bool and never stores NULL. `zink_start_batch` and `flush_batch`
   keep the old state and call `check_device_lost()` when it fails.
2. In the `screen->device_lost` early return of `zink_end_batch`, mark the state submitted and
   completed and signal its tc fences' `ready`. Batch states are then recycled and nothing
   allocates on a dead device.
3. When a submit hits `VK_ERROR_DEVICE_LOST`, skip the dma-buf semaphore import and call the reset
   callback of every context on the screen, not just the submitter.
4. Free `mfence` on the `zink_create_fence_fd` failure paths. Check the `CALLOC` in
   `dri_create_fence_fd`.

Also check that Hyprland 0.57 creates its EGL context with
`EGL_CONTEXT_OPENGL_RESET_NOTIFICATION_STRATEGY_EXT = EGL_LOSE_CONTEXT_ON_RESET_EXT`. Without it,
zink has no reset callback to call. No Hyprland tree was available here to check this.

The respawned Hyprland's `eglInitialize` failure (incident 1) is not explained by this
analysis. Capture `EGL_LOG_LEVEL=debug MESA_DEBUG=1` output from the respawn. Rule out a new VM
whose first work never completes (see §1).

---

## 5. Mitigations, ranked

| # | What | Effort | Effect |
|---|---|---|---|
| 1 | Kernel A + B: dropped work never poisons; every recovery-touched fence signals within a bound | small (A) / medium (B) | A client fault no longer takes the compositor's VM, and no fence can wedge KMS |
| 2 | apple-drm D: bounded plane-fence wait | small–medium | Any future GPU-driver fence bug costs a frame, not the panel until reboot |
| 3 | Stopgap now: Electron/Chromium without the GPU (below) | none | Removes the trigger seen in both incidents; costs CPU |
| 4 | Kernel C: read the M5 reason and stamp | medium | Correct blame; diagnoses §3 |
| 5 | zink robustness (§4) | medium | A real loss becomes `GL_CONTEXT_LOST`, not a segfault |
| 6 | Hyprland: robust context and reset handling; respawn backoff in `start-hyprland` | out of tree | Compositor survives or restarts cleanly |

### Stopgap: Chromium/Electron without the GPU (Omarchy)

- **Which flag.** Use `--disable-gpu`. Add `--disable-gpu-compositing` if a GPU process still
  appears. `--use-gl=disabled` is legacy and is not accepted by current Chromium, so do not rely
  on it. Chromium also accepts a single dash (Omarchy's Obsidian file uses `-disable-gpu`).
- **Chromium and Omarchy web apps:** `~/.config/chromium-flags.conf`, one flag per line. Omarchy
  already ships this file with the Wayland flags. Add `--disable-gpu`.
- **Electron apps on Arch's system `electron*` packages:** the wrapper reads
  `~/.config/electronNN-flags.conf`, then `~/.config/electron-flags.conf`.
- **Apps with their own file:** for example `~/.config/obsidian/user-flags.conf` (Omarchy already
  sets `-disable-gpu` there) and `~/.config/code-flags.conf`.
- **Apps that bundle Electron**, as claude-desktop's process name suggests: a flags file has no
  effect unless the app's launcher script reads one (`grep -i flags "$(command -v claude-desktop)"`).
  Override the desktop entry instead:
  1. Copy its `.desktop` file to `~/.local/share/applications/` under the same name.
  2. Append `--disable-gpu` to `Exec=`.

  Omarchy's launcher and `uwsm-app` use desktop entries, so the override wins.
- **Per-app alternative without flags:** `Exec=env LIBGL_ALWAYS_SOFTWARE=1 <app>`. Chromium sees
  llvmpipe (built into `/opt/mesa-aurora`) and falls back to software compositing.
