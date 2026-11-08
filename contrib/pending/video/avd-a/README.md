# avd-a test payload builders (2026-11-08)

Studio-side pieces of the AVD + JPEG "boot A" test described in `../AVD-BOOT-A.md`: `SERIES.txt` (branch `j716s-avd-a`
on the daily, with every conflict resolution), `patches/0001-0009` (the series as applied; 0001 is Aurora's T6041 no-reset quirk commit the daily lacks), `build-avd-fw.sh` (the open
decoder firmware from aurora-silicon/avd-fw, v5 tier 2, reproducible), `build-kernel-avd.sh` (the daily's container
recipe for the test kernel) and `mk-avd-a-test.py` (the payload, pinned loader/initramfs/firmware/restore target). The
runner that drives the MacBook stays private (host address).
