reset: apple-cio: Add the T6050 reconfiguration register

> [Note for Rolando, delete before sending] HOLD - do not send as is. PR #946 (j716c/thunderbolt, commit 35c0d1d6bc96) already adds
> `apple,t6050-cio-reset` with the same 0x60 offset and a hardware-checked sequence: on T6050 the odd
> bit is a done flag, and request + done must both clear before the CPU wrapper is touched (an early
> access takes an SError). This patch treats the odd bit as busy and can return too early. Preferred
> route: drop this PR, comment on #946 that the J716s die0 node binds with its entry. Body kept below
> in case #946 is split and the minimal part is wanted.

`t6050-die0.dtsi` uses `apple,t6050-cio-reset`, which no driver on `integration/aurora` matches. T6050 has the T8142 bit layout at offset 0x60 of its page instead of 0x30. This makes the register offset part of the variant and adds the T6050 entry. A T8142 fallback in a DT would hit the register at 0x30.

**Tested on:** J716s, R3-SERIES and R3-S (2026-11-07): the driver binds through its own T6050 entry (no T8142 fallback in the DT). No deassert has been issued: the only consumer (`usb4_3_acio`) is disabled on every T6050 board. `drivers/reset/reset-apple-cio.o` builds clean with `W=1` on `integration/aurora` 7aee01a89865.

**Dependencies:** none; overlaps #946.

**Open questions:**
- Would you take the offset-in-variant part separately from #946's T6050 deassert sequence?
- The binding and driver are in one commit (checkpatch asks for a split); split if wanted.
