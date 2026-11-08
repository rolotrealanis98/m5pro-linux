# omacom/m1n1 T6050 stack rebased onto #30 head 140a36b (2026-11-08, local only, nothing pushed)

#30 (`edimoldovan:j714c/diskboot`) moved ad08bf5 -> 140a36b3015a "main: keep the heap the last steps before the jump
allocate" (fast-forward, one commit: chainload.c/.h, kboot.c/.h, main.c, +69 lines). The five PRs are all based on
`integration/aurora` and stack by containing each other's commits:

    #33 bringup (2 own commits) -> #34 n1 (+5) -> #37 gpu (+1) -> #35 display (+5, incl. phandle fix) 
                                                         \-> #36 wdt-keep (+1) sits on db0d3bf, the display tip BEFORE the phandle fix

(#36's 22 commits = #35's old tip db0d3bf + 02785a3. It does not carry ffee101; kept that way, "same stacking".)

## Branches (repo ~/Work/agents/aurora-prs-2/m1n1, worktree ~/Work/agents/omacom-m1n1/tree-r2)

| PR | branch | old tip (fork) | new tip | own commits |
|---|---|---|---|---|
| #33 | omacom-t6050-bringup-r2 | 275ecc4205ad | ff75a40df862 | 2 |
| #34 | omacom-t6050-n1-r2 | f1a942e393d1 | 9879c2f9b488 | 5 |
| #37 | omacom-t6050-gpu-r2 | 4e461025b9ec | 2bebfe7708c7 | 1 |
| #35 | omacom-t6050-display-r2 | ffee10193201 | 5818f6bdd73b | 5 |
| #36 | omacom-wdt-keep-r2 | 02785a35e046 | 64c8ce217115 | 1 |
| (test only, do not push) | omacom-stack-r2-test = wdt-keep-r2 + phandle fix | | 194eac067eaf | |
| (helper) | omacom-t6050-display-r2-prefix = display-r2 minus the phandle fix (wdt-keep-r2's parent) | | | |

Existing branches untouched. Below our commits every branch had #30's old tip ad08bf5; now 140a36b.

## Conflicts

None textually: every `git rebase --onto` applied cleanly, and `git range-diff` shows `=` (identical patch) for all 14
commits except the first. 140a36b touches kboot.c/main.c/chainload.c at places none of our commits edit.

One semantic break, fixed: 140a36b makes two more CI host tests fail on #30's head (pytest at 140a36b: 5 failed
+ 141 errors; the old ad08bf5 had 4 + 141). Our first commit ("tests: build the T6050 paths that #30 adds", #33) now
covers them (amended in place, so every commit above it has a new hash; message "Five" -> "Six"):
- `tests/python/test_chainload_run_base.py`: harness compiles `chainload_image()`, which now writes the file statics
  `staged_boot_args`, `staged_args0`, `staged_heap_end`; declared beside the model state (+2 lines).
- `tests/python/test_smp_handoff_gate.py`: harness compiles `kboot_prepare_dt()`, which now sets `retained_heap_end`;
  declared (+1 line).
These are #30's own regressions on #30; they sit in our #33 for the same reason as the other four.

## Interaction of 140a36b with our hand-offs (static analysis, r2 tips; no hardware run)

What 140a36b does: `kboot_prepare_dt()` takes the heap high-water once (kboot.c:6951, `retained_heap_end`, kboot.c:6971/6973)
and reserves [_end, heap_end) in the FDT. Heap is a bump allocator from top_of_kernel_data (heapblock.c:37, high-water
only grows). Everything allocated after that point (the rest of prepare_dt, i.e. all dt_set_* incl. ours) was never
reserved. Now main.c:349-354 calls `chainload_retain_late_heap()` (no-op for a Linux boot: `staged_boot_args` is set
only by chainload_image and `args[0] != staged_args0`) and `kboot_retain_late_heap()` (kboot.c:6677; active because
kboot_boot set `next_stage.args[0] = dt`, kboot.c:7221), which extends the reservation to the current high-water and
returns -1 (m1n1 goes back to the proxy) if the FDT edit fails.

Nothing of ours allocates after that new point (main.c:349), reads `cur_boot_args.top_of_kernel_data`, or touches
`retained_heap_end`/`staged_*`. Our new allocations are all inside kboot_prepare_dt, i.e. before it, and are now
covered (they were not before):

- #37 GPU (`dt_set_gpu_t6050`, kboot_gpu.c:3269): no heap, no DART init. ADT -> DT only (mailbox regs, UAT/firmware
  regions from the ADT via dt_set_resvmem). Unaffected; nothing to retain.
- #35 display (`dt_reserve_t6050_oslogs` kboot.c:5357, `dt_set_display_t6050` kboot.c:5570): reads registers, never
  initialises or walks a DART (comment at kboot.c ~5463: tables, firmware segments and /vram lie above published RAM). Only
  heap use: `t6050_dt_save()` = malloc(dt_bufsize) (kboot.c:5260), freed in `t6050_dt_done()`, once per function. Those
  transient copies raise the high-water after the early reservation; the late reservation now sweeps them in:
  about one dt_bufsize (FDT size + 96 KiB) of extra reserved RAM. Benign. `display_shutdown()` (main.c:342) does nothing on
  our T6050 path (no iboot session; display already up); if a DCP session ever existed there, it now ends up reserved
  because the call sits before the new one.
- #34 N1 (`kboot_setup_n1` kboot.c:7050, after the early reservation): `pcie_t6050.c:651` smc_init (calloc, ASC, RTKit buffers;
  `smc_shutdown` frees and quiesces it) for t6050-n1=2|4; `pcie_t6050.c:770` nvme_init (ANS RTKit, queue memalign in
  nvme.c:181-189, bounce buffers) and the 8 KiB block (778) for =3|4, ending with `nvme_stop()` (751): ANS and SMC sessions
  are dead before Linux, so those pages are dead memory. Before: unreserved (harmless because dead). Now: reserved
  (a few hundred KiB lost to Linux, nothing breaks). When ANS is already running at entry, no allocation. The N1's own
  DART is only read (kboot_n1.c:247-258), no tables of ours exist. If nvme_stop fails the code reboots through the
  watchdog (pcie_t6050_storage_lost) and never reaches the jump.
