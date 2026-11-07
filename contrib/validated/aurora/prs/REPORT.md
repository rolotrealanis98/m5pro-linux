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
