mfd: macsmc: Match the T6050 SMC

> [Note for Rolando, delete before sending] Send only if PR #941 (j716c/t6050-smc) / the j716c/t6050-platform branch is far off. #941 adds the
> same `const: apple,t6050-smc` binding entry and the driver match with a T6050 cell list. If #941 is
> moving, offer a J716s Tested-by there instead and drop this.

`apple,t6050-smc` is matched by no driver on `integration/aurora`, so a T6050 board has no RTC, power button, lid, reboot or SMC GPIOs. This adds the match on the generic path, which the J716s ran through an `apple,t8103-smc` DT fallback before. #941 matches the same string and will replace this; the binding entry has the same shape, so the later merge is trivial.

**Tested on:** J716s, R3-SERIES (2026-11-07): macsmc bound through this native match, no fallback in the DT; the SMC GPIOs work (trackpad AFE reset on gp1c). R3-S (same kernel and DT): power/lid input device, reboot/poweroff via SMC, battery and AC supplies (Full, 100 %, 33 cycles, no probe hang). `drivers/mfd/macsmc.o` builds clean with `W=1` on `integration/aurora` 7aee01a89865.

**Dependencies:** none; superseded by #941.

**Open questions:**
- Is #941 expected soon, or is a minimal match wanted on `integration/aurora` in the meantime?
- Binding and driver in one commit (checkpatch asks for a split); split if wanted.
