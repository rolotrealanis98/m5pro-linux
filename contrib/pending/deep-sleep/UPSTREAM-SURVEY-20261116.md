# Upstream survey: sleep, screen-off, s2idle power and hibernation on T6050 (2026-11-16)

Read-only survey. Sources: aurora-silicon/linux (fetched 2026-11-16, `integration/aurora` at `d5a8a254c0d8`), its
PRs (about 830 PRs matched by sleep / s2idle / suspend / DPMS / power gate / T6050 / hibernat / PMP / wake / s2r;
bodies read for about 40), aurora-silicon/aura (`origin/main` `52af355c`) and its PRs, DjDeveloperr's own repos,
`aurora-silicon.github.io` `src/data/support.json`, and betizzel/omarchy-m5 (`c45c137`).

"In next4" means reachable from `j716s-next4` (`ae58811d8398`, on `07ade53fd116`) or patch-equal per `git cherry`.
"Applies" means `git merge-tree` cherry-pick simulation (no worktree, no refs) gave no conflict.

## DjDeveloperr's machine

- **J714s** (14-inch MacBook Pro, M5 Pro), not a J716s. Every T6050 sleep PR he wrote says so: #1963 "T6050 (M5 Pro,
  J714s): suspend to RAM", "Run on the J714s only", and a per-board table that lists the J716s as "no profile: as the
  base".
- **DCP firmware 27.0.** #1963: "the sleep's A500 in the method table (a J714s copy of the 27.0 table) ... a J714s on a
  27.2 or 27.3 build: A408 with the base's table", so 27.2 and 27.3 get no firmware 27 sleep.
- **Linux at EL2 under aura.** His runs used aura main after #214, plus a private stack (display restart values, AOP2
  wake words, the PMU latch source). Most of that stack went public on 2026-11-15/16 as #2027-#2030.
