hwmon: (macsmc) keep a fan whose optional keys are missing

`macsmc_hwmon_create_fan()` drops the whole fan when any of `apple,fan-minimum`/`-maximum`/`-target`/`-mode` names a key the SMC does not have. The T6050 SMC spells the mode key `F0md`, not `F0Md`, so a fan description shared with older machines loses both fans. This keeps the fan, warns, drops that attribute, and allows manual control only when mode, target, minimum and maximum all exist. The `apple,fan-manual-control` check is unchanged.

**Tested on:** J716s, HWMON-T1 (2026-11-07): the series kernel with a DT that enables `smc_hwmon` with dual fans (`apple,fan-mode = "F0md"`/`"F1md"`). `macsmc_hwmon` registers; both fans are listed with min 1350 and max 5349/5777 rpm (0 rpm, fans off at 28 C), plus 60+ discovered temperature channels and the power keys. No probe warning, so every key that DT names exists; the missing-key path itself has not run on hardware. Fan control not tried (the T6050 SMC has no `Ftst` unlock key). `macsmc-hwmon.o` builds clean with `W=1` on `integration/aurora` 7aee01a89865.

**Dependencies:** none. Applies on its own and on top of #941 (T6050 SMC sensors), which touches the same file elsewhere.

**Open questions:**
- Is describing the T6050 mode key in the DT (`apple,fan-mode = "F0md"`, as tested) the preferred way, or should the driver try both spellings?
- Warning level: `dev_warn` once per missing key, or `dev_info`?
