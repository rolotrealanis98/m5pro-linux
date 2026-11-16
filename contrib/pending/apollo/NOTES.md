# apollo: open-apollo on the J716s (2026-11-15 night)

- Clone: `/Volumes/m5pro/bench/apollo/open-apollo` (branch `j716s`, no local changes needed; upstream main 8e7cd3f, driver v0.2.0, GPL-2.0).
- Build: `/Volumes/m5pro/bench/apollo/build-ua-apollo.sh` (env TREE, OUT, DRV, RES). Built clean (clang, W=1, zero warnings) against next2
  (7.3.0-ge4fc1f3d43ba, 16K pages): `result/<release>/ua_apollo.ko`, `ua_apollo.stripped.ko`. Not loaded on hardware.
- The driver already handles arm64/16K pages and Asahi (docs/asahi-linux.md: verified on a Mac Studio M2 Ultra over a TB3 Apollo x4, MSI, no IOMMU faults).
- Firmware: the driver needs no blob by default; `input_strips=1` needs 7 DSP strip modules `dsp/{0a5,0c2,0c9,0da,0db,0eb,12b}.bill`. They are in the macOS UAD
  install on the Studio (Mach-O strip-header plug-ins carry the same Bill records; sha256 equal to open-apollo's pins for UAD 12.0.0.602). Extracted to
  `/Volumes/m5pro/bench/apollo/fw-out/` (owner's files, not for any repo).
- Test: `/Volumes/m5pro/bench/requests/apollo-1.md` + `/Volumes/m5pro/bench/apollo/apollo-check.sh`.
