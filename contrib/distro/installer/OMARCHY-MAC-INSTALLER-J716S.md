# omarchy-mac-installer: J716s branch (dist.installer)

Written 2026-11-23. Nothing pushed, no GitHub writes. Clone: `/Volumes/m5pro/wt/omarchy-mac-installer-j716s`
(upstream `omacom/omarchy-mac-installer` main `e0aa53f`), branch `j716s-support`. The full write-up
(what each piece does, the qualification checklist, the dependencies on linux-aurora #404/#413 and
omacom/m1n1 #30-#37, the open questions) is `docs/j716s-qualification.md` in that clone.

## How the upstream installer is built (what the ledger row meant)

It is not one catalog file. The pieces are: `Engine/patches/0001-omarchy-engine-runtime.patch`
(the asahi-installer tables `CHIP_MIN_VER`, `DEVICES`, `IPSW_VERSIONS`), the Python overlay
`Engine/overlay/src/omarchy_asahi.py` (`BOARD_STAGE1`, `BOARD_STAGE2`, firmware collectors),
`scripts/supported-models.json` (the `developer` class) and `MacModelNames.swift`. By chip, every
T6040+ Mac already goes to aura's Mach-O Stage 1 (PR #238, `omarchy_chip.uses_execute_window`, T6050
is in the range). The J716s must not: its qualified object is the raw A/B m1n1, so it is a
`BOARD_STAGE1` board, which skips the chip rule.

## What the branch has

- Tables: T6050 minimum 27.3, `j716sap`, an `IPSW("27.3", min_iboot mBoot-20457.60.65.0.1)` row whose URL is unpinned.
- `omarchy_m1n1_ab.py`: the A/B Stage 1 (port of `mk-stage1.py`); byte-identical to it on `bench/picker-entry/s1build/out/m1n1-chain-ab.bin`.
- `BOARD_STAGE1` / `BOARD_STAGE2` entries, second Stage 2 slot (`boot.bin.prev`) seeded at install.
- `omarchy_n1.py`: the N1 FTAB stitch (port of `mk-ftab-w3.py`), `omarchy_als.py`: the `als` subtree search.
- `Development/simulate-j716s.py`: dry run of the flow, no disk, no process.
- Tests: 40 new engine tests, all engine and script suites green except one failure that predates the branch (see the report).

## Not done

Image builder staging (`stage1-j716s.bin`, `boot-j716s.bin`, `27.3` in `supported_fw`), engine rebuild
(lock digests and name are updated, `validation_artifact` is not), the 27.3 restore image URL and
range recipe, the Swift simulator scenario, anything on hardware.
