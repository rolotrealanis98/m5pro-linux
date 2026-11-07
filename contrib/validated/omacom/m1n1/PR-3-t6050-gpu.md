kboot_gpu: T6050: hand the GPU to the G17 driver from the ADT (stacked on PR-2)

Base: PR-2 (`omacom/t6050-n1`). This PR adds one commit, `src/kboot_gpu.c` only, and does not depend on PR-2's code: it cherry-picks onto PR-1 or #26 unchanged. Branch: `omacom/t6050-gpu`.

aurora-silicon/linux's G17 driver (`apple,agx-g17s`, #1012, with the 27.2/27.3 InitData in #1173) takes over the M5 Pro GPU as iBoot leaves it: both GPU coprocessor images loaded but not started, and the UAT already set up. The driver needs that state described as reserved memory, and the two coprocessor mailboxes at their native windows. On integration/aurora, `dt_set_gpu()` has no T6050 case.

This adds `dt_set_gpu_t6050()` next to the T8140 fill. It uses the same reserved-memory names, `dt_set_resvmem()` and disable path. Everything comes from the ADT of the current boot. It reads and writes no GPU register.

| DT | ADT |
|---|---|
| `/reserved-memory/uat-handoff`, `uat-l2-pagetables`, `uat-pagetables`, `uat-ttbs` | `/arm-io/sgx` `gfx-handoff-*`, `gfx-shared-l2-region-*`, `gfx-shared-region-*`, `gpu-region-*` |
| `/reserved-memory/gpu-fw-text` | from `/arm-io/gfx-asc` `__TEXT` start to `/arm-io/gfx1-asc` `__TEXT` end (`segment-ranges`) |
| `/reserved-memory/gpu-fw-data` | from `gfx-asc` `__DATA` start to `gfx1-asc` `__DATA_SHARED_RO` end; each segment must sit at the matching sgx `gfx{,1}-data{,-shared-ro}-base` |
| both GPU mailboxes: `reg` (wrapper and iop-vbar), then `status = "okay"` | `reg[0]`/`reg[1]` of the coprocessor whose ADT `role` is the mailbox's `apple,firmware-role` (GFX, GFX1); its interrupts must be that coprocessor's |

Before anything is published:
- the gpu node's `sgx` window must be the ADT's;
- both firmware spans must be contiguous;
- every region must be non-zero, 16 KiB aligned, below 4 TiB, not overlapping another region, and have its `/reserved-memory` node.

If any check fails, the gpu node, both mailboxes and every region already published are disabled, and the boot continues. The firmware images move between iBoot builds (on the same J716s, two builds placed `fw-text` 0x38000 apart), so no address is hardcoded.

When it runs: only for a gpu node that is `apple,agx-g17s` and enabled in the DT. There is no `chosen.*` opt-in: as with T8140, the DT that comes with the kernel decides.

Relation to edimoldovan's `j714c/m1n1` (`160b644 kboot: GPU handoff for T6050`, not in #26): that commit generalises the T8140 fill to `dt_set_gpu_g17()` and calls it for a gpu node that is `apple,agx-t6050` / `gpu,t6050`. It fills the OPP table and the four UAT regions, and requires the perf-state shape 14/13/4. The two serve different kernel drivers and can coexist, dispatched on the gpu node's compatible:
- The J716s ADT's sgx has `perf-state-count` 14, `gpu-num-perf-states` 13 and `perf-state-table-count` **2**, so the 14/13/4 check would disable a J716s GPU. Table count 2 is the M5 Pro (G17S) and 4 presumably the M5 Max.
- `apple,agx-g17s` (#1012) keeps its own operating points and needs the firmware spans and mailboxes, which that fill does not publish.
- This function returns at once for any other compatible, so a J714c DT is untouched. If `160b644` lands, the T6050 branch of `dt_set_gpu()` becomes "g17s here, agx-t6050 there"; I can rebase onto it either way.

### Testing

MacBook Pro 16-inch, M5 Pro (J716s, Mac17,8), macOS 27.3 beta 1 stub (26C5035r). Kernel: aurora-silicon/linux #1012 + #1173.

This code was tested in our own stage 2, not on this branch. That build read the same ADT sources and published the same values, gated by a payload variable (`chosen.m5pro,gpu=1`); it also enabled the gpu and PMGR nodes itself (here the DT does). On 2026-11-07:

- E2a (variable unset): GPU nodes left as the DT has them, driver idle, 18 CPUs, N1 adopted: pass.
- E2b (hand-off on): the six regions and both mailboxes published, all outside Linux RAM. The kernel log showed `GPU firmware: 27.3 (26C5035r), G17S`, `M5 primary initdata acknowledged`, `M5 secondary initdata acknowledged`, `M5 firmware opening records retired` and `[drm] Initialized aurora 1.0.0 for 2300000000.gpu`. There was no SError and no UAT or DART fault: pass.
- First frame on the same payload: Vulkan (`Apple M5 Pro (G17S B1)`) passed compute, render and a stress run (`render.first` 206 iterations, `xq.chain` 8114 iterations, 0 errors). GL ran on zink. A GPU-rendered frame reached the panel, and Hyprland ran on the GPU: 13 of 13 checks passed.

This branch:
- Not booted. The boot-test payload is built: the E2 kernel, the E2 DTB with `&gpu` and `&pmgr_gfx` okay, `chosen.asahi,t6050-n1=4`, self-test on. This loader disables the stage 1 watchdog, so the boot has to be attended.
- Host test (aurora branch, same function): run against a J716s ADT with the J716s DTB, it fills the six regions and both mailboxes. With the gpu node disabled it changes nothing. A wrong sgx base, two mailboxes claiming one role, a foreign interrupt, or a single mailbox each leave everything disabled.
- Builds with `make` and `make CHAINLOADING=1`: 15 warnings, the same as #26, none new. Image sizes unchanged (0x410000 / 0x420000). CI's pytest set (Linux): all pass. `git clang-format`: clean.

Dependencies: aurora-silicon/linux #1012 and #1173, plus J716s DT GPU nodes. Those nodes keep the six regions and both mailboxes disabled with placeholder `reg`; m1n1 fills and enables them.

Questions:
- Opt-in or DT-decides? I followed T8140. An explicit `chosen.asahi,t6050-gpu=1` is a few lines on top.
- @edimoldovan: which GPU driver does your J714c kernel bind, `apple,agx-t6050` from your branch, or #1012's G17 driver? If it is #1012, the M5 Max likely only needs `apple,agx-g17c` added here.
