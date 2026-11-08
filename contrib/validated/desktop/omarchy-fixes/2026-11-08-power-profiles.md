# Power profiles fail at the CPU boost interface (2026-11-08)

Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/43. Kernel: `7.3.0-g0933f881d736`

## What broke

The user reports that the Omarchy status-bar power saver, balanced and performance choices do not produce the expected response.

## Cause

The running `omarchy-power-profiles-daemon 0.30-3` advertises all three profiles, reports balanced, but logged on startup:

```
Failed to activate initial profile: Failed to activate CPU driver 'cpufreq': Error writing '/sys/devices/system/cpu/cpufreq/boost': Invalid argument
```

This proves initial profile activation failed at the kernel boost interface. The exact kernel reason and whether every subsequent profile transition fails remain untested. A reported active profile does not establish successful hardware configuration.

All three policies use `apple-cpufreq` and `schedutil`, with minimum 300000 kHz and maximum 4380000 / 4380000 / 4608000 kHz for policies 0 / 6 / 12. Global boost reads 0. Each policy exposes boost and scaling_boost_frequencies, but all three scaling_boost_frequencies files are empty. Available governors are ondemand, userspace, performance and schedutil. No ACPI platform_profile interface exists; the daemon advertises a placeholder platform driver for balanced/saver. These observations suggest a boost-interface integration mismatch, not a proven specific kernel defect.

## Fix

Diagnosis only. No runtime power changes, package installation, service restart, kernel or desktop changes. The protected kernel workflow belongs to the Studio session. Next: inspect the running kernel's boost table/implementation and daemon cpufreq backend, then test transitions with readback under the owner-coordinated workflow.

Read-only commands: uname -r; powerprofilesctl list/get; systemctl status power-profiles-daemon; busctl get-property for Profiles; journalctl -b -u power-profiles-daemon; pacman -Q power-profiles-daemon; reads of cpufreq policy attributes. Read the packaged panel and omarchy-powerprofiles-set/list scripts. The panel invokes the setter; the setter calls powerprofilesctl and exits on error before saving a new preference.

Sandboxed system-bus reads initially failed with Operation not permitted; approved read-only execution succeeded. Initial repository pulls failed DNS inside the sandbox; approved pulls succeeded. GitHub connector issue creation returned integration permission 403; CLI fallback used.

## Files changed

Only this diagnostic report. No installed files changed.

## Verified

Daemon startup failure, advertised profiles and current cpufreq state directly observed. Studio busy marker absent at preflight. No profile switching or power/performance benchmark performed. No feature status matrix changed. Battery-life impact and the exact reason for boost EINVAL are unverified.

## Rollback

No runtime changes to undo. Revert the report commit to remove this documentation.
