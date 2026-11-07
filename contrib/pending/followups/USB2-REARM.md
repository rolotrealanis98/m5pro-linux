# edimoldovan 4f8b07f31d66, "re-arm USB 2.0-only ports after their device left" (finding 2)

Verdict: not needed on the J716s, and it cannot be applied. No patch (`patches/0002-*` intentionally absent).

## 1. Does it apply

No. `git cherry-pick -n 4f8b07f31d66` in a scratch worktree at `dd6b39464ca9`
(`/Volumes/linux-cs/wt-j714s-scratch`; `wt-series` untouched) stops with
`CONFLICT (modify/delete): drivers/phy/apple/t6050-usb2.c deleted in HEAD`. The file does not exist in our tree:
his patch modifies a separate USB 2.0 host PHY driver, `t6050-usb2.c`, that he added in `ae65f0d3a88e`
("phy: apple: add a T6050 USB 2.0 host PHY and use it on J714c"), which is only on his `t6050-j714c`. It builds on
a second commit he names (`dccfab72274b`, Type-C controllers of ports 0 and 2) and on `XHCI_PORTSC*` accesses
into the controller through his own PHY's `p->core` mapping. Taking it would mean taking `ae65f0d3a88e` and its DT,
a second PHY driver for hardware our combo PHY already drives.

## 2. What our tree carries instead

The J716s uses Aurora's T6050 combo PHY, `drivers/phy/apple/atc-t6050-dp.c` (+ `atc-t6050-combo.h`,
`usb-t6050/*.h`), driven by the SN201202x PD controller's Type-C mux events and the `apple,t6050-dwc3` glue:

| Series patch | What | Replug relevance |
|---|---|---|
| 0018 (Dj) | the combo PHY: DP + USB, Type-C mux and orientation switch | the state machine below |
| 0020 | hold the USB domain for the USB2 banks | the USB2 PHY registers are unclocked without the USB domain |
| 0023, 0024 | dummy PIPE PHY for the USB3 lock; stay on USB2 when the PIPE never left the dummy | USB2 keeps working when USB3 does not come up |
| 0025 | accept every Type-C port but the debug port (ATC0) | ATC1 and ATC2 are served; ATC0 is not |
| 0026, 0027, 0028 (Erik Bourget, `j716c/thunderbolt`) | park the PIPE from a dummy producer on any clock; carry on when the PIPE lock is not acknowledged; restart the PHY firmware on its original data | 0028 is the fix for "any second start: an unplug and replug, a role change, or suspend" (`contrib/validated/aurora/pipe-park/ANALYSIS-R3O.md`) |
| m1n1 0020 | `pipepark-atc`: park the PIPE before Linux | first start |
| 0057, 0060 | hpm1 (ATC1) and hpm2 (ATC2) nodes, polled, connector graph into dwc3 and the PHY | attach and detach events reach the PHY |

Mechanism, from `atc-t6050-combo.h`:

- Cable gone: tipd (`tipd/core.c`: the SN201202x data uses `cd321x_interrupt()`, which ends in `cd321x_update_work()`;
  the hpm nodes have no `interrupts`, so `tps6598x_poll_work()` calls it every 500 ms) drops the USB role to NONE, unregisters the partner and puts the mux
  in `TYPEC_STATE_SAFE` ("If there was a disconnection, set PHY to off"). `combo_mux()` then runs `combo_stop()`:
  quiesce, `apple_t6050_usb2_stop()`, power domains off, `usb2_active = false`.
- Cable back: orientation, then `TYPEC_STATE_USB` (or a DP alt mode). `combo_start()` powers the domains and runs the
  complete `apple_t6050_usb2_host[]` sequence again: the USB2PHY default and host tunables, reset, run, host bits,
  signal settings; then the USB3 init. This is the same work as his re-arm (reset, tunes, run, host bits), done on every
  attach, driven by the Type-C event rather than a timer.
- `combo_usb2_reset()` and the dwc3 role switch cover port reset and controller role.

His port needed the timer because his PHY runs that sequence once, at the host flip, and nothing in his driver reacts
to the cable leaving: the Type-C controller sees the replug, the PHY never leaves its stale state.

## 3. Evidence that replug works here

- Before the series: R2-B failed ("after an unplug nothing re-enumerates ... nothing in Linux re-arms the port";
  `RESULTS.md`, no PD controller driver or node then).
- Series kernel, today (your report): a hub replugged in the left port re-enumerated, and the right port enumerated a
  hot plug. Both ports run through the path in section 2.
- The delay on the left port (about 70 s, exact timing unknown, with Tailscale path churn around it): nothing on the PHY
  path takes that long by code reading. tipd polls every 500 ms; the PHY start is tens of ms of register work. To
  pin it down, on the next replug keep `journalctl -k -o short-monotonic` and compare the `sn201202x`/`atc`
  Type-C lines with the xhci `new ... device` line; if they are seconds apart, the 70 s was the network, not USB.

## 4. Why adopting it would be wrong here

- On an empty port our PHY is in SAFE: domains off, USB2 banks unclocked (the comment in `combo_start()` says so).
  A timer writing `USB2PHY_CTL` every 3 s would hit unclocked registers, with the SError risk the series already
  designs around (pin 112, the pipehandler bank read only while the controller holds its domain).
- It would take no `dp->lock` and would race `combo_start()`/`combo_stop()`.
- ATC0 (left-back, the tether) is a gadget on the loader's PHY state with no Linux PHY: the patch has nothing to act on.

## 5. Remaining gap (not his patch)

`combo_usb2_mode()` and `combo_usb3_mode()` return -ENOLINK without USB prepared, and `dp->faulted` is sticky: one
failed start disables the port until reboot. If a replug ever fails on our side, the thing to capture is the
`start of mode N failed` / `stop failed` line, not a missing re-arm.