- #33: the RVBAR relay is a page below the image (smp.c), reserved explicitly (kboot.c ~6985), not heap. Unaffected.
- #36 wdt-keep: `wdt_disable()` still runs (main.c:247) and returns early under keep (wdt.c:37). The new failure path
  (main.c:351-353, `uartproxy_run`) therefore waits with the watchdog armed: the machine resets into the earlier stage's
  fallback after the deadline instead of sitting in the proxy. Same as the existing NVMe/display proxy returns in that block;
  acceptable (arguably wanted for the loop).

Only risk to watch on hardware: `kboot_retain_late_heap()` needs room in the FDT buffer (fdt_open_into to dt_bufsize,
+16 bytes memrsv entry). Our T6050 additions (oslog nodes, N1, GPU regions, display props) fit in the +96 KiB headroom with
margin by construction, but the J716s has not run it; the log line to expect is `FDT: late heap [0x..., 0x...) retained`
(absent if the heap did not grow) and no `could not reserve the late heap`.

## Build / tests (Fedora 43, clang/lld 21.1.8, rustc 1.99.1, build/build-r2.sh, results in build/r2/)

- plain `make` (m1n1.bin 0x410000 = 4259840 bytes for base-r2, all 14 commits, and each tip) and CHAINLOADING=1 (0x420000
  = 4325376 bytes, base and each tip): 15 warnings each, identical sets to 140a36b and to the pre-rebase tips (no new
  warning; the occasional "NEW" line in new-warnings.txt is parallel-make output interleaving of the same rust warning).
- pytest (omacom CI set): 140a36b itself 5 failed + 141 errors; ff75a40 / 9879c2f / 2bebfe7 / 5818f6b: 442 passed; 64c8ce2 /
  194eac0: 443 passed (17 skipped, 10 subtests). Before the test fix, ff75a40 had 2 failures (r2-pass1/).
- `git clang-format --diff <parent> <tip> -- src`: empty for all five (and the stack test branch).
- Greptile-style script: none exists in the repo or in omacom-m1n1; the compiler warning diff (-Wall -Wextra as the Makefile
  has them) is the only static check run.

