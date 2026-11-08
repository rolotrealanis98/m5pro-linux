# GPU recovery: isolation, bounded fences, bounded plane-fence wait (M5 Pro, G17S)

Built 2026-11-08, not yet run on the MacBook. Builds on `../GPU-RECOVERY-KILLS-COMPOSITOR.md`; tracker issue
rolotrealanis98/m4-m5-linux#36.

## Patches (branch `j716s-daily-dcp-recovery`, base `bd53915f2ef1`; files `0001-0003*.patch` here)

| # | Commit | What |
|---|---|---|
| 0001 | 89701e82 drm/asahi: g17: Fix a GPU recovery failing the compositor for compute work it dropped | Compute work that comes back unexecuted (ENODATA) after crossing a recovery, with no fault reported on its queue, is classified Spared: it replays or fails with ENODATA without the VM-wide fan-out. A zero-duration record without a recovery stays Guilty (the queue's own fault) and fails the VM as before; a late fault report reclassifies Guilty. `poisons()`: ENODATA poisons only when Guilty. |
| 0002 | aa6c7b0e drm/asahi: g17: Fix fences of work a GPU recovery dropped failing as a lost device or never signalling | Spared compute whose watchdog expires fails with ENODATA, not ETIMEDOUT (ETIMEDOUT reached the status mirror and lost the innocent client's device); a spared queue with an unticketed entry fails at once (its witness can never arrive); `timeout_head()` reports queues whose spared work still waits; a render replay stalled 10 s fails its parked groups Spared/ENODATA instead of returning ETIMEDOUT (which killed the event service and every client's device). Timeouts: the drm_sched job watchdog, 2 s per expiry, bounded renewals on M5 (about 2 s typical, 38 s worst); parked render replays keep 10 s. |
| 0003 | ed7e1d0c drm/apple: Fix a GPU fence that never signals wedging the display | `apple_atomic_commit` = `drm_atomic_helper_commit` minus self-refresh accounting; all plane in-fences of a commit share a 1 s `dma_fence_wait_timeout`, on timeout the fence is dropped with one rate-limited `drm_warn` (driver and timeline named) and the frame is presented; after the helper's 10 s flip_done timeout the commit's own pending event is sent as failed (`-ETIMEDOUT` on its out-fence) through `dcp_drm_crtc_flip_lost`, so the `-EBUSY` stall path is bounded (about 1 s + 10 s). |

Correction to the analysis: the compute queue's own watchdog is armed in drm_sched and never consults
`timeout_head()`; the real gaps were the error code and the unpublished entries.

## Builds (`~/Work/agents/gpu-recovery/`, all 0600)

Release `7.3.0-ged7e1d0c42b0`; config identical to daily-dcp; Fedora 43 container, clang 21.1.8, rustc 1.99.1,
bindgen 0.73.2. Warnings: the full build's set is identical to the daily build's (19 Rust deprecation/dead-code
warnings); W=1 + CLIPPY=1 on `drivers/gpu/drm/{asahi,apple}` at the base and at each commit: 51, none new.

| Artifact | sha256 |
|---|---|
| kbuild/Image.gz | ee0e54a38ff0313f2f6228ab97d833defc2b69679e7aff7daaaf021f42070141 |
| kbuild/t6050-j716s-daily-dcp-recovery.dtb (= the daily's) | c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d |
| modules-7.3.0-ged7e1d0c42b0.tar.zst | d6e07f7a00b1980f84180264736d542a435d060e64fae04383849f7af6eba9e9 |
| daily-dcp-recovery-test-20261108-24a688f0.bin | 24a688f0e1b35f227f306fe156dd8f7036469449e939c976d1ef599674aa4ebf |

Payload: phfix loader, in-tree DTB, loop-safety initramfs `initramfs-ftab-wdt2`, variables show-notch +
`m5pro,gpu=1` + `m5,t6050-display=1`, bootargs `m5.selftest=1 watchdog.open_timeout=300 log_buf_len=16M
appledrm.fw27_panel_vrr=1 rcupdate.rcu_cpu_stall_timeout=21`. Install the modules tarball before the first boot.

## Test plan

`recovery-test.sh TRIGGER-CMD...` as root with the session up (results in `/root/recovery-test-<date>/`): records
Hyprland's pid, a vkcube baseline, the `dcp:iomfb_swap_complete` rate and a dmesg mark; runs the trigger; checks that
Hyprland survives, swaps continue, vkcube is alive or exits cleanly, recovery lines appear, the lost-device line
appears only for the trigger, no "page-flip is awaiting", no RCU stall or hung-task lines. No synthetic GPU-hang
program was written; the trigger is the natural one: a multi-client GPU load (several vkcube instances, glmark2,
Chrome with GPU acceleration, quickshell), which produced faults within minutes today.

## Expected before (daily) and after

| Case | Before | After |
|---|---|---|
| Faulting client | lost device | unchanged |
| Hyprland, bystander compute | ENODATA lost device, zink SEGV | no lost-device line; work fails with ENODATA or replays |
| Spared compute hits its watchdog | ETIMEDOUT, lost device | ENODATA, no lost device, about 2 s (38 s worst) |
| Render replay stalls for 10 s | "GPU event service failed", every device lost | parked groups fail spared with ENODATA |
| Plane fence never signals | worker stuck, panel black until reboot | 1 s, one warning, a stale frame |
| DCP never completes a flip | event pending forever, "page-flip is awaiting" | event failed after 10 s, the next commit goes through |

## The 10:56 and 11:12 wedges

The only blocked task in both sysrq dumps was a kworker in `synchronize_rcu` (key garbage collector); no DRM commit
frames were blocked, so a flip whose completion event never arrived fits (fix 0003 fails it after 10 s). The RCU
grace-period stall itself is not fixed: PREEMPT_RCU=y, the recovery handshake sleeps, busy loops are bounded; one
unproven lead is the `ExportFence` drop running from the dma_fence `release_cb` inside an RCU read section and
cascading into `complete()`/`owner_done()`. Next capture on a wedge: the stall detector's output (bootarg set) and
`echo t > /proc/sysrq-trigger`. Hyprland's ENODATA lines today were reported at `g17/runtime.rs:1422`, the same site as
the bystanders', which 0001 covers.
