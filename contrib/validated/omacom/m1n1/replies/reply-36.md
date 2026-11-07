Thanks. Of the two findings:

- `src/wdt.c:39` (on T8140, CDC replaces the inherited deadline): fixed. Under `m1n1.wdt=keep`, `usb_cdc_arm_watchdog()` no longer arms its own 170 s watchdog. The earlier stage's deadline stands, and CDC has nothing of its own to disarm when the host opens the proxy. `docs/boot-options.md` says so. The fix is in this PR's commit, and the standalone branch has the same commit.
- `src/smc.c:73` (notifications restart the command timeout): that is N1 code from #34, visible here because this branch sits on top of the stack. It is fixed there: each SMC command, and the initialisation, has one 2 s deadline from the moment it is sent.