| image | commit | bytes | sha256 |
|---|---|---|---|
| base-r2 plain (140a36b) | 140a36b | 4259840 | f25a4e10e3656508245fffc811673a995b02daef9dc2a71b2b14e18e735da433 |
| ci-base-r2 (CHAINLOADING=1) | 140a36b | 4325376 | 5d895510645852ae2b4172156561b3b0f346f0e944b495624c1eff44c4a8bf89 |
| c02 plain, #33 | ff75a40 | 4259840 | 9a7f45bb91b6f745f56f66d2de86a3ad8e9fa8ffdb5a86192f26802e3ab2edbd |
| ci-bringup | ff75a40 | 4325376 | 5464cc16b17e97dcc224367d9c8ee4e4082ed921c9d93216b172838b35f8d0fa |
| c07 plain, #34 | 9879c2f | 4259840 | aa17bb7751dbf2d72d090e91d560902b0105465b92f0f586ba150d3efaa61a5a |
| ci-n1 | 9879c2f | 4325376 | 8ee7891be6baf6196ecd3ebc6dbe65a4ab99e04bb8368d676ae92df004eac7dd |
| c08 plain, #37 | 2bebfe7 | 4259840 | b7b5ca683b6c497c9116868507701bbef08a1d4fabbda48cb3c09956ecaa3c1c |
| ci-gpu | 2bebfe7 | 4325376 | e8aed3d0ecee38477998989b43b59501b36a69e187b4bfd4ee5fa6791aa1cad1 |
| tip-display plain, #35 | 5818f6b | 4259840 | 6646514e118cd7ce2288997c5a4ca5b7d676eb54b5ce2825d55a2dcf51f2cb8c |
| ci-display | 5818f6b | 4325376 | 907abc8dd115643a5a025d0486395070e097c436608cc13ce483c287530b3fd3 |
| c13 plain, #36 | 64c8ce2 | 4259840 | 8fb60c21cfb9a74ca9032e872fadb98e59ba46a61118d0a6664db89c84eee71d |
| ci-wdt | 64c8ce2 | 4325376 | b07c5409646c01dedf3eb4e63a14a58158f75bb62561c5c57fde02d67bee10f1 |
| c14 plain, stack-r2-test (#36 + phandle fix) | 194eac0 | 4259840 | dee9bc6f4557f91ee1fe412b684a641f32e2f8e87c2b34dfcde4af134f056e7a |
| ci-stack | 194eac0 | 4325376 | 919db33205e7267a710ff08aeca5284b0087e0830aa323236009a59a3f9dc11b |

## Push (Rolando runs these; from ~/Work/agents/aurora-prs-2/m1n1, push in this order)

    git push --force-with-lease=refs/heads/omacom-t6050-bringup:275ecc4205add99cc5f26860896cf1b43df96156 https://github.com/rolotrealanis98/m1n1 omacom-t6050-bringup-r2:refs/heads/omacom-t6050-bringup
    git push --force-with-lease=refs/heads/omacom-t6050-n1:f1a942e393d11eadb154988a4a3bd961184fe5e0 https://github.com/rolotrealanis98/m1n1 omacom-t6050-n1-r2:refs/heads/omacom-t6050-n1
    git push --force-with-lease=refs/heads/omacom-t6050-gpu:4e461025b9ecd25b571ed66d87acdd5680bf6b21 https://github.com/rolotrealanis98/m1n1 omacom-t6050-gpu-r2:refs/heads/omacom-t6050-gpu
    git push --force-with-lease=refs/heads/omacom-t6050-display:ffee10193201daf884c0f3ff3639e33924d805de https://github.com/rolotrealanis98/m1n1 omacom-t6050-display-r2:refs/heads/omacom-t6050-display
    git push --force-with-lease=refs/heads/omacom-wdt-keep:02785a35e046901d5686ab9059b2c08b6256752a https://github.com/rolotrealanis98/m1n1 omacom-wdt-keep-r2:refs/heads/omacom-wdt-keep

(omacom-wdt-keep-standalone f723230 is on integration/aurora, not on #30: not touched.)

PR comment drafts (one sentence each):
- #33: Rebased onto #30's new head 140a36b (no conflicts); the test-fix commit now also declares the new `retained_heap_end` and `staged_*` statics so test_smp_handoff_gate and test_chainload_run_base build again.
- #34: Rebased onto #30's head 140a36b with no change; the SMC and ANS sessions the N1 training starts are now inside the heap range #30 reserves just before the jump.
- #37: Rebased onto #30's head 140a36b with no change; the GPU hand-off allocates no heap, so #30's late-heap retention does not touch it.
- #35: Rebased onto #30's head 140a36b with no change; the hand-off never initialises a DART, and its transient DT copies are merely swept into #30's late-heap reservation.
- #36: Rebased onto #30's head 140a36b with no change; if #30's late-heap reservation fails, m1n1 returns to the proxy with the watchdog still armed, so the machine resets into the earlier stage's fallback.

## Boot test

Loop-boot payload (the #36 tip, 64c8ce2, m1n1 = build/r2/c13.bin, same daily kernel/DTB/initramfs/chosen n1=4 as
the 15618a15 payload; self-test on, battery on, mode 0600):
`~/Work/agents/omacom-m1n1/payloads/r2/omacom-wdt-keep-r2-20261108-e52ca584.bin`
sha256 e52ca584172fd5914657c40b557a199e8db924a36851cfdc4bbdf18a2fad2135 (payloads/r2/SHA256SUMS). Loop script (not run):
`~/Work/agents/omacom-m1n1/loop/run-wdt-keep-v30r2.sh` (copy of run-wdt-keep-v30fix.sh with the new payload and hash, without the
wait on the dcp120 log; the stage-2 log grep also shows `late heap` / `retained heap`). Payload generator:
payloads/r2/mk-omacom-r2.py. The phandle fix is inert in this payload (display hand-off is opt-in and the payload does not set
it); to test it with the display opt-in use build/r2/c14.bin (194eac0, no payload built).
Expected panel: as for 15618a15 plus `FDT: retained heap [...)` at prepare and `FDT: late heap [...) retained` before the jump.
