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
