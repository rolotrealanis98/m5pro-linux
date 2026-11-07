# Aurora submissions, batch 2 (J716s), 2026-11-07

Nothing pushed or posted by the agent. The coordinator opened aurora-silicon/linux #1152 (WFI) and aurora-silicon/m1n1 #65
(N1) at 14:43 UTC from the branches below.

## Branches
| Item | Branch | Tip | Base | State |
|---|---|---|---|---|
| 1 WFI idle | `pr/t6050-wfi-idle` (linux) | `72f8eecf708b` | integration/aurora `4114f761f469` | **opened #1152** |
| 3 m1n1 N1 | `pr/t6050-n1-handoff` (`~/Work/agents/aurora-prs-2/m1n1`) | v1 `4e76442c71c8` (pushed, #65); **v2 local `4d50f1f`** | aurora-silicon/m1n1 `aurora-wip` `b6b4592` | **opened #65**; v2 ready, boot-test payload built, not pushed |
| 2 ASPM | `pr/pcie-apple-adopted-port-aspm` (linux) | `acfb8489d607` | PR #937 head `a873be047e9a` | **hold: needs a boot** |
| lid | `pr/macsmc-input-lid-confirm` (linux) | `238be1b80437` | integration/aurora `4114f761f469` | hold (Rolando's call) |
Patches: `patches/<topic>/`. PR bodies: `PR-<topic>.md` (line 1 title). Held bodies start with a "[Note for Rolando,
delete before sending]" block. Trailers on every new commit: `Signed-off-by: Rolando Trevino <rolotrealanis@gmail.com>`
+ `Assisted-by: LLM Claude`, author/committer Rolando; no disclosure sentence in bodies or the comment.

## 1. WFI idle (#1152)
- Nothing new upstream in `arch/arm64/kernel/idle.c` since 5c9cbb25dba8 (T8142); no competing PR. Applies clean.
- Commit message now carries the J716s numbers (16.4 W -> 9.8 W, 56 min soak, FP check on 18 CPUs, s2idle S1-S4).
- Finding: Aurora's m1n1 (`aurora-wip` kboot.c:481) and aura (kboot.c:882) already skip the `idle=nop arm64.nowfxt` append for
  T8140/T8132/T6040/T6041 (aura gives T8152 only `arm64.nowfxt`). The PR asks whether they prefer T6050 added there.
- Checks: checkpatch --strict clean; built in the separate detached worktree `/Volumes/linux-cs/wt-prs2` at `72f8eecf708b`
  (created after the 09:37 branch switch in wt-prs, which only hit the build I had already stopped), so the result stands:
  `arch/arm64/kernel/idle.o` builds with W=1 (LLVM, arm64, defconfig + asahi.config) with 0 warnings (`build-idle.log`).

## 3. m1n1 N1 hand-off (#65)
- Base `aurora-wip`, not `main`: `main` is an ancestor 353 commits behind; every recent PR (#57-#64) targets aurora-wip.
- Four commits: 0022 DT fill-in; 0023 training (with 0026's `adt_getprop_copy()` length fix folded in, so no buggy
  intermediate); 0025 ANS start; 0026 SMC `gP13` pulse. `chosen.m5pro,n1` renamed `chosen.asahi,t6050-n1` (Aurora's
  `asahi,<chip|board>-<feature>` pattern: `asahi,t6030-gpu`, `asahi,j713-dcpext`). Modes unchanged; 4 is the working one.
- Dropped: 0017 (aurora has its own `asahi,show-notch`), 0018 HPM, 0019 dart-pmp0, 0020 pipe park, 0021 ATC tunables (USB/GPU
  topics; aurora has no T6050 equivalent of 0020/0021, but the N1 code does not need them), our 0010-0016 boot-chain patches,
  and 0026's 0x400000 size-driven message shortening. Not re-added because aurora-wip has them: `tunables_validate_local()`,
  `pmgr_power_is_on()`.
- Adapted: `pmgr_psreg_by_name()` skips virtual devices; `rtkit_set_boot_timeout()` (default 1 s). On aurora-wip
  `nvme_shutdown()` leaves an M4-class ANS running; 0025's check now accepts that (only a failed shutdown counts as storage
  lost), so with modes 3/4 Linux gets a running ANS (v1 only; v2 below stops ANS fully instead).
- Build (`m1n1-build/build.sh`, Apple container, Fedora 43, clang/lld 21.1.8, rustc 1.99.1): base and each commit build,
  15 warnings = base, none new; clang-format clean; v1 tip sha256 `750ef747...`. `CHAINLOADING=1` fails the file-size assert on
  the base already; the plain image's file part grows 0x110000 -> 0x120000, exactly the limit.
- Context: aurora-silicon/m1n1 has no other T6050 support (CPU IDs, SMP only), so this tree has never booted a J716s; all
  W0-W3b evidence is from our pipepark-atc lineage. Aurora's J813 N1 code is in **aura** (`src/j813_n1.c`,
  `j813_n1_prepare()`, gated by `chip_id == T8142` + an okay ECAM node, no opt-in), not m1n1. The PR asks whether it should
  move to aura and whether to gate by chip/board.
