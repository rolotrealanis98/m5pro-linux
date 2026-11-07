# Update (2026-11-07 evening): rebased onto #30; #26 closed

- **Why #26 closed:** edimoldovan closed it unmerged at 20:48 UTC: "Superseded by #30, which carries this together with
  the rest of the T6050 support the J714c now boots from disk with, rebased onto the current integration/aurora".
  #30 (`edimoldovan:j714c/diskboot`, head ad08bf5, base integration/aurora 121fcbf, open) carries #26 and #27 plus his
  USB host prep, the G17 GPU fill for `apple,agx-t6050`, the PMP DAPF entry and the live-ANS marking for U-Boot. No
  T6050 code is in integration/aurora c614476 (#25, J504, merged since).
- **Stack:** all five branches rebased onto #30's head. Nothing of ours is carried by #30 beyond what #26 already
  had. Changes in the rebase:
  - the test-fix commit now covers the five CI tests #30 breaks (adds `test_m3_defaults_optout` and
    `test_universal_boot`);
  - `dt_set_gpu()` on T6050 picks our fill for `apple,agx-g17s` and #30's G17 fill otherwise (before, #30's dispatch
    returned first and made ours unreachable);
  - the `nvme.c` conflict keeps both #30's `nvme_t6050_stop_coproc` and our `nvme_stop_requested`;
  - the display commit message names #30.

  The stack merges cleanly with c614476. `omacom/wdt-keep-standalone` is on c614476.
- **New tips:** t6050-bringup 80e7953bc8ee, t6050-n1 26519fb00302, t6050-gpu be49759ad511,
  t6050-display 256759b17454, wdt-keep 6653bb279714, wdt-keep-standalone a08882b (see build-results/refs.txt).
- **Build matrix:**
  - Every commit with `make`, and every tip with `make CHAINLOADING=1`: no new warnings against #30
    (build-results/new-warnings.txt). Sizes 0x410000 / 0x420000, the same as #30.
  - pytest: #30 head 5 tests failing (141 errors in one); every tip passes (442; 443 with wdt); standalone 466;
    c614476 465.
  - clang-format: clean.
- **Hardware:** the #26-based wdt-keep payload (`v26/`, 2014252d) booted the J716s on the first pass:
  - `Primary WDT left armed`, `SMP: installed RVBAR relay`;
  - the N1 trained by the loader (`pcie-t6050: port 0 up, N1 at 01:00.0`, `n1: port 0 up: root port and DART okay`);
  - MTP DAPF programmed, 18 CPUs, Wi-Fi up, no USB gadget network (expected).

  PR-1, PR-2 and PR-5 are therefore proven in that stack. GPU and display were present but not armed. The #30-based
  payloads are rebuilt (payloads/) and have not booted. #30's USB host prep has not run on a J716s.
- **Not pushed:** the coordinator asked for a force-push of the rebased branches to the fork. Rolando's task said no
  push, so the commands are in the report for him to run.

# omacom/m1n1 T6050 series — five PR-ready branches stacked on #26 (2026-11-07, not sent, not booted)

omacom/m1n1 default branch `integration/aurora` (121fcbf; `main` is upstream Asahi). #26 is cut from edimoldovan's
`j714c/m1n1` (re-splits 26c2c86, 5211878 without traces/opt-in coprocessor stop, eaa6bd1 onto current
integration/aurora); #27 = his two payload commits. His j714c/m1n1 head 5bb6965 sits on an old integration/aurora
(50fb132) and still has, in no omacom PR: USB host prep (7 commits), 160b644 GPU fill for `apple,agx-t6050` (needs 4
perf-state tables; the J716s ADT has 2, so it would disable our GPU; ours runs only for `apple,agx-g17s`), fc277aa PMP
DAPF, 5bb6965 live-ANS marking for U-Boot (`asahi,nvme-adopt`), proxyclient chainload. His m1n1 publishes nothing for
the T6050 display and does not train the N1. Stacked on #26 (PRs must sit on current integration/aurora; on his head
the series conflicts in kboot.c after the N1 training commit).

Dropped as covered by #26: i2c limit 16, CPU_START bit (BIT(index)), ANS split BAR (J716s NVMe/NVMMU addresses match
the J714c, 0x30000 window).

| Branch | Head | Adds |
|---|---|---|
| omacom/t6050-bringup | f8ab2e17c3c4 | fix for 3 CI tests #26 breaks (test_nvme_adoption, test_smp_handoff_gate, test_t8103_inherited_reservation) + RVBAR relay with host test |
| omacom/t6050-n1 | 561df3a66f43 | N1 DT fill-in, training, ANS start for storage checks, SMC gP13 pulse, warm-N1 entry (0027 rebuilt) — optional if kernel-side training works |
| omacom/t6050-gpu | 8906f3b36876 | GPU hand-off for apple,agx-g17s |
| omacom/t6050-display | 1e7b2780660f | firmware strings, __OS_LOG reservations, opt-in hand-off `chosen.asahi,t6050-display`, compat 27.3.0 |
| omacom/wdt-keep | aee8488dd7a7 | `m1n1.wdt=keep` boot option (opt-in), docs/boot-options.md, test |
| omacom/wdt-keep-standalone | 0d93a7071388 | same on integration/aurora alone |

Authorship Rolando Trevino, Signed-off-by, no AI trailers (omacom rules do not ask; AGENTS.md/CLAUDE.md only on
main; PR #3 requiring Co-Authored-By was closed). Rolando later allowed AI trailers on omacom commits (2026-11-07).

Comparison: RVBAR relay needed only when stage 2 is too big to stay at stage 1's base (our kernel-appended stage 2;
his U-Boot chain never reaches it). ANS: his chain leaves ANS live for U-Boot; our N1 code trains without touching
ANS and stops it only if it started it (only the stopped-ANS path has run on hardware). Display: opt-in; two parts run
on every T6050 boot incl. his J714c (__OS_LOG reservations, read-only DCP state log) — PR-4 asks him.

Build/tests (Fedora 43, clang/lld 21.1.8, rustc 1.99.1): every commit builds, each tip also with CHAINLOADING=1,
15 warnings = base; m1n1.bin 0x410000 plain / 0x420000 chainloading; pytest integration/aurora 441 pass, #26 3
failures, every tip 442 (443 with the wdt test); git clang-format clean. Range-diffs in
~/Work/agents/omacom-m1n1/range-diff/. PR texts PR-1 … PR-5 in ~/Work/agents/omacom-m1n1/.

Payloads (~/Work/agents/omacom-m1n1/payloads/, self-test on, 0600): bringup 0ff98ed2 (daily, stage-1 wdt disarmed,
attended from full power-off), n1 8d2a9d1d (chosen.asahi,t6050-n1=4, disarmed, attended), gpu 8fe1fce1 (E2 kernel,
disarmed, attended), display 916071aa (DCP-B0 DTB, display opt-in, disarmed, attended), wdt-keep 2014252d (full
stack, daily, n1=4, watchdog kept armed, unattended OK). Panel: no `is not alive`; `SMP: installed RVBAR relay`
once; 18 CPUs; wdt-keep: `Primary WDT left armed (m1n1.wdt=keep)`.

Risks: no T6050 USB-C PHY tunable fill (our 0021) and no baked tunables in the daily DTB -> USB network may not come
up (N1 payloads have Wi-Fi); relay necessity in our chain inferred; #26 programs only the MTP DAPF (lineage programmed
all + dart-pmp0); overlaps with the Omarchy-chain B1 build (PR-1, PR-5).
