# recovery2 build and payload tools (2026-11-08)

Studio-side scripts that produced kernel `7.3.0-g12c445fa5371` (branch `j716s-daily-dcp-recovery2`
= daily-dcp `bd53915f2ef1` + `../0001-0003` + `../../faults/0001-0002`) and its payloads. Paths point
at `~/Work/agents/gpu-recovery/` on the Studio; the runners that drive the MacBook stay private there
(they carry the host address).

- `build-kernel-r2.sh`: the Fedora 43 container build (clang 21, rustc 1.99, same config as daily-dcp).
- `check-r2.sh`: W=1 + CLIPPY=1 over `drivers/gpu/drm/{asahi,apple}` per commit, new-warning diff.
- `mk-recovery2-test.py`: the two test payloads (`m5.selftest=1`, `watchdog.open_timeout=300`):
  `daily-dcp-recovery2-test` (stock 150 us pause bound) and `-pause2000-test`
  (`aurora.m5_pause_timeout_us=2000`).
- `mk-recovery2-daily.py`: the daily `daily-dcp-rec-p2000` (no selftest, VRR on, pause bound 2000 us),
  built 2026-11-08 as `daily-dcp-rec-p2000-20261108-f185b487.bin`.

Results: `contrib/validated/integration/RESULTS.md` (2026-11-08 12:08, 12:24 and promotion entries),
`../REPORT.md`, `../../faults/HYPOTHESES.md` (H1).