- #65's posted body predates the restart result (DAILY-WIFI promotion: a restart with the N1 link alive does not come back);
  the local v2 file has it. Refresh it with the v2 force-push (`PUSH-PLAN.sh` section 3b, commented).

### #65 v2 (review findings), local only
- Commits: `a8b4519` kboot: n1 DT fill-in; `9823d48` train port 0; `06e6c66` ANS start; `4d50f1f` SMC gP13 pulse (tip).
  v1 kept as tag `v1/t6050-n1-handoff`. Tree of `4d50f1f` == `c7d851e` (the build-tested/payload tree; the only difference
  is the trailer, so the payload's m1n1 reports `...-gc7d851e`).
- 1 (P1, ANS buffers): on aurora-wip `nvme_shutdown()` does leave the T6050 ANS running with live RTKit/SART buffers. Chose a
  full stop, not a reservation: new `nvme_stop()` (src/nvme.c:800) runs the M1-M3 teardown when m1n1 itself started ANS;
  `ans_stop()` (pcie_t6050.c:708) requires the ANS CPU to read stopped, else watchdog reset. That is what the hardware runs
  did ("ANS stopped again for Linux"); Linux restarts a stopped ANS (W1/W2).
- 2 (P1, storage): a failed post-stage `storage_check()` returns `N1_STORAGE_LOST` (-2), passed through `TRY()`;
  `kboot_setup_n1()` (kboot_n1.c:281) sends it to the watchdog reset whoever started ANS.
- 3 (P1, mode 5): removed; `stage_e()` takes the link wait (1 s after the pulse, 500 ms otherwise); mode 4 is register for
  register the W2c/W3b path.
- 4 (P2, adoption): a stopped port-0 training keeps port 0 + DART disabled even with the link up (kboot_n1.c:273/284/322);
  `n1_port_up()` now also requires no valid RID2SID entry, endpoint command bits clear, DART 0x200/0x208/0xc00 at 0.
- Build: base, each commit and tip 15 warnings = base (the `new-warnings.txt` c2 line is the base's kboot.c stack warning
  with interleaved output); clang-format clean; tip image `e44f479b...` 0x420000 bytes.
- Reply text: `REPLY-m1n1-65.md`; PR body `PR-m1n1-t6050-n1.md` updated (modes 1-4, restart caveat).
- **Boot-test payload (not deployed):** `payloads/m1n1-65v2-n1-20261107-22f89156.bin`, sha256
  `22f891562f218bf87765f09f8fcd025c4f31a75ec94cfc5691ddd39e2a1b2e8b` (0600, carries the board FTAB). Built by
  `payloads/mk-v2.py` (mk-daily.py unchanged as a module; overrides: `M1N1_SIZE=0x420000` because aurora-wip's plain image
  is 0x420000 and reads its variables there, and `chosen.asahi,t6050-n1=4` appended after the show-notch line). Everything
  after the variables is byte-identical to W3b (kernel 975dab00, stack DTB 594f2a9f, stitched-FTAB initramfs cffbbaf1,
  `pcie_aspm=off`, battery, `m5.selftest=1`). Run from a full power-off.
  - Risk: aurora-wip m1n1 has never booted the J716s and lacks our T6050 boot patches (0010-0016, HPM, pipe park, ATC
    tunables, RVBAR trampoline): stage-2 may not start, or USB/Ethernet/SMP may fail; the stage-1 watchdog (150 s) or the
    self-test (90 s) falls back to prev.
  - Pass: stage-2 log (phram mtd0) with `SMC key gP13`, `port 0 link Gen1 x1`, `endpoint 01:00.0 is 0x1900106b`,
    `nvme: shutdown done`, `ANS stopped again for Linux`, `n1: port 0 up: root port and DART okay`; kernel `adopted port 0`,
    `[106b:1902]`/`[1903]`, wlan0, hci0, NVMe root mounted.
- Trailer: the v2 agent had dropped `Assisted-by: LLM Claude` citing the memory rule (exception = aurora-silicon/linux only).
  I re-added it, as the brief and the coordinator ask for Aurora-bound branches and v1 on #65 already carries it.
  **Rolando to confirm** for aurora-silicon/m1n1 (memory `no-ai-trailers` lists only aurora-silicon/linux). To drop it: `git -C ~/Work/agents/aurora-prs-2/m1n1 branch -f pr/t6050-n1-handoff c7d851e` (identical tree, no trailer).

## 2. ASPM (hold: needs a J716s boot without `pcie_aspm=off`)
- The adoption code is not in integration/aurora: it is PR #937 (`adopt_link`), so the branch is stacked on #937's head;
  #937 itself no longer merges cleanly into `4114f761f469` (conflicts in pcie-apple.c and the binding).
- Fix: the existing tunnel bus notifier (Aurora's "strip L1 on tunnel hosts", `pcie_aspm_remove_cap()` at
  BUS_NOTIFY_ADD_DEVICE of the root port, before the bus behind it is scanned) is registered for `adopt_link` hosts too and
  strips L0s and L1 there, without the tunnel path's runtime-PM reference. Same approach as edimoldovan's ab24d156868e
  (J714c), without his shutdown park (separate topic). With neither state supported, `pcie_aspm_cap_init()` returns
  early and leaves the link alone, which is what `pcie_aspm=off` does globally.
- Per host rather than per endpoint (106b:1900): the root port is added before the endpoint exists; an endpoint check
  would need a FINAL fixup + `pci_disable_link_state()` after the ASPM core has configured the link once. Asked in the PR.
- For Rolando's test: `git format-patch -1 pr/pcie-apple-adopted-port-aspm` applies to `j716s-series` `a83b052e9ffb`
  (offset 53). Pass criteria are in the note block of `PR-pcie-apple-adopted-port-aspm.md`.
- Checks: checkpatch --strict clean; `drivers/pci/controller/pcie-apple.o` builds with W=1, 0 warnings (`build-aspm.log`), with CONFIG_RUST off: on #937's 615-commit-old base the generated Rust bindings fail a layout assert with this toolchain (sched_statistics alignment), unrelated to the patch.

## Lid-open confirm (hold)
- Applies unchanged on the tip (macsmc-input.c identical to the patch base). Commit message adds the hardware run.
- Correction to the coordinator's summary: the only patched lid run had **no** spurious event ("No spurious early event
  appeared in this run" in RESULTS.md), so the hold-back path has not run on hardware; the body says so. It asks whether
  Aurora knows an SMC sleep-notify key.
- Checks: checkpatch --strict clean; `drivers/input/misc/macsmc-input.o` builds with W=1, 0 warnings (`build-lid.log`).

## 4. COMMENT-293.md
15 lines (long bullets): WFI, sleep + lid, sensors + right port, speakers (J616s TDM format), Wi-Fi/BT recipe with repo paths
(all checked to exist in rolotrealanis98/m5pro-linux), the ASPM and restart caveats, two questions for edimoldovan. No
disclosure line. Not posted.

## Could not do / caveats
- `/Volumes/linux-cs/wt-prs` was switched between branches by someone else during the run (pr/rtkit-handshake-10s with
  uncommitted rtkit/nvme edits). I stopped my build there and used a new detached worktree `/Volumes/linux-cs/wt-prs2`
  (out dir `wt-prs2-out`); the ASPM and lid branches were created without a checkout (temporary index + commit-tree).
  `wt-prs2` (a full checkout, now detached at the ASPM commit) and `wt-prs2-out` (222 MB, CONFIG_RUST off) can go:
  `git -C /Volumes/linux-cs/linux worktree remove --force /Volumes/linux-cs/wt-prs2 && rm -rf /Volumes/linux-cs/wt-prs2-out`.
  The volume is at 91 % (7.3 GiB free).
- No hardware run of anything in this batch; the m1n1 rebase and the ASPM patch are build-tested only.
- `dtbs_check`/binding checks not relevant here (no DT changes).
