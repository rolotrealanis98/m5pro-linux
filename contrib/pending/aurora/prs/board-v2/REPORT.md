# J716s board PR, v2 (2026-11-07)

(Saved by the coordinator from the agent's hand-back.) Branch `pr/j716s-board-v2` (`4e93573160c6`) on the carried tip
`61346ae6ef7f` (#935 commits 1-9, #945 commits 10-12, unchanged). Nothing pushed or posted; v2 not booted. Deliverables:
`patches/0001-0010`, `CPUFREQ-DECISION.md`, `COMMENT-481.md`, `COMMENT-946.md`, `dtb/` (v1 and v2 DTBs + decompiled),
`logs/`, `venv/` (dt-schema 2026.9).

## v1 -> v2
| v2 | change |
|---|---|
| 0001 t6050-max CPU order | unchanged |
| 0002 SMC second GPIO bank | node renamed `gpio@67700000` -> `gpio-low` (apple,smc.yaml documents it; t6041-j616c uses it; driver matches by compatible; node contents and phandle identical) |
| 0003 apple.yaml J716s | unchanged |
| 0004 dt-bindings: pwm: apple,s5l-fpwm: t6050 | new |
| 0005 dt-bindings: spmi: apple,spmi: t6050 (+t8142 pair) | new |
| 0006 dt-bindings: power: apple,pmgr-pwrstate: t6050 | new |
| 0007 dt-bindings: arm: apple,pmgr: t6050 | new |
| 0008 J716s board DT | `apple,internal-panel` dropped (no binding, nothing on integration reads it) |
| 0009 j716s.config | unchanged |
| 0010 t6050-j716s: use the T6050 cpufreq profile | new: removes the T8112 override ("adopt #481") |
Trailers: author + `Signed-off-by: Rolando Trevino` + `Assisted-by: LLM Claude` on all ten (Aurora PR branch).
No carried commit adds the t6050 spmi / pmgr-pwrstate / pmgr bindings; 0004-0007 also clear 22 carried pwrstate nodes, 3 PMGRs, 3 SPMI buses.
DTB sha256: v1 `8c4df67ac743` (= R3-SERIES boot), v2 without 0010 `ab71443ce429`, v2 `4a00841d84dd`; decompiled diff = node name, internal-panel, three cpufreq compatibles.

## Checks
- `make W=1` j716s/j716c/j775d: 0 warnings. `make dtbs`: clean. `dt_binding_check` on the five bindings: pass; yamllint clean.
- checkpatch --strict: 0001-0007, 0010 clean; 0008/0009 MAINTAINERS note; 0008 "undocumented apple,t6050-cluster-cpufreq" x3 for lines 0010 removes (squash 0010 into 0008 clears them).
- dtbs_check `apple/t6050-j716s.dtb`: v1 144 warning lines -> v2 55 (J716c on the same tree: 57). Ours fixed: fpwm, pmgr-pwrstate, pmgr, spmi, internal-panel, cpufreq (now only "no schema", like J716c; #481 fixes it), gpio-low. **Open ours:** usb@2a2280000 `snps,dwc3` `iommus` too long (the ATC0 tether gadget: two DARTs, snps binding allows one). Carried: tunable-cio (#939), smc-reboot nvmem-cells (#941), tx-never-wait (#946), centauri (#938), smc/cio-reset/usb4/nvme/sart/pcie/combo-phy/t6050-dwc3/display-crossbar (#941/#946/#936/#937/#939), admac/aop/aop-audio/mtp/dockchannel/pinctrl/i2c/dcpext/pmc/clpc (no binding in any PR).
- Preview with #946's bindings dir swapped in (approximate): cpufreq, smc, reboot, tx-never-wait, tunable-cio, centauri, NVMe, DWC3 clear; still ours: the ATC0 iommus; same as J716c: atc1_phy lacks the 14 `apple,tunable-*` (#939 makes them required; the loader fills them); `gpio-low` flagged only by #946's older smc.yaml.

## Still blocking
1. cpufreq depends on #481: with 0010 and without #481 no cpufreq driver binds (should still boot at iBoot's p-states; untested). #481's T6050 profile never ran on the J716s; the `apple,firmware-managed-thermal` qualification was not done here.
2. ATC0 gadget node: `snps,dwc3` with two DART iommus. Recommend moving the tether gadget out of the PR into m5pro-linux local changes (depends on the PHY state m1n1 leaves; reviewers will question it). Alternative: `apple,t6050-dwc3`.
3. #946 adds `nub_spmi_a1: spmi@28a1a8000` to the shared `t6050-max.dtsi`; our board file defines the same label -> dtc duplicate-label failure once #946 lands. Then: `&nub_spmi_a1 { status = "disabled"; };` and check #946's ATC2 router nodes' status on the J716s.
4. v2 not booted (runtime-relevant: the rename, matched by compatible; and 0010).
5. PR body `~/Work/agents/aurora-prs/PR-j716s-board.md` is stale (dtbs_check done; bindings added; internal-panel gone; cpufreq via #481; runtime deps #946 + #941).

## Decisions and drafts
- cpufreq (`CPUFREQ-DECISION.md`): adopt #481, drop 0053 (the carried dtsi already has the single compatible and `apple,firmware-managed-thermal`; #946's base lists #481; it applies cleanly onto v2).
- `COMMENT-946.md`: we read the odd bit the other way, dropping ours; our boots only showed the reset controller probing, no deassert; asks about a probe-only Tested-by and whether `usb4_3_acio` is expected to work on T6050.
- `COMMENT-481.md`: the J716s situation; one question: what should a board do before it carries `apple,firmware-managed-thermal`?

## Next
1. Post COMMENT-481 / COMMENT-946 (Rolando). 2. Boot integration + #481 + `dtb/j716s-v2.dtb`: three cpufreq policies, no thermal-ownership or transition-timeout errors, each cluster scales; then the all-core qualification watching TCMb and the fans; pass -> squash 0010 into 0008; fail -> drop 0010, back to 0053. 3. Decide the ATC0 gadget; if out, delete the node and its two DARTs from 0008, rerun dtbs_check. 4. Close `pr/t6050-cpufreq-binding` and `pr/t6050-cio-reset`. 5. Update the PR body, push `pr/j716s-board-v2`, open stacked on #945. 6. After #941/#946 rebase, rerun dtbs_check, fix the `nub_spmi_a1` label.
Reproduce: macOS recipe + `PATH=~/Work/agents/board-pr/venv/bin:$PATH make O=/Volumes/linux-cs/wt-prs-out CHECK_DTBS=y apple/t6050-j716s.dtb`.
