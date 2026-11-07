HID: dockchannel-hid: settle 50 ms after releasing the AFE reset

With power method 2 and a host-driven AFE reset the driver releases the line and sends HasChanged at once. On the J716s (MacBook Pro 16-inch, M5 Pro; MTP firmware 6320.86.1; reset on SMC gp1c, active low) the trackpad only came up reliably with a 50 ms settle after the release, which the driver already waits for a firmware-managed reset. This adds the same wait to the host-driven path.

It also logs assert and release at info level (and a failure to drive the line as an error), so a boot log shows whether the reset ran at all.

**Tested on:** J716s: "Touch MT ready" on 3 of 3 boots when introduced (round R3-R), and on every boot since; R3-SERIES and R3-S (2026-11-07): "Touch MT ready" at 1.34 s, multi-touch working. `dockchannel-hid.o` builds clean with `W=1` on `integration/aurora` 7aee01a89865.

**Dependencies:** none to build. Applies on its own and on top of #491. On hardware the J716s reset line is the SMC's second GPIO bank (described in the J716s DT PR).

**Reviewers:** authors of 6a411d0d1495 (power method 2) and 3661ab4c3fad (firmware-managed M5 trackpad power).

**Open questions:**
- Are the two info-level lines acceptable, or should they be `dev_dbg`?
- Is 50 ms right for other host-driven boards, or should the settle time come from the DT?

**v2 (2026-11-07, after RyanTheTide's pre-review):** commit 00768a757b56 (was 227703b63d84). The assert/release message is `dev_dbg` instead of `dev_info`; a failure to drive the line stays `dev_err`. Nothing else changed. `dockchannel-hid.o` builds clean with W=1, and checkpatch --strict is clean. Patch: `patches-v2/dockchannel-afe-settle/`.
