# Aurora PRs from the J716s series (2026-11-07)

(Saved by the coordinator from the agent's hand-back.) Nothing pushed by the agent; the coordinator pushed the three
"send now" branches to `rolotrealanis98/linux` (remote `fork`) at 10:20 UTC.

## Base
- Remote `aurora` added; `integration/aurora` is `7aee01a89865` (#1079 merge), 139 commits past `33bec4016c46`.
- Every branch is based on `7aee01a89865`; every cherry-pick clean. Read-only refs `refs/remotes/aurora-pr/<n>`: PR heads
  #935-#939, #941, #942, #945, #946, #481, #490, #491, plus `j716c/t6050-platform`.
- Worktree `/Volumes/linux-cs/wt-prs`; build output `/Volumes/linux-cs/wt-prs-out` (defconfig + asahi.config).

## Branches
| Branch | Tip | Content | Send? |
|---|---|---|---|
| `pr/rtkit-handshake-10s` | `f285da2ec9a1` | 0045 | now |
| `pr/dockchannel-afe-settle` | `8af6aa6ce9e4` | 0046 | now |
| `pr/macsmc-hwmon-optional-fan-keys` | `c129a7eb5888` | 0047 | now; HWMON-T1 exercised, missing-key path not triggered |
| `pr/t6050-cio-reset` | `f3ec03961558` | 0051 | hold; drop in favour of #946 |
| `pr/t6050-cpufreq-binding` | `6cd5b96c65ac` | 0053 | hold; discuss on #481 |
| `pr/t6050-smc-match` | `bec2a2090242` | 0052 | only if #941 is far off |
| `pr/j716s-board` | `7a0a707294a2` | carried 0001-0012 + 0054-0058 | hold |

`pr/j716s-board` sits on PR #945's head `301c0e3ca376` unchanged; #945 is stacked on #935 (`j716c/t6050-dt`), so carried
0001-0009 are PR #935 (Jeff Queisser) and 0010-0012 PR #945 (Erik Bourget); SERIES.md labels all twelve as #945. Patch-ids
match except 0008 (the qspi conflict fix). Smallest set giving the same DTB (`8c4df67a`): 0001, 0002, 0004, 0009, 0010; all
12 kept (bindings for dtbs_check, 0011 runtime, 0012 = #945 exactly).

## Trailers
`Assisted-by: LLM` and `Co-Authored-By: Claude` removed from Rolando's commits on all `pr/*` (filter-branch, trees
unchanged); author and `Signed-off-by` kept; no disclosure sentence in the bodies. Pre-strip state kept as
`disclosed/<topic>`. Flag: the tree's `Documentation/process/submitting-patches.rst` ("Using Assisted-by") and
`coding-assistants.rst` ask for `Assisted-by: LLM [TOOL]`; 26 of the last 60 `integration/aurora` commits carry it.
Carried Aurora commits keep their own authors' lines.

## Check results
- Single objects (`W=1`, LLVM arm64) pass with 0 warnings: `reset-apple-cio.o` (0051), `rtkit.o` (0045),
  `dockchannel-hid.o` (0046), `macsmc-hwmon.o` (0047), `macsmc.o` (0052).
- `make dtbs` on `pr/j716s-board`: pass, 1912 DTBs, no warnings; `t6050-j716s.dtb` `8c4df67a` byte-identical to the one
  booted in R3-SERIES/R3-S. `make W=1 apple/t6050-j716s.dtb`: one warning from our 0055, `gpio@67700000` has a unit name
  but no reg (same pattern as t6031).
- `dtbs_check`: NOT run (`dt-validate` missing; `pip install --user dtschema` refused by PEP 668; not worked around). Binding
  YAML unchecked (no PyYAML).
- `checkpatch --strict`: clean 0045, 0046, 0047, 0053, 0054, 0055, 0056. 0051/0052: "DT binding docs and includes should be
  a separate patch" (+ undocumented-compatible noise from checking without the binding). 0057: MAINTAINERS note;
  undocumented `apple,t6050-fpwm`, `apple,t6050-spmi`, `apple,t6050-pmgr-pwrstate`, `apple,t6050-cluster-cpufreq`.
  0058: MAINTAINERS note. spdxcheck skipped (no python `ply`).
- Style fix: 7 comment lines in 0057 over 100 columns wrapped and squashed (DTB unchanged). The repo's `series/patches/0057`
  does not have the wrap; the updated patch is `patches/j716s-board/0016-*.patch`.

## Findings that change the plan
- #946 (`j716c/thunderbolt`, `35c0d1d6bc96`) already adds `apple,t6050-cio-reset` at +0x60 with a hardware-checked
  sequence (odd bit = done; waits for request and done to clear; "an access before that takes an SError"). Our 0051 treats
  the bit as busy and can return early. Do not send 0051; comment on #946 instead.
- #941 (`j716c/t6050-smc`) adds the same `apple,t6050-smc` binding and match: 0052 redundant unless #941 stalls.
- #481 (`t6050/cpufreq`) conflicts with 0053 and the board's fallback nodes (single `const`, requires
  `apple,firmware-managed-thermal`).
- No conflicts: 0045 on #942, 0046 on #491, 0047 on #941.

## Must fix before sending the board PR
Binding for `apple,t6050-fpwm` (first user); settle the cpufreq route (#481 or 0053); run `dtbs_check`; decide the
`gpio@67700000` W=1 warning; runtime dependencies are now #946 and #941. If 0051/0052 are ever sent: refresh their stale
"not built/run" text (both now build and boot: R3-SERIES) and split binding from driver. Held PR bodies start with a
"[Note for Rolando, delete before sending]" block.

## Not prepared
0048 (edimoldovan carries it; R3-S confirms the hang is gone), 0049 (Dj's), 0050 (edimoldovan `9dee12b1266c`; needs a
Tested-by arrangement and an `apple,internal-panel` binding).

## Recommendation
Send now: rtkit-handshake-10s, dockchannel-afe-settle, macsmc-hwmon-optional-fan-keys (active lines in `PUSH-PLAN.sh`).
Hold: cio-reset (#946 replaces it), cpufreq-binding (ask on #481), smc-match (#941 covers it), j716s-board (fixes above).

## Sent (2026-11-07 10:25 UTC, from rolotrealanis98/linux, with `Assisted-by: LLM Claude` per Aurora's process docs)
- #1082 soc: apple: rtkit: wait up to 10 s for a handshake reply (`pr/rtkit-handshake-10s` 6d43a3ec72fa)
- #1083 HID: dockchannel-hid: settle 50 ms after releasing the AFE reset (`pr/dockchannel-afe-settle` 227703b63d84)
- #1084 hwmon: (macsmc) keep a fan whose optional keys are missing (`pr/macsmc-hwmon-optional-fan-keys` 8125f1376ef0)
Held: cio-reset (#946), cpufreq-binding (#481), smc-match (#941), j716s-board (fixes listed above).

## Sent, batch 2 (2026-11-07 14:45 UTC)
- aurora-silicon/linux #1152 "arm64: idle: T6050 idles in WFI even with idle=nop" (`pr/t6050-wfi-idle` 72f8eecf708b on integration/aurora 4114f761f469; validated as our daily, soak + S1-S4).
- aurora-silicon/m1n1 #65 "kboot: train the T6050 N1 link and fill its hand-off (J716s Wi-Fi/Bluetooth)" (`pr/t6050-n1-handoff` 4e76442c71c8 on aurora-wip b6b4592; 4 commits: N1 DT fill-in, opt-in training behind `chosen.asahi,t6050-n1`, ANS started for the storage checks, SMC reset pulse; build-tested on aurora-wip, hardware-tested on our lineage: W2c/W3b).
Pre-reviews on #1082-#1084 (merge-train bot, 14:33 UTC): per-device RTKit timeout, dev_dbg for the AFE lines, dev_info for the missing fan keys; v2 branches in preparation.

## 2026-11-07 15:40 UTC: v2 pushes and the lid PR
- #1082 v2 0630fabf19e9 (per-device RTKit handshake timeout, 10 s only for `apple,t6050-nvme-ans2`), #1083 v2 00768a757b56
  (dev_dbg), #1084 v2 5de41949c174 (one dev_info per fan): force-with-lease pushed to the fork, replies posted
  (`~/Work/agents/aurora-prs/REPLY-*.md`, copies in `patches-v2/`).
- aurora-silicon/linux #1160 "Input: macsmc-input - confirm a lid-open report during system sleep"
  (`pr/macsmc-input-lid-confirm` 238be1b80437 on integration/aurora 4114f761f469). Validated by the LID sleep pass;
  the hold-back path (a spurious report ignored) has not fired on hardware yet and the PR says so.
- aurora-silicon/m1n1 #65 v2 4d50f1f pushed with a lease on v1 4e76442c71c8 (v1 kept as tag `v1/t6050-n1-handoff`):
  ANS fully stopped via `nvme_stop()`, storage loss after training starts ends in the watchdog reset, mode 5 removed,
  port 0 and its DART stay disabled unless adoption fully validates. Boot test of the rebased tree pending
  (payload `m1n1-65v2-n1-20261107-22f89156.bin`, needs a full power-off start).

## 2026-11-07 17:10 UTC
- omacom/linux-aurora #293: J716s status update posted (comment 6710416717): WFI idle, sleep, sensors/right port,
  speakers, Wi-Fi/Bluetooth recipe, the restart caveat (since solved by W4), two questions for edimoldovan.
- aurora-silicon/m1n1 #65: hardware result of the exact aurora-wip tree posted (comment 6710105778); T6050 bring-up
  series for aurora-wip in preparation (agent).
- GPU/DCP 27.2+ port started as six parallel agents (InitData root/sizes/HW data; power policy; status config;
  firmware identity + J716s board profile; runtime format diff; DCP 27.3 table), integrator to follow.

## 2026-11-07 17:30 UTC
- aurora-silicon/linux #1167 "arm64: dts: apple: add the J716s (MacBook Pro 16-inch, M5 Pro)" opened: `pr/j716s-board-v2`
  674542cf2e22 (10 patches on #945 carried), validated by BOARDV2-T2 (the PR DTB + a local ATC0 gadget node boots the
  series kernel: input, NVMe, N1, battery, sensors).
- m1n1 T6050 bring-up series for aurora-wip ready (`pr/t6050-bringup`, 4 commits: i2c limit 16, per-cpu-id CPU_START bit,
  RVBAR relay for cores locked to the stage-1 base, T6040-style split BAR), payload
  `m1n1-t6050-bringup-20261107-020e7150` built; boot test must be ATTENDED (this loader disables the stage-1 watchdog, so
  a hang parks the machine in the proxy; macOS recovery plan as for #65 v2). PR after the boot.
- ASPM PR branch dropped as redundant (0085 validated by NOASPMFLAG-T1).

## 2026-11-07 21:10 UTC
- aurora-silicon/linux #1173 "drm/asahi: M5: InitData for the macOS 27.2 and 27.3 firmware (G17S bring-up on J716s)"
  opened: `pr/m5-gpu-27.2` 34f2f5bb4d03, 13 commits stacked on #1012 (base `funkzy/t6050-gpu-on-integration`
  b1615e3fca90). Hardware: E2b on the J716s (firmware 27.3 26C5035r identified, both InitData acknowledged, opening
  records retired, aurora DRM device registered). Checks (A/B/C/D scripts, host tests) pass on the head; patches and
  check scripts under prs/gpu-27.2/. Announcement comment posted on #1012.

## 2026-11-07 (m1n1 GPU hand-off PR prepared)
- aurora-silicon/m1n1 `pr/t6050-gpu-handoff` 686e792 (1 commit, `src/kboot_gpu.c` only) stacked on `pr/t6050-bringup`
  d8a0458; does not need #65 (cherry-picks cleanly onto it, builds). Reshaped from lineage 0028 to aurora-wip's
  T6040 fill: no chosen.* opt-in (runs when the DT enables `&gpu`), `/reserved-memory/uat-*` + `gpu-fw-text/-data`
  via `dt_set_resvmem()`, mailbox windows from the ADT (enabled with the GPU), no PMGR check, disable path as T6040.
  Build: 15 warnings = base, none new, clang-format clean, plain image stays 0x410000 (with #65: 0x420000); base,
  bring-up and lineage n1-warm rebuild byte-identical. Host test vs the J716s ADT passes (fill, control, 4 negatives).
  Boot-test payload `m1n1-t6050-gpu-20261107-30a40882` (E2 kernel, E2 DTB + `&gpu`/`&pmgr_gfx` okay, Wi-Fi daily
  initramfs, selftest, battery): ATTENDED boot (no stage-1 watchdog). PR text and copies under prs/m1n1-gpu/. Not
  pushed, PR not opened.

## 2026-11-07 22:30 UTC
- aurora-silicon/linux #1174 "drm/apple: firmware 27.3 IOMFB method table and swap layout" opened: `pr/t6050-dcp-27.3`
  716bce007fd3 (Jeff Queisser's #894 table-selection commit with authorship kept + ours) on #1012's branch
  `funkzy/t6050-gpu-on-integration` (aurora-silicon/linux-aurora is not reachable, so option (b)). Hardware lines filled
  with stages A/B0/B; stage C pending (attended; bw-scratch measured, payload `dcpc-20261107-9ec63d9a` built).
- m1n1 display series `pr/t6050-display` (e0640ca: V27_2/V27_3B1 strings, T6050 __OS_LOG reservations, opt-in display
  hand-off behind chosen.m5,t6050-display=1, compat 27.3.0) stacked on bring-up + #65, builds with 0 new warnings;
  opens after the attended Aurora-loader sitting.

## 2026-11-07 22:00-23:00 UTC: Omarchy (omacom) PRs

- Forks created under rolotrealanis98 with Rolando's permission: linux-aurora, omarchy-mac-pkgs (m1n1 fork pre-existed).
- omacom/omarchy-mac-pkgs #103 "Cover the 16-inch M5 Pro (J716s) in the audio tests and the manual": opened.
- omacom/linux-aurora: branch `j716s` (12 commits on #404) pushed to the fork; PR creation refused with "branch not
  found" while GitHub populates the new fork; a poller opens it once the branch is visible.
- omacom/m1n1, stacked on edimoldovan's #30 (which superseded #26): #33 T6050 bring-up (RVBAR relay + CI test fixes),
  #34 optional N1 training and hand-off (on #33), #37 GPU hand-off for apple,agx-g17s (on #34), #35 internal display
  hand-off for the firmware-27 DCP driver (on #37), #36 `m1n1.wdt=keep`. The #26-based form of this stack booted the
  J716s first pass (OMACOM-WDT-KEEP); the #30 rebase itself has not booted yet (payload
  `omacom-wdt-keep-20261107-3713d26f` queued, unattended OK).

## 2026-11-08 ~01:00 UTC: kernel-side N1 training PRs (aurora-silicon/linux)

- Driver half: https://github.com/aurora-silicon/linux/pull/1182 — base `j716c/t6050-pcie` (#937's branch): ed's ASPM strip + shutdown park, our binding commit,
  ed's cold train, host tunables, DART binding, DART availability (2 commits), our warm-N1 reset and gP13 template.
  Ed's six commits carry no Signed-off-by of his own (asked in the PR text).
- DT half: https://github.com/aurora-silicon/linux/pull/1183 — base integration/aurora, stacked on #1167: ed's DART binding + the J716s DT.
- Hardware section from K1/K2 (2026-11-07 21:27 UTC). Copies in `contrib/pending/wireless/pr-kernel-train/`.

## 2026-11-08 05:10 UTC: #293 replies posted (Rolando's go)

- Reply 2 to edimoldovan: J616s format stays J716s-only; W4 ab24d156868e confirmed on the J716s (3 warm restarts, ASPM
  strip replaces pcie_aspm=off); the adopted-link s2idle fix; the GPU result (27.2+ InitData port boots the G17S, #1173).
- Reply 3 to TripleU613 (J714s effort, github.com/TripleU613/Omarchy-M5-Pro): pointer to m5pro-linux as the status repo
  and the six solved pieces that carry over (SMP/relay, N1 kernel training #1182/#1183, GPU #1173, DCP 27.3, AFE reset
  #1083 + pcIO table, SMC/hwmon/lid/WFI), plus the 60 s reboot rule.
- rolotrealanis98/linux-aurora fork: broken on GitHub's side (API never indexed pushes); Rolando approved deleting and
  re-forking; the token lacks the delete_repo scope, so the delete happens in the web UI, after which the fork, push and
  PR creation run automatically.

## 2026-11-08 02:20 UTC: omacom/linux-aurora J716s PR opened

- https://github.com/omacom/linux-aurora/pull/413 "Add the 16-inch MacBook Pro with the M5 Pro (J716s)" (12 commits on edimoldovan's #404, from the re-created fork rolotrealanis98/linux-aurora, branch j716s). The first fork never indexed pushes; the new one needed pushes by explicit URL because the old remote-tracking refs made git skip the push.
- 2026-11-08 03:05 UTC: #293 reply 4 posted (Rolando's go, as a correction): 27.3 looked required only because the
  multi-core blocker was fixed on the 27.3 side; the kernel/loader work is firmware-version keyed (27.2 and 27.3 share
  the layouts except one word); the Omarchy repos are the shared place; a cross-machine tracker/wiki proposal is being
  drafted (`contrib/community/SHARED-REPO-PLAN.md`, agent).

## 2026-11-08 03:30 UTC: aurora-silicon/mesa #194 opened

- https://github.com/aurora-silicon/mesa/pull/194 "asahi: native Gallium GL on the M5 Pro and M5 Max (G17S, G17C)":
  five commits on agx3c a8e86a80cdc (drm-shim M5 gate, M5 path for G17S/G17C, program storage lists, tile kept under
  fully masked draws, GBM map waits for writers), from the new fork rolotrealanis98/mesa (Rolando's consent), branch
  g17s-gallium-native = the exact tree running as the MacBook's desktop GL (MESA_COMMIT 043a4c58). Hardware section:
  A/B 12/12 on both trees, Hyprland on the native driver, glmark2 1278 vs zink 597-890; asahi suite 108/110 (two
  pre-existing G17P blit failures).

## 2026-11-08 02:40 UTC: shared-tracker proposal posted on omacom/linux-aurora #293

- Comment: https://github.com/omacom/linux-aurora/issues/293#issuecomment-6716271037 (the follow-up to Rolando's
  earlier "get something up early tomorrow"). Proposes one tracker repo (status matrix, result logs, build recipes
  with hashes, topic notes; code stays upstream), asks for a name (`m4plus-linux` suggested) and a home (new neutral
  org, or omacom), with a one-day default. Full plan: `contrib/community/SHARED-REPO-PLAN.md`.
- Nothing has been created on GitHub yet (no org, repo or invitations). Next: after the day passes without objection,
  create the org and seed the J716s entry; the AI policy and the licence question for the J714s repos are decided
  before the repo opens.
- 2026-11-08 03:20 UTC: TripleU613 answered (name **M4Plus-Linux**, new repo under omacom, needs dhh/team
  confirmation, active developers onto the M team). Reply posted:
  https://github.com/omacom/linux-aurora/issues/293#issuecomment-6716546581 (agree on both; content staged under
  rolotrealanis98 and transferred to `omacom/m4plus-linux` when omacom confirms; neutral org as the fallback; J716s
  seeded and J714s/J714c drafts for their owners this weekend).

## 2026-11-08 04:50 UTC: omacom/m1n1 #35 updated with the phandle fix

- Pushed `ffee101` "kboot: t6050: give the display nodes a phandle if the DT has none" to the PR branch (22 commits
  now) and explained it in https://github.com/omacom/m1n1/pull/35#issuecomment-6717322207. The in-tree J716s DTB has no
  phandle on `dcp` and `display-subsystem` (dtc emits one only for referenced nodes); #35 logged "no handoff" and booted
  without the display, our stage-2 variant bailed into the proxy and the stage-1 watchdog reset the machine (nine
  bisect boots, `contrib/pending/dcp/daily-dcp/FIRST-BOOT-ANALYSIS.md`). Hardware: the same fix in our loader
  (`n1-dt-gpu-dcp-phfix`) booted the in-tree DTB with the DCP driving the panel next to the GPU (`daily-dcp-lfix-test`).

## 2026-11-08 04:43 UTC: aurora-silicon/linux #1082, #1083, #1084 MERGED

RyanTheTide merged the three driver PRs after a fleet test (one-shot kernel = integration/aurora 36d91984 + #1082,
#1083, #1084, #1060 and the Touch ID series; booted on J413, J316s, J616s and J700; regression suite against the
fleet30 rows: no regression; for #1082 every fleet Mac kept the 1000 ms default, only `apple,t6050-nvme-ans2` gets
10 s, zero RTKit timeout lines). Merged: `soc: apple: rtkit: wait up to 10 s for a handshake reply`,
`HID: dockchannel-hid: settle 50 ms after releasing the AFE reset`, `hwmon: (macsmc) keep a fan whose optional keys
are missing`. Still open: #1152 (WFI idle), #1160 (lid confirm), #1167 (J716s DT), #1173 (M5 InitData), #1174
(27.3 IOMFB), #1182/#1183 (kernel-side N1 training), mesa #194, m1n1 #65.

## 2026-11-08 05:56 UTC: aurora-silicon/linux #1167 (the J716s board DT) accepted, merges once CI is green

RyanTheTide: the T6050 trees are in scope; he checked the J716s file against the J716s ADT (register windows and
interrupts of PCIe port 0, the HPM buses, FPWM0 match), the CPU order (the J775D ADT lists cores the same way), and
`make W=1` / `CHECK_DTBS=y` on J716s, J716c, J775D after the merge: no warnings. He pushed on top of our commits: a
merge of current integration (#935 and #945 with their review fixups; our carried copies kept the CPU order and the
gpio-low bank, the reviewed versions of the other T6050 files were taken), dropped `arch/arm64/configs/j716s.config`
(the tree builds every Mac from defconfig + asahi.config; options the J716s needs go to asahi.config in a PR; built-in
boot path is a distro choice) and dropped the default `bootargs = "maxcpus=1"`. On our questions: carrying #945 was
fine; the cpufreq override with the T8112 fallback stays until #481 lands; a panel node for the boot framebuffer and
the trackpad reset route can be follow-ups. "Build-tested here, and you've booted it on the J716s, so this goes in
once CI is green." PR now 26 commits, head 36aba43. Follow-ups for us: #1183 (DT half of the N1 training) sits on
#1167 and may need a rebase after the merge; our daily's `j716s.config` fragment stays local (or goes to asahi.config).

## 2026-11-08 06:11 UTC: aurora-silicon/linux #1167 MERGED (merge commit e636747)

The J716s board device tree is upstream in `integration/aurora` with the maintainers' fixups (no per-board config
fragment, no `maxcpus=1` default). Follow-ups: rebase #1183 (DT half of the N1 training, carried #1167 underneath)
onto the new tip, and resolve #1182's conflict with its base (#937's branch); panel node for the boot framebuffer
and the trackpad reset route as later PRs.

## 2026-11-08 07:25 UTC: #1183 and #1182 rebased after the #1167 merge

- #1183 (DT half): now 2 commits on integration/aurora e636747 (head c69970a): the apple,manual-availability binding
  and the J716s N1 training DT; the 23 carried #1167/#945 commits dropped; the SMC GPIO node renamed `gpio` to match
  apple,smc.yaml (the W=1 `unit_address_vs_reg` warning is gone); dtbs_check clean with #1182's binding on top.
- #1182 (driver half): rebased onto the force-pushed base 911da8c (#937 rebased at the #945 merge); conflicts in
  apple,pcie.yaml, pcie-apple.c and gpio-macsmc.c resolved, edimoldovan's commits unchanged in content, the second
  t6050 block of the binding extended with our six reg-names; 9 commits, per-commit W=1 compile clean; mergeable again.
- Both pushed with --force-with-lease to the fork PR branches; notes posted on both PRs. Report:
  `contrib/validated/aurora/prs/REBASE-1183-1182.md`. Still open: edimoldovan's Signed-off-by on six of his commits.

## 2026-11-08 08:25 UTC: omacom/m1n1 #33-#37 rebased onto #30's 140a36b and re-validated on hardware

edimoldovan pushed 140a36b3 to #30 (late-heap retention: `kboot_retain_late_heap()` before the jump, answering a
greptile finding about USB DART tables). Our stack rebased with no conflicts (`contrib/validated/omacom/m1n1/
REBASE-ON-30-140a36b.md`): #33 ff75a40 (test-fix commit also declares the new statics so two host tests build),
#34 9879c2f, #37 2bebfe7, #35 5818f6b (keeps the phandle fix), #36 64c8ce2. None of our hand-offs allocates after
the new reservation point; the N1 training's SMC/ANS sessions and the display hand-off's temporary DT copies are
swept into the retained range. Builds 0x410000 / 0x420000, 15 warnings as before, pytest 442-443 pass, clang-format
empty. Hardware: the #36 tip booted the J716s (m1n1 v1.6.1-430-g64c8ce2, `FDT: late heap [...] retained`, N1 trained,
18 CPUs, Wi-Fi, Bluetooth; `~/Work/agents/omacom-m1n1/loop/run-wdt-keep-v30r3.log`), daily restored. Branches
force-pushed with lease, notes posted on all five PRs.

## 2026-11-08 09:35 UTC: M4Plus-Linux tracker published; #1167 reply posted

- https://github.com/rolotrealanis98/m4plus-linux (public; Pages at https://rolotrealanis98.github.io/m4plus-linux/,
  wiki off, Discussions on). Staged content as planned in `contrib/community/SHARED-REPO-PLAN.md`: README with the
  rules and AI policy, schemas, validator / generator / privacy scanner / PR-status tools with 81 tests, four
  workflows, `machines/j716s` with 23 scrubbed results and the daily recipe, J714s and J714c drafts that only link to
  their owners' posts, nine topic pages. To be transferred to `omacom/m4plus-linux` when the omacom side confirms.
- Reply posted on aurora-silicon/linux #1167: https://github.com/aurora-silicon/linux/pull/1167#issuecomment-6719931337

## 2026-11-08 15:50 UTC — GPU recovery and fault-blame PRs opened

- **#1240** `pr/g17-recovery-dropped-work` on `integration/aurora` (bdb99945db71): recovery 0001 + 0002 (spared and
  bounded work a GPU recovery dropped; a bystander compositor keeps its device) + a 5-line `Completion::signalled()`
  accessor the base lacks.
- **#1241** `pr/apple-drm-bounded-fence-wait` on `integration/aurora`: recovery 0003 (a GPU fence that never signals no
  longer wedges the display).
- **#1242** `pr/m5-recovery-cause-log` on `funkzy/t6050-gpu-on-integration`, stacked on #1173's head 34f2f5bb4d03:
  faults 0001 (firmware reason code and blamed client logged per recovery).
- **#1243** `pr/m5-fault-experiment-params` stacked on #1242: faults 0002 (`aurora.m5_pause_timeout_us` and
  friends; default stays 150 us; the 2000 us result is one 10-min run).
Checks: W=1 + CLIPPY=1 over `drivers/gpu/drm/{asahi,apple}` per commit, no new warnings (68 at the integration
base, 53 at #1173's), checkpatch --strict 0 errors, rustfmt-clean hunks. Hardware evidence in RESULTS.md (12:08,
12:24, 14:19 entries). Branches live in `/Volumes/linux-cs/linux`, pushed to the `rolotrealanis98/linux` fork.