- **Runs had both USB4 router nodes disabled.** The dock work came later (#2046, #2057).
- **Results:** six real sleeps and wakes in one boot. The panel lights 0.84 s after the wake with one DCP restart per
  wake (#2029).
- **The nearest upstream 16-inch M5 Pro is a K116s:** Jens Axboe's, Mac17,12, on the 27.2 stub (26B8125), s2idle only.
  Joshua Swarren's K114c (M5 Max) did read-only SPMI probes. Nobody else upstream runs a J716s or 27.3 sleep.
- **support.json** (last changed 2026-11-14, before #1963 merged): `j714s` Sleep/resume "works" with no note, and
  `j716s` "works: s2idle, 4 of 4 (#1152); lid wake fix (#1160)", which is our own row. It claims no deep sleep for any
  T6050 board.

## Blocker 1: deep sleep (DCP .prepare on 27.3; the AGT MSR)

### What exists

| What | Where | Author, board, firmware | State | In next4 |
|---|---|---|---|---|
| T6050 S2R series (25 commits: sleep profile, SMC, ANS2, SIO/AOP/AOP2, fw27 DCP sleep and wake, GPU, Type-C, PCIe, SPMI recovery, PMU latch ack) | #1963, merge `e5974c27faaa` | DjDeveloperr, J714s, 27.0 | merged 11-15 | yes |
| J714s sleep SoC data (4564-line dtsi) | #2030 `e0c68f7593d8` | DjDeveloperr, J714s | merged | yes (patch-equal; our `j716s-s2r-data` includes it) |
| **DCP restart during the wake:** RTKit crash-log buffer after a strict restart; the DART around the restart; display power words around the restart; restart at wake; one restart per wake | #2027 `929bfabd703c` `27524fa19c0e` `79dd83cfd941`; #2028 `69e7e757517a`; #2029 `1afdc5f302f0` | DjDeveloperr, J714s, 27.0 | merged 11-16 | **no** |
| Sleep-step refusal logging; merged-pair teardown; tunnel released at entry | #2053 `9558c0aa7cd5` `8ef6d2be19d0` `a7704ed576c6` (+ `af2f974aabda`) | DjDeveloperr, J714s | merged | no |
| Resume tail: SD port after the resume, parked-port work, N1 link watch, cd321x wake state | #2031 `0804d6f18b1a` `0a2d99d4ae30` `2a28cd0cc443` `b76f1e71d6be` | DjDeveloperr, J714s, "not yet hardware-tested" | merged | no |
| USB4 dock router sleeps in place / trains in place | #2046, #2057 (`24bdb358cf93` and others) | DjDeveloperr, J714s | merged | no |
| G17 M5: compute queues configured again at a wake | `03ee690458d3`, `721baa1a361f` | DjDeveloperr | merged 11-16 | no |
| **27.2 AP-link release is A550** (was A500) | #2063 `f07a07669558` | sithglan, J813 (T8142), 27.2 | open | no |
| T8140/T8142 fw27 DCP stop (set_power_state, A500, D572) | #1941 (5 commits) | gig3m / m0d16l14n1, J813, 27.0 | open | no |
| Our .prepare refusal on 27.3 | #2070 (ours, `eb13c59cec29`) | us, J716s, 27.3 | open | on `j716s-s2r-data` |

### 27.2/27.3 DCP sleep method tags: what is and is not known

- **Nobody upstream has a T6050 27.2 or 27.3 display sleep.** `dcp-v27-sleep.inc` still sends 27.0 literals through
  `iomfb_v27_call()` (A484, A500, A414, A489, A487, A412, A115, A442), bypassing the method table. That is why it
  crashes a 27.3 DCP.
- **The one new data point is #2063 (sithglan).** In the T8142 DCP firmware the AP-link release is not in the method
  table: the dispatch compares it in code. 27.0 (26A428, at 0x1de0dc) compares 'A500' / 'A501':
  `mov w9,#0x3030; movk w9,#0x4135,lsl #16`. 27.2 (26B123, at 0x1df68c) has the same code with `#0x3530`, so
  'A550' / 'A551'. That gives a method for 27.3: search `t605xdcp.im4p` 27.3 (`26C5035r`) for
  `movk wN,#0x4135,lsl #16` next to `mov wN,#0x3?30`.
  - The firmware image is not on this Mac. `~/Work/studio-artifacts/j716s-fw/Firmware/dcp/t605xdcp.im4p`, named in
    `contrib/pending/dcp/aurora/ANALYSIS.md`, is absent here. The host is an M2 Ultra, so Preboot only has
    `t602xdcp`.
- **The sleep's table-backed calls, mapped through our 27.3 table.** That table is our `23358a522bb6` in next4. Its
  untraced rows are inferred: the file comment says "27.2's tags, unmoved up to A517, one higher above". These are
  candidates, not facts. A wrong tag panics the DCP ("link_rpc_lookup callback not found").

  | 27.0 literal (method) | 27.2 | 27.3 candidate | basis |
  |---|---|---|---|
  | A484 set_power_state | A534 | A535 | our table, untraced |
  | A489 pipe_query_478 | A539 | A540 | our table, untraced |
  | A487 pipe_set_476 | A537 | A538 | our table, untraced |
  | A414 pipe_cfg_414 | A464 | A464 | our table, untraced |
  | A412 is_main_display | A462 | A462 | our table, untraced |
  | A407 swap_submit (J714s) | A458 | A458 | our table (27.3 swap record) |
  | A115 (UPPipe A1xx) | A115 | A115 | 27.2 comment: A0xx/A1xx unchanged |
  | A442 (out of band, unnamed in 27.0) | A492? | A492? | +50 rule; never seen |
  | A500 AP-link release (in code, not in the table) | A550 (T8142, #2063) | A550 or A551 | needs the firmware read |

  The sleep also needs the `sleep_v27_ep` endpoint tracking opened beyond `dcp->v27_j714s` (dcp.c:1518/1534/1674,
  afk.c:139).

### The AGT MSR (S3_4_C15_C2_7)

- **Upstream has not changed this code.** `t6050_sleep_boot_timer_off()` in integration still writes
  `SYS_APL_AGT_CTL_EL02` = `sys_reg(3,4,15,2,7)` from a bound worker, gated only by `is_kernel_in_hyp_mode()`.
  Nobody else has reported it.
- **Our branch already copes.** It is off by default (`apple_sleep.t6050_agt_off`) and moved to an IPI.
- **A lead, not checked:** aura's `cpu_regs.h` names the neighbouring encodings `S3_4_C15_C2_2` and `S3_4_C15_C2_5`
  as `CTRR_B_CTL_EL1` and `CTRR_A_CTL_EL1`. C2_7 sits in the CTRR control block. So on our chain (m1n1 stage 1, aura
  stage 2, 27.3) it may be locked or trapped, where the J714s's aura stage 1 on 27.0 leaves it open.

### Port recommendation

1. **Port #2027-#2029 onto `j716s-s2r-data` now:** `929bfabd703c` `27524fa19c0e` `79dd83cfd941` `69e7e757517a`
   `1afdc5f302f0`.
   - Applies cleanly onto `eb13c59cec29`.
   - Without it no T6050 wake lights the panel (#1963: "With these 25 commits alone the internal panel does not
     light after a wake"). It is inert for us while #2070's .prepare refusal stands.
   - Risk: the PMC handshake checks for "disp-4" at exactly `0x286700000` (dcp-v27-sleep.inc:186), and the DART GAPF
     slice is matched by J714s DART addresses. Both are T6050 SoC addresses and should match the J716s, but check them
     against our DT before relying on them.
2. **#2053:** `8ef6d2be19d0` applies. `9558c0aa7cd5` conflicts in `dcp-v27-sleep.inc` with our `eb13c59cec29`, a
   small hand merge. `a7704ed576c6` conflicts in `dcp-fabric.c` unless `af2f974aabda` comes first. Low priority: these
   are external display and tunnel cases.
3. **#2031:** three of its four commits apply. `0804d6f18b1a` conflicts in `pcie-apple.c` with our J716s cold-train
   changes. Take it once deep sleep gets past .prepare.
4. **The real unblocker is not in any upstream tree: the 27.3 tags.**
   - Do a sithglan-style read of the 27.3 `t605xdcp` dispatch for the A500 compare, and confirm A535/A540/A538/A464/
     A462 there. Or get a macOS 27.3 sleep trace through the HV.
   - Then generalise `iomfb_v27_methods_j714s()` into a per-build sleep table instead of literals.

## Blocker 2: screen off, DPMS and DCP power-down on firmware 27

### What exists

- **Upstream T6050 today:** on firmware 27, `dcp_uses_soft_dpms()` is true for the eDP panel, so DPMS off only blanks
  the backlight. `dcp_dpms_power_cycles()` requires `hw.s2r`, and `apple_dcp_hw_t6050` has none.
  `appledrm.power_gate_ms` exists only in `iomfb_m4.c` (T8132).
- **#1941, gig3m (Kyle Arrington), from m0d16l14n1's J815 work, open:** "T8142: stop the DCP firmware on DPMS off
  (firmware 27.0)". Commits `113b85172394` `f54c63ac65c9` `9a0bdd4ccfe3` (+ DT/selftest `9838f823176b`
  `48aab64bef51`).
  - Adds a per-SoC `dcp_s2r_layout` (power words, retention words, DART streams) and `s2r_no_secure_port`.
  - Adds firmware 27's stop calls: set_power_state, A500, and D572 powerUpDART (`trampoline_dart_power_v27`).
  - Gated by `appledrm.s2r_untested=1` and firmware 27.0.
  - **Measured on J813: screen-off 2.72 W to 1.81 W**, 9 DPMS cycles.
- **#2019, gig3m, open:** "stop the DCP firmware for a suspend-to-idle too" (`9e707546362e`). **J813 s2idle 1.53 W to
  0.53-0.58 W**, with 146 ms added to suspend and 57 ms to resume.
- **#2063, sithglan, open:** gives the 27.2 table the A550 entry. With it, the J813 on 27.2 stops the DCP on DPMS off.
- **#2027-#2029, DjDeveloperr, merged:** `dcp_v27_rtkit_cycle()` is the only T6050 fw27 DCP stop, power-off and
  restart sequence anywhere:
  - sessions closed, RTKit idle, receive side off, CPU stop;
  - `apple_dart_m5_display_cycle()` (GAPF slice 0x2/0x12, streams 23/24);
  - the display PMC handshake (+0x108020/+0x108028, request word);
  - `apple_sleep_m5_display_power()` (the CPU/FE/SYS words from the sleep profile's `ps.disp[]`);
  - at least 12 ms off, then a strict warm restart.

  It runs only inside the wake today. As a sequence it is the T6050 counterpart of #1941's T8142 stop.

### For the J716s

- **No secure mailbox needed.** The 27.3 ADT has no `dcp-exclave-mailbox`, only `mapper-dcp-exclave`, so the T6050
  needs #1941's `s2r_no_secure_port`, as the T8142 does.
- **Three things are missing for a fw27 DPMS power-down:**
  1. a T6050 `dcp_s2r_layout`, or a hook that calls #2027's `apple_sleep_m5_display_power()` and
     `apple_dart_m5_display_cycle()` in place of the T8142 PS write-disable bit;
  2. the 27.3 set_power_state tag (A535 candidate);
  3. the 27.3 AP-link-release tag (A550 or A551, unknown), plus D572 on 27.3. The callback IDs are unchanged in the
     shared 27.x callback table.
- **Untested:** whether a T6050 fw27 DCP idles without the A500-class call is unknown. #2027 always sends A500 before
  each stop.

### Port recommendation

- **Cherry-pick #1941's three driver commits, #2019 and #2063 onto next4.** All five apply cleanly
  (`113b85172394 f54c63ac65c9 9a0bdd4ccfe3 9e707546362e f07a07669558`). With no T6050 layout they are inert on the
  J716s.
- **Then write a J716s-only T6050 layout on top of #2027's helpers:**
  - keep it behind `appledrm.s2r_untested`;
  - send the 27.3 sleep tags only once they are read from the firmware;
  - first test: DPMS off/on cycles with PSTR, then #2019's s2idle stop.
- **Expected gain**, scaling from the J813: a few hundred mW to about 1 W of our 4.3 W s2idle, plus screen-off idle.
- **Risk:** a DCP crash on a wrong tag, so read the dispatch first. The external DCP is not covered, as on the
  T8142.

## Blocker 3: s2idle power (what stays up, PMP domains, RTC wake)

| Item | Commit / PR | Author, board | State | In next4 | Applies |
|---|---|---|---|---|---|
| PMP domains (pms, pmp, pms-sram) `apple,always-on`. This is omarchy-m5's "0028" (README: "0028 #1789 (`f61eb4550a95`)") | #1789 `f61eb4550a95` | Jens Axboe / sithglan, K116s 27.2, 2 clean s2idles | merged 11-16 | **no** | yes |
| Devices below a kernel-trained port may leave D0 | #1647 `70bf8ed1867b` | Axboe / sithglan, K116s | merged | no | yes |
| K116s / J714s in the adopted-link s2idle allowlist | `aa16d423cf8a`, #2012 `56b02059cfc8` | Axboe, Isaac Duarte | merged | no | **conflict** (our `apple,j716s` line in the same list) |
| ATC usb-aon domains always-on (Type-C dead after s2idle) | #2018 `64d473f5321d` | Isaac Duarte, J714s | merged | **yes** | n/a |
| GFX domain kept across s2idle (K114c) | #1710 | joshuaswarren | merged | yes; our DT has `&ps_gfx` always-on | n/a |
| T6050 GPU mailboxes by interrupt (#1843's s2idle panic avoided) | #1844 | erikwb | merged | yes | n/a |
| DCPEXT crossbar output parked for s2idle | #1723 `265f620833e7` | RyanTheTide | merged | yes | n/a |
| **Gen-4 SPMI interrupts and mask bank** | #1743 `f2aaec48fc75` `d18d765c60c0` | joshuaswarren, K114c read-only probes, "NOT booted" | open draft | no | yes |
| **T6050 PMIC RTC alarm IRQ** (nub-spmi0 as interrupt controller on AIC 726; smc_rtc source 2) | #2007 `c373799c6e14` | joshuaswarren, unbooted | open draft | no | yes |
| Gen-4 SPMI IRQ banks (0x400 mask, 0x600 ack) + FIFO recovery, older form | `d505e03bff1e` (branch `t6050/spmi`) | DjDeveloperr, 10-26 | closed, not merged | no | not tried |
| PMU RTC for T6050 (older) | `d16bbc059818` (`t6050/pmu-rtc`) | DjDeveloperr | closed | no | superseded by #1963's pmu-rtc |
| ANS keep-live across s2idle, opt-in (keep-live crashed ANS on K114c after ~60 s) | #1698 | joshuaswarren | open draft | no | - |
| USB DARTs kept live across sleep (J714s reset otherwise) | #1699 | joshuaswarren / FatBoy721 | open draft, compile-only | no | - |
| D3hot endpoint accepted in the s2idle check | #2010 | joshuaswarren | open draft | no | - |
| H17 ANE parked when idle (J700) | #1863 | niteria | open | no | - |
| Idle-cluster parking | #1988 (`6b72af7a8c93` `b17d649b440c`) | RyanTheTide | open draft | ours already, with the `policy->cpus` fix `4a223cc5ae56` that upstream lacks | - |
| CPU PD residency knob | #2044 | muness | open | no | - |

Notes:

- **PMP domains.** #1789 is inert for us while `ps_pms` stays disabled in the J716s DT. Our sleep dtsi already sets
  `ps_pmp` and `ps_pms_sram` always-on. Take it anyway, so that enabling the PMP later does not bring back the K116s
  "PS pms: Failed to reach power state" crash.
- **RTC wake.** Upstream still refuses an interrupt on a gen-4 controller ("Generation 4 interrupt layout is not
  supported", spmi-apple-controller.c:711). Only #1743 + #2007 address it, and both are unbooted.
  - Our 27.3 ADT gives `nub-spmi0` `interrupts` = <256, 726, 281, ...>. That matches #2007's "index 1 = 726"
    inference, but `interrupt-parent` holds three phandles (0x2b6, 0x144, 0x2b6), so the parent of 726 needs a look.
  - #2007 hangs the alarm cells on `smc_rtc`, while our `t6050-j714s-sleep.dtsi` adds `pmu_rtc` (`apple,t6050-pmu-rtc`)
    under `&pmu`. Pick one alarm owner before booting.
- **Nothing upstream powers down on T6050 s2idle beyond the items above.** That covers the DCP (blocker 2), GPU
  firmware, the Thunderbolt link with a PCIe tunnel, the N1 link and NVMe. The USB4 router "sleep in place"
  (#2046/#2057) is deep-sleep only. Our low-power findings stand: about 4.3-4.4 W.

### Port recommendation

- **Take `f61eb4550a95` and `70bf8ed1867b` (clean).** Hand-merge `aa16d423cf8a`/`56b02059cfc8` into our allowlist:
  keep `apple,j716s`, add `k116s`/`j714s`.
- **Port #1743 + #2007 as a single test boot:**
  - `rtcwake -m freeze -s 30` with the WD0 wake left as the fallback;
  - risk: if the AIC parent is wrong, `nub-spmi0` stops probing, and with it the PMU RTC;
  - DjDeveloperr's `d505e03bff1e` is a second reference for the bank offsets.

## Blocker 4: hibernation

**What exists (has the picture changed? Yes, on the J616s, not the T6050):**

- **The J616s (M4 Pro, T6040) hibernates at EL2 under aura.**
  - fbalazsy's #1477 (closed): #906 first. It was split into #1903-#1916 (open; 2/9 is #1909, the hibernation core).
  - Measured: repeated hibernations with the desktop, GPU and compute clients kept. One intermittent open issue in the
    G17 kernel window after back-to-back hibernations.
  - aura side: #148 (merged) adds `hib=1`, a fixed layout published as `/chosen/aura,hibernate-layout` plus a DT slot.
- **It answers both of our "not feasible" reasons:**
  - **Spin-table CPUs going offline.** `95ba8c321482` "arm64: hibernate and spin-table CPUs at EL2 on M4 Pro
    (T6040)": an offlined RVBAR spin-table CPU parks in a pen in the kernel image and comes back through
    `cpu_soft_restart()` (needs KEXEC_CORE). `spin_table_hibernate_cpus_stuck()` replaces the kexec check for
    hibernation.
  - **iBoot restarting every coprocessor.** The restored kernel rebuilds each one in place:
    - RTKit-helper re-adopt;
    - DART `.restore` re-imports locked DARTs' fresh firmware roots;
    - PMP session rebuilt on `PM_POST_HIBERNATION`;
    - SMC new RTKit session in `.restore`;
    - AIC/SPMI masks re-applied;
    - genpd re-powers domains found gated;
    - the GPU firmware is republished.
- **RyanTheTide #1814 (open):** pm_test hibernation dry runs on Apple silicon. It fixes apple-pmu-rtc refusing
  hibernation in `.prepare`, which matters for any dry run of ours.

**For the J716s:**

- aura's `hib=1` is T6040-only (`kboot.c` "Hibernation layout (T6040, config line hib=1)").
- None of the T6050 coprocessors has a cold-restore path in that series: fw27 DCP, G17 M5 GPU, ANS2, N1, AOP2, SIO.
- **We do run Linux at EL2.** Our AGT note says "from EL2 with E2H", so the EL2 spin-table pen approach applies in
  principle.

**Verdict:** move hibernation from "not feasible" to "feasible in principle, XL". Prerequisites: aura `hib=1` for the
T6050 on our m1n1-stage-1 chain (CTXR window at a fixed address), #1909's core, and a cold restore for every T6050
coprocessor. Do not start before deep sleep works. `#1814`'s pmu-rtc `.prepare` fix (`38a70bfa8027` range) is the
only piece worth taking early, and only if we run hibernation dry runs.

## Other repos checked

- **DjDeveloperr/linux** (pushed 10-03): `dcp/sleep` is Hector Martin's 2022 WIP. `m5-t6050-dts` (07-23) is a
  descriptive J714s DTS. Nothing for sleep.
- **DjDeveloperr/m1n1:** `m5-t6050-rfc` and `m5-t6050-atcphy-display`, no sleep.
- **DjDeveloperr/aurora-darling:** a fork of VibeDarling/darling, a Darwin emulation layer, pushed today with CI work
  only. Unrelated.
- **aurora-silicon/aura:**
  - #214 (Dj, merged): T6050 SIO tables, plus the sleep node's wake sources and skipped pins from the ADT.
  - #217 (Ryan, merged): S2R mailbox where RVBAR is not locked.
  - #117 (Dj, closed): an OS at EL2 returns from its own sleep.
  - #148 (fbalazsy, merged): hib=1 and the T6040 S2R windows.
  - Nothing else for T6050 sleep. Our `j716s-s2r` aura work (`74aa840e`) is ahead of upstream for the J716s mailbox.
- **betizzel/omarchy-m5, J714s on 27.2:**
  - "Lid sleep works" (v272-12, 2 s2idle cycles on TripleU613's J714s) is #1647 + #2012 + #2018 + #1789. Those are
    upstream now.
  - `CONFIG_APPLE_SOC_SLEEP` is off there, so the release has no deep sleep.
  - Their J714s runs Linux at EL2 with a stage 1 that does not start SPTM ("aurora-silicon targets 27.2",
    `docs/move-to-27.2.md`).

## Top three to port first

1. **#1941 + #2019 + #2063, then a T6050 fw27 layout.**
   - Commits: `113b85172394 f54c63ac65c9 9a0bdd4ccfe3 9e707546362e f07a07669558`; they apply cleanly to next4.
   - Why: the only fw27 DCP stop on DPMS off and in s2idle with measured savings (J813: 2.72 to 1.81 W screen-off,
     1.53 to 0.55 W s2idle). It goes straight at blocker 2 and the largest known piece of our 4.3 W.
   - Needs: the 27.3 AP-link and set_power_state tags from a firmware read, and a T6050 layout on #2027's helpers.
2. **#2027 + #2028 + #2029.**
   - Commits: `929bfabd703c 27524fa19c0e 79dd83cfd941 69e7e757517a 1afdc5f302f0`; they apply cleanly to
     `j716s-s2r-data`.
   - Why: required for any T6050 deep-sleep wake (the panel stays dark without it), and they hold the only T6050 DCP
     power-down sequence (DART, PMC handshake, power words) that item 1 can reuse.
3. **#1743 + #2007** (`f2aaec48fc75 d18d765c60c0 c373799c6e14`, clean). Take `f61eb4550a95` + `70bf8ed1867b` along,
   also clean.
   - Why: they fix the gen-4 SPMI IRQ refusal, so the PMU RTC alarm can wake s2idle. That is blocker 3's named gap, and
     the same interrupt path the deep sleep's PMU latch uses.
   - Risk: they have never booted anywhere; check the AIC parent and pick one RTC alarm owner first.

**The common unblocker for blockers 1 and 2 is not upstream:** read the 27.3 `t605xdcp` dispatch for the A500-class
compare and confirm A535/A540/A538/A464/A462. That is the method #2063 used for 27.2 on the T8142. The firmware image
is not on this Mac.
