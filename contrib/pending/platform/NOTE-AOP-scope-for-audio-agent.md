# AOP scope note (platform agent -> audio agent), 2026-11-04

Split: audio agent documents the AOP microphone path; platform agent owns the
ambient light sensor (ALS) and lid-angle sensor (LAS). Neither ships an AOP DT
node yet. Shared facts from the J716s ADT (hardware-description properties only):

- /arm-io/aop: "iop,ascwrap-v6", AIC interrupts 578-581, function-pll_off_mode;
  child iop-aop-nub "iop-nub,rtbuddy-v2", firmware-name "mac17jaop",
  pre-loaded 1, no-shutdown 1, firmware-type "scrt".
- iop-aop-nub has `routes` = phandle of /arm-io/aop-exclave-mailbox
  ("iop,secure-rtbuddy-proxy", exclave-service com.apple.service.SecureRTBuddyAOP,
  role AOP-EXCLAVE). dart-aop has an exclave-sid list and a mapper-exclave-aop.
  i.e. on this generation part of AOP is owned by an exclave (absent on M1-M3).
- iop-aop-nub children: aop-audio, aop-voicetrigger, als, aop-gapf-filters,
  aop-pio-filters, aop-scm-xbar, accel, gyro. `als` carries only
  device_type "als" + harmony-db-version 3 (no calibration in the ADT; Asahi
  takes it from macOS ioreg CalibrationData -> apple/aop-als-cal.bin).
- Linux side: drivers/soc/apple/aop.rs + iio aop_als.rs/aop_las.rs and
  sound/soc/apple aop audio are Rust (CONFIG_RUST is off in the current
  macOS-hosted build); aop.rs knows t8103/t8112/t6000/t6020 only, rewrites the
  AOP bootargs in AOP SRAM and sets ASC CPU_RUN at probe.

Whoever brings AOP up first owns the aop core node; the other only adds a child.
Platform agent will not touch the AOP until the exclave question below is
answered: does the non-secure AP still own the AOP RTKit endpoints for audio/ALS
on T6050, or are they reachable only through SecureRTBuddyAOP?
