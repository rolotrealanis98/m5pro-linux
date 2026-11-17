# power-profiles

Scope: generic (any Apple Silicon Mac on Omarchy whose kernel has no writable cpufreq boost switch, and every
devicetree Mac with the CLPC platform profile). Status: installed on the J716s 2026-11-17.

## Root cause

Omarchy's stable repository ships `omarchy-power-profiles-daemon 0.30-3` (built 2026-10-14). On the J716s it probes no
CPU driver and no platform driver, so the placeholder takes over: `powerprofilesctl` shows only balanced and
power-saver with `PlatformDriver: placeholder`, `performance` is missing, and power-saver changes nothing.

- **CPU driver.** 0.30-3's `cpufreq` driver maps `apple-cpufreq` to its boost method only, and that method needs a
  writable `/sys/devices/system/cpu/cpufreq/boost`. The J716s kernels since next6b (`j716s-cpufreq-noboost`,
  c8b41c8e197e) offer no boost switch at all, because the T6050 tables have no turbo OPPs, so the probe fails. The
  older kernels had the switch but refused every write (EINVAL), which is the 2026-11-08 failure.
- **Platform driver.** 0.30-3 reads only `/sys/firmware/acpi/platform_profile`. The kernel already has a platform
  profile, `apple-clpc` (`drivers/soc/apple/clpc.c`, aurora-silicon bdd3bc3f17b4), registered through the
  platform-profile class at `/sys/class/platform-profile/platform-profile-0` with low-power / balanced / performance
  after macOS's power modes. On a devicetree machine there is no ACPI file, so 0.30-3 never sees it.

omacom/omarchy-pkgs master already fixes both: pkgrel 5 `cpufreq-apple-no-boost.patch` (#2078, the M3 Max case: cap
power-saver when there are no boost frequencies) and pkgrel 8 `platform-profile-class.patch` (#2381, the class
interface without ACPI). Omarchy builds pkgrel 9 for aarch64 on its **edge** channel; stable and rc still carry 0.30-3.
No kernel change is needed.

## What 0.30-9 does on the J716s (verified 2026-11-17, kernel 7.3.0-gcee93f953357)

| Profile | CpuDriver `cpufreq` | PlatformDriver `platform_profile` (apple-clpc) | scaling_max_freq policy0/6/12 | governor |
|---|---|---|---|---|
| power-saver | caps every policy at 60 % of its top, nearest table step | `low-power`: ceilings 2964/2964/2880 MHz plus the 15 W package target (SMC PHPC, read every 100 ms) | 2652000 / 2652000 / 2880000 | schedutil |
| balanced | uncapped | `balanced`: no limit | 4380000 / 4380000 / 4608000 | schedutil |
| performance | uncapped | `performance`: no limit (High Power mode to the SMC only with the j716s-power1 kernel) | 4380000 / 4380000 / 4608000 | performance |

`powerprofilesctl` lists all three with `CpuDriver: cpufreq` and `PlatformDriver: platform_profile`; switching back to
balanced restores the full range. The performance governor holds every core at its top clock, idle ones included, so
performance costs idle power (measured in `/Volumes/m5pro/bench/requests/power-1.md`).
`omarchy-powerprofiles-set` picks performance on AC when the user has saved no AC choice; this Mac has `balanced`
saved in `~/.local/state/omarchy/powerprofiles/ac`.

## Install / undo

- Install: `sudo bash install.sh` (downloads 0.30-9 from `pkgs.omarchy.org/edge/aarch64`, checks the sha256 from the
  edge database and Omarchy's signature, `pacman -U`, restarts power-profiles-daemon).
- Undo: `sudo bash install.sh --remove` (reinstalls the cached 0.30-3 and restarts the daemon).
- pacman keeps 0.30-9 over the stable 0.30-3; once stable publishes pkgrel 9 or later, a normal update takes over.

## Upstream

Omarchy itself (omacom/omarchy-pkgs): promote `omarchy-power-profiles-daemon` 0.30-9 from edge to stable for aarch64.
Nothing to change in the patches.
