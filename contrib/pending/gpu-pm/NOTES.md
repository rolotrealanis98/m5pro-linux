# gpu.pm: macOS 27.2 InitData power words vs what the kernel sends (J716s, 2026-11-23)

Source of truth: the InitData macOS 27.2 (26B123) built on this J716s, captured under the m1n1 hypervisor on
2026-11-22 (`/Volumes/m5pro/bench/hv27-gpu/runs/20261122-055744-gpu-26B123/capture/initdata-gfx1-asc-send-1/`:
`policy.bin` 0x12728 bytes, `hw_data.bin`, `region_c.bin`). Read at the moment macOS stored the INITDATA word, so it is
macOS's own setting, before the firmware (27.3 stub) touched it. Private data: nothing here is for a PR comment as is.

Kernel compared: `j716s-ane2293` (`0c6bb36ed14a`), the daily's configuration: `aurora.m5_controller_defaults=1`
(J714's controller defaults + this part's leakage, `db578d3d99cc`). Tool: `policy-diff.py` (output `policy-diff.out`).
Without `m5_controller_defaults` the kernel sends no controller configuration at all (firmware default budget).

## Differences (macOS 27.2 on this J716s vs kernel with m5_controller_defaults=1)

Policy (26A428 offsets, 26B123 offsets +0x0 below 0x4910):

