wdt: leave the watchdog armed when the boot-args say m1n1.wdt=keep

Base: integration/aurora c614476 (`omacom/wdt-keep-standalone`). The commit is independent of the T6050 stack. It is also the last branch of the stack, `omacom/wdt-keep` on PR-4 (on #30), with the same commit.

m1n1 disables the SoC watchdog at start. A chainloading stage 1 can arm the watchdog before it starts its stage 2, so that a stage 2 or a kernel that hangs resets the machine and iBoot counts a failed boot. That protection is lost the moment stage 2 runs. On our J716s, a stage 2 that fell back to the proxy sat there until someone pressed the power button. The next start then booted the same stage 2 again, because the PMU boot-error count does not cover a boot that stops in the proxy.

What it does:
- With the exact token `m1n1.wdt=keep` in the boot-args command line, `wdt_disable()` finds the watchdog, leaves the primary and secondary as they are, and logs "Primary WDT left armed (m1n1.wdt=keep)". `wdt_reboot()` works as before.
- Nothing in m1n1 feeds the watchdog. Linux's `apple_wdt` keeps an armed watchdog fed once it probes.
- The token is matched by `boot_option_present()`, like `m1n1-debug` and `m1n1-proxy`. It is honoured in every stage: the stage it matters for is a chainloaded one, and that stage may or may not be built with `ESP_STAGE2`.
- On T8140, the CDC proxy window no longer arms its own 170 s watchdog under the token, because that would replace the earlier stage's deadline. CDC then has nothing of its own to disarm when the host opens the proxy.
- Without the token nothing changes. It is opt-in by construction: only a stage that armed the watchdog and appends the token to the next stage's command line turns it on.
- `docs/boot-options.md` documents it, including why it does not belong in the NVRAM boot-args: there it would leave iBoot's watchdog running.
- `tests/python/test_boot_options.py`: exact-token matching (`m1n1.wdt`, `m1n1.wdt=`, `m1n1.wdt=keeps`, `xm1n1.wdt=keep` and truncated lines are refused), independent of the stage.

Not in this PR: arming the watchdog in omacom's own stage 1. In our chain, our A/B stage 1 does that. It arms 150 s right before the chainload when its config asks for it, appends ` m1n1.wdt=keep`, and disarms again if it drops to the proxy itself. If omacom wants the same for the Omarchy chain, that stage 1 side is a separate change: it needs `wdt_arm_seconds()` opened up beyond T8140 and a fallback slot.

### Testing

MacBook Pro 16-inch, M5 Pro (J716s, Mac17,8), macOS 27.3 beta 1 stub (26C5035r).

**This commit on hardware (2026-11-07):** The full stack on #30 (`omacom/wdt-keep` at 6653bb2, m1n1 `v1.6.1-429-g6653bb2`, before the review fixes) booted the J716s on the first pass, 74 s to SSH behind our A/B stage 1, whose boot-args carried ` m1n1.wdt=keep`. The log showed `Primary WDT left armed (m1n1.wdt=keep)`, then the N1 training, and Linux came up on 18 CPUs with Wi-Fi: pass. The stack on #26 had passed the same way earlier. Since then, the commit only gained the T8140 CDC change above, which does not run on T6050.

Before that, the same check ran in our own stage 2 as a substring match of the same token. Our A/B stage 1 armed the watchdog for 150 s and passed the token on every boot on 2026-11-07. That day:
- Payloads that hung or panicked before `apple_wdt` probed came back unattended on the fallback payload, with the boot-slot marked `fallback-after-failure`: DAILY-NEXT-T1, W3 (a cold start), and the boots of freshly written files that fell back once.
- Every boot that reached Linux kept running with the kernel feeding the watchdog (R3-S: 160 s against the 150 s timeout, and every soak after it).
- The only boot on 2026-11-07 that needed someone at the power button was the one Aurora loader without this check: it disabled the watchdog and parked in the proxy.

This branch:
- Builds with `make` and `make CHAINLOADING=1`, standalone and at the top of the T6050 stack: no new warnings against the base. Sizes are unchanged.
- CI's pytest set (Linux): all pass, including the new test.
- Boot-test payload rebuilt on #30: the full T6050 stack (`omacom/wdt-keep`) with the daily's kernel, DTB and initramfs and `chosen.asahi,t6050-n1=4`, self-test on. With our stage 1's token it keeps the stage 1 watchdog armed, so it is the one payload in this set that can boot unattended.

Questions:
- Is a boot-args token the right channel, or would you rather have a field in the chainload header (`chainload.h`) that only a chainloading m1n1 can set?
