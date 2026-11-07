## Kernel compile check: pass

Range `a873be047e9a..a0e28f1c1ab6`, 9 commit(s), per-commit on.

| state | commit | objects | recompiled | prepare cmds | W=1 warnings | errors | compile s |
|---|---|---|---|---|---|---|---|
| base | `a873be047e9a` | 4 | 4 | 122 | 0 | 0 | 3.21 |
| commit-1 | `94c120b60a86` | 4 | 1 | 2 | 0 | 0 | 3.13 |
| commit-2 | `e3790e581d90` | 4 | 0 | 2 | 0 | 0 | 1.79 |
| commit-3 | `83df1e683979` | 4 | 1 | 2 | 0 | 0 | 2.67 |
| commit-4 | `54095153716a` | 4 | 1 | 2 | 0 | 0 | 2.59 |
| commit-5 | `d47001a3a7ff` | 4 | 0 | 2 | 0 | 0 | 1.83 |
| commit-6 | `bdca4904925f` | 4 | 3 | 2 | 0 | 0 | 3.09 |
| commit-7 | `02f083465e8a` | 4 | 1 | 2 | 0 | 0 | 3.37 |
| commit-8 | `4ecc1e3a870e` | 4 | 1 | 2 | 0 | 0 | 2.75 |
| commit-9 | `a0e28f1c1ab6` | 4 | 1 | 2 | 0 | 0 | 2.22 |

### New W=1 warnings: 0


Pre-existing W=1 warnings at HEAD (same as merge base): 0

### Changed headers

| header | includers found | selected by config | use changed identifiers | compiled |
|---|---|---|---|---|
| `include/linux/soc/apple/dart.h` | 3 | 3 | 3 | 3 |

Wall time (s): checkout 19.53, config 2.85, prepare_and_list 22.52, include_index 0.06, compile 26.65, total 82.6

CPU time of child processes (s): checkout 8.97, config 2.98, prepare_and_list 23.65, include_index 0.02, compile 23.78, total 65.7