| word | kernel | macOS | note |
|---|---|---|---|
| 0xa18, 0xad0, 0x44a4, 0x44a8, 0x44ac, 0x45e4 (u32 mW) | 98884 (0x18244, J714's) | **101692** (0x18d3c) | +2.84 %; region C 0x88 carries the same value (macOS 101692) |
| 0x9f4, 0x45e0 (f32) | 98884.0 (0x47c12200) | **101692.0** (0x47c69e00) | |
| 0xa00 (f32) | -0.013147 (0xbc576554) | **-0.012784** (0xbc5172b9) | per-part coefficient |
| 0x490c | 0 | **20** | J714 defaults do not write it; kext store at 0x490c |
| 0x11288, 0x1128c (f32) | 0 | **25.0** both | |
| 0x12158 (f32) | 0 | **0.0727115** (0x3d94e9c3) | |

HW data:

| field | kernel | macOS |
|---|---|---|
| relative power curve main 0x19e4 (14 values + 2 zero) | J714's (0x4106f651 ...) | **J716s's own** (0x4105dcf0, 0x41411dd1, ... 0x42b6276a, 0x42c80000) |
| relative power curve aux 0x1a64 | J714's (0x4105a0ed ...) | **J716s's own** (0x4102dcc8, 0x414e6839, ... 0x42baf4b6, 0x42c80000) |

Confirmed equal (nothing to change): leakage words (clusters 3732/2 and 3808/2 halves, SRAM 362/2, AFR 992/2: the
decode of `apple,leakage-calibration-words` by #2080 matches what macOS computes on this part, word for word);
every other J714 default word in the policy; the 26B123 controller words (0x492c = 5000, 0x4a14 = 1600); sample
period 0x4/0x8 (200000), pstate scale 0x3f828f5c, perf-state frequencies, both voltage tables (all 14 states, core and
SRAM, lanes 0/1), aux perf states, relative-frequency curve 0x1a24/0x1aa4 (J716s base pstate 1), region C
0x8c/0x90/0x9c/0x7c8 (idle standby 1500 us)/0x1c30 and the utilisation tunables, pstate count 13.

Not comparable from this capture: the 26C5035r (27.3) pause timeout word (0x271c is the fixed word 0x96 in the 27.2
layout), the firmware-written words (changed between send and ack: status A/B, status config).

No power-gating or idle-timer word differs: idle standby 1500 us, pause timeout as is, and policy bands are the same.
So the only real "tuning" the trace supports is the maximum power (+2.84 %) and the two curves; expect a small effect
(a few percent of top-state headroom under a sustained load, and a slightly different efficiency model for the
performance controllers). Expected idle effect: none (idle is the 2 ms firmware power-off, cores_powered false).

## What the kernel branch does (`j716s-gpu-pm`, worktree `/Volumes/m5pro/wt/gpu-pm`, from `j716s-ane2293`)

- `f74c7a488eaf` `aurora.m5_j716s_observed=1` (boot param, default 0): with `m5_controller_defaults=1` on a J716s also
  writes the words in the tables above (`set_m5_policy_j716s_observed`, g17/fw/m5/initdata.rs). Region C's maximum
  follows from the policy word (existing code). Off by default; with 0 the kernel sends exactly what the daily sends.
- `d3df838aeb3d` debugfs `aurora-g17/power` gets a `policy_residency` line: the firmware's per-state residency table of
  the policy (26B123 offset 0x12320, 40 entries of 24 bytes) printed raw for the entries that are not all zero. The
  table is firmware-written ({acc, count, last} by the kext/firmware analysis, not observed): we publish the words
  unscaled and learn on the first loaded boot what they count (a pstate residency would be the first view of the clock).

## What the driver exposes today (no kernel change needed)

| what | where | on the J716s |
|---|---|---|
| GPU core power gate | debugfs `/sys/kernel/debug/aurora-g17/power`: `core_power`, `cores_powered`, `host_hold`, `idle_hold_ms` | works; idle = gated (`cores_powered=false`) |
| firmware GPU power, budget, limiter | same file, last line: `gpu_power_mw`, `power_budget_mw`, `limiter_mask/limit`, `effort_published`, `busy_permille` | works (gpu-gov `2d4636b310e4`); only GPU-power reading |
| pstate / frequency | sysfs `agx_stats` `pstate`, `achieved_frequency_hz` | `unsupported` on 27.3 firmware (no 0x1b record); `reports` debugfs shows raw tags 0x19/0x1a/0x20 |
| busy time | `agx_stats` `busy_ns`, fdinfo `drm-engine-*` | `busy_ns` stays 0 under frame-paced load until #1879 (open); fdinfo and `busy_permille` work |
| CLPC floors | debugfs `*performance-controller*/status`, module `clpc.gpu_floor`, `gpu_busy_floor` | works |
| idle delay | sysfs `idle_off_delay_ms` | M5 takes no host hold: no effect (gpu-power-2) |
| light effort | sysfs `light_effort`, param `aurora.m5_light_effort` | works, off |
| firmware power-policy residency table | debugfs `power` line `policy_residency` | NEW in this branch, raw |
| hardware perf counters (perfmon, Instruments-style) | nothing in the tree | **missing**: no counter ring is decoded or exposed; needs a macOS capture of the counter setup (hypervisor trace of AGXPerfCounters), not derivable. Not attempted |
| devfreq / energy model / cooling | none | firmware owns the clock; not planned (gpu-power-1) |

Upstream, read-only: #1173 (27.2/27.3 InitData, open, this capture is its evidence), #1666 (PMP effort to G17 power
ceiling, T8140 only: effort reads 0 under load, J716s has no PMP running), #1879 (busy time across power gates, open).

## Measurement

`gpu-pm-measure.py` (this folder): `python3 -I gpu-pm-measure.py LABEL OUTDIR --idle 90 --loads paced-finish:40,paced-heavy:40,glmark-terrain:60 --bench`
Run as root on the Mac. Reads PSTR/heatpipe (hwmon), the debugfs power line, agx_stats, CLPC; per phase TSV +
summary. Idle GPU power = PSTR of the idle phase next to the GPU power-gate duty; there is no GPU-only rail sensor.
Uses `/home/rolo/gpu-ab/power2/load.sh` and `/opt/gpubench` if present (both left there by gpu-power-2).

Request: `/Volumes/m5pro/bench/requests/gpu-pm-1.md`.

## Build and files (2026-11-23)

Branch `j716s-gpu-pm` (local, not pushed; author rolotrealanis98 noreply, Signed-off-by, no Claude trailers): `f74c7a488eaf`, `d3df838aeb3d`
on `j716s-ane2293` `0c6bb36ed14a`. `build-next.sh` (lockf) -> BUILD OK `7.3.0-gd3df838aeb3d`, modules-missing empty, same warning count
as ane2293, DTB identical. Folder `/Volumes/m5pro/bench/pr-verify/kbuild-gpu-pm/`. Test files `gpupm-observed-20261123-bee892d1.bin`
(param on) and `gpupm-control-20261123-e69fd137.bin` (param off) in `/Volumes/m5pro/bench/pr-verify/`. Request `gpu-pm-1.md`, runbook `gpupm-runbook.sh`.
Not booted, not run on hardware. Perf counters not started (needs a hypervisor capture of macOS's counter setup).
