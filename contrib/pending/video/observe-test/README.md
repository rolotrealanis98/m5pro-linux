# video-observe test payload (2026-11-08)

One self-reverting test payload that observes both video blocks on the J716s without a data path:
the AVE encoder (probe-only bind, firmware handed over by the loader) and the ProRes engine
(observe-only probe, registers read once). Kernel `7.3.0-g0933f881d736` = daily-dcp-rec-p2000
(`12c445fa5371`) + the stack in `SERIES.txt` (video 0006/0008, encode 0001/0002, prores
0001/0003/0004/0005; prores 0002 dropped because 0008's `t6050-media.dtsi` already defines
`apr0`/`apr0_dart`). Config = the daily's + `CONFIG_VIDEO_APPLE_PRORES_T6050_OBSERVE=y`.
Loader = the daily's `n1-dt-gpu-dcp-phfix` + `../encode/patches/m1n1/0001` (AVE hand-off).
Bootargs = the recovery test set + `aurora.m5_pause_timeout_us=2000 module_blacklist=apple_prores`
(the observer is loaded by hand during the test). Scripts here are the Studio-side builders; the
runner that drives the MacBook stays private (host address). Results: RESULTS.md (2026-11-08).
