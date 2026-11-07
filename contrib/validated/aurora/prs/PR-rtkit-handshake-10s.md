soc: apple: rtkit: wait up to 10 s for a handshake reply

`apple_rtkit_wait_for_completion()` gives a co-processor 1 s to answer. On the J716s (MacBook Pro 16-inch, M5 Pro, T6050) the ANS firmware that iBoot hands over sometimes needs about 3 s to answer the power-state and endpoint-map handshake. With PR #936's nvme-apple that fails as "ANS did not boot" / "Reset failure status: -62" and there is no root device; a later rebind of the same firmware works.

This raises the timeout to 10 s. A firmware that answers in time is not slowed down; only a dead co-processor is reported later.

**Tested on:** J716s, in every payload since our round R3-J; most recently R3-SERIES and R3-S (2026-11-07, kernel built from this tree + the T6050 PRs): NVMe partitions at 0.37 s on every boot. `drivers/soc/apple/rtkit.o` builds clean with `W=1` (LLVM, arm64) on `integration/aurora` 7aee01a89865.

**Dependencies:** none; applies on `integration/aurora` alone and on top of #942 (rtkit crash logs). Motivated by #936 (T6050 ANS).

**Open questions:**
- Would you rather have this per co-processor (a `timeout_ms` in `struct apple_rtkit_ops`, or a DT property on the ANS, default 1000 ms) than global? Happy to rework it that way.

**v2 (2026-11-07, after RyanTheTide's pre-review):** commit 0630fabf19e9 (was 6d43a3ec72fa). The 10 s wait now applies only where it is needed. `apple_rtkit_set_handshake_timeout()` sets a per-instance handshake timeout, defaulting to the current 1000 ms, which every handshake wait uses (including the polled `apple,sync-syslog-ack` path). nvme-apple requests 10 s only for `apple,t6050-nvme-ans2`, so other SoCs still fail after 1 s. It checks the compatible because the T6050 match entry is in #936; once that lands it can become a field in `apple_nvme_t6050_hw`. Testing: the global 10 s (v1) was tested on the J716s. v2 is compile-tested only (`drivers/soc/apple/rtkit.o`, `drivers/nvme/host/apple.o`, W=1, LLVM, arm64; no new warnings, while `apple.c` already has 10 `-Wthread-safety-analysis` warnings on 7aee01a89865); it boots on the J716s in the next daily build. Applies on `integration/aurora` (7aee01a89865 and 4114f761f469), on top of #936, and on top of #942. checkpatch --strict clean. Patch: `patches-v2/rtkit-handshake-10s/`.
