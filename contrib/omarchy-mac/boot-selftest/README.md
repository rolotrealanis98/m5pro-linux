# boot-selftest

A payload booted with `m5.selftest=1` must reach the network in 90 s or the previous `boot.bin` is restored; the two stage-mark units record boot progress. `m5-stage-mark.sh` and `firstboot-probe.sh` live in `contrib/pending/boot-ab/firstboot/`.

- Scope: `j716s`. Status: installed. Upstream: none (bring-up tooling for a hand-built boot chain).
- Install: `sudo contrib/omarchy-mac/install-item.sh boot-selftest`. Then: `systemctl daemon-reload; systemctl enable m5-selftest m5-stage-mark-net m5-stage-mark-root`. The script assumes the ESP is `/dev/nvme0n1p4`: check before use.
- Undo: `sudo contrib/omarchy-mac/install-item.sh --remove boot-selftest` (originals come back from `*.before-omarchy-mac`).
- Files are captured from the MacBook on 2026-11-17; the row in `../INVENTORY.md` is the record.
