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
