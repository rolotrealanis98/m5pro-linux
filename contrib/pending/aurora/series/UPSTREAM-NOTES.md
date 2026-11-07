# Upstreaming our J716s fixes to aurora-silicon/linux

One section per patch of ours in `patches/series/` (0045-0058). Aurora policy: disclose LLM use per
commit. Every one of these commits carries `Assisted-by: LLM` (the kernel's own format,
`Documentation/process/coding-assistants.rst`) and a `Co-Authored-By: Claude ...` line; the PR text below
repeats the disclosure. None has a `Signed-off-by`: the person submitting adds it (`git commit -s --amend`,
or `git am -s` / `git format-patch --signoff`), which certifies the DCO for them; an assistant must not.
0049 is Dj's (with Erik's sign-off) and is listed only so its route is clear.

Base for every PR: `integration/aurora` (`33bec4016c46` here). Where a patch depends on an open PR,
the PR says so.

---

## 0045 soc: apple: rtkit: wait up to 10 s for a handshake reply

- Target: `integration/aurora`, alone; or offered to the PR #936 author (Jeff Queisser) as a prerequisite,
  since it is the T6050 ANS that needs it.
- Title: `soc: apple: rtkit: wait up to 10 s for a handshake reply`
- Text:

  > On the J716s (M5 Pro) the ANS firmware iBoot hands over sometimes takes ~3 s to answer the power-state
  > and endpoint-map handshake, so with PR #936 nvme-apple fails with "ANS did not boot" / "Reset failure
  > status: -62" and there is no root device; a later rebind works. This raises
  > `apple_rtkit_wait_for_completion()`'s timeout from 1 s to 10 s. A co-processor that answers in time is
  > not slowed down.
  >
  > Tested on J716s (in every payload since R3-J). LLM use: the patch and this text were written
  > with an LLM assistant (Claude); `Assisted-by: LLM` is in the commit.

- Expect: a request to make the timeout per-endpoint or per-SoC instead of global. Fallback version: a
  `timeout_ms` in `struct apple_rtkit_ops` or a DT property on the ANS, default 1000.

## 0046 HID: dockchannel-hid: settle 50 ms after releasing the AFE reset

- Target: `integration/aurora`; reviewers: the authors of `6a411d0d1495` (power method 2, Ryan Murray) and
  `3661ab4c3fad` (firmware-managed M5 trackpad power, Acelogic).
- Title: `HID: dockchannel-hid: settle 50 ms after releasing the AFE reset`
- Text:

  > With power method 2 and a host-driven AFE reset the driver releases the line and sends HasChanged at
  > once. On the J716s (MTP firmware 6320.86.1, reset on SMC gp1c, active low) the trackpad only came up
  > reliably with a 50 ms settle after the release, which the driver already waits for a
  > firmware-managed reset ("Touch MT ready" on 3 of 3 boots with it). It also logs assert and release at
  > info level so a boot log shows whether the reset ran.
  >
  > LLM use: written with an LLM assistant (Claude); `Assisted-by: LLM` in the commit.

- Possible pushback: the two info-level lines. Offer `dev_dbg` for them if asked.

## 0047 hwmon: (macsmc) keep a fan whose optional keys are missing

- Target: `integration/aurora` (macsmc-hwmon). Upstream Asahi has the same problem; our m5pro-linux 0003 is
  the original.
- Title: `hwmon: (macsmc) keep a fan whose optional keys are missing`
- Text:

  > `macsmc_hwmon_create_fan()` drops the whole fan when any of fan-minimum/-maximum/-target/-mode names a
  > key the SMC lacks. The T6050 SMC spells the mode key `F0md`, not `F0Md`, so a shared fan description
  > loses both fans. This keeps the fan, warns, drops the attribute, and allows manual control only when
  > mode, target, min and max all exist (the `apple,fan-manual-control` check is unchanged).
  >
  > Not exercised on the J716s yet: its DT keeps `smc_hwmon` disabled until the fan keys are checked
  > there. LLM use: written with an LLM assistant (Claude); `Assisted-by: LLM` in the commit.

- Follow-up for us: enable `smc_hwmon` on J716s with `apple,fan-mode = "F0md"/"F1md"` once the keys are
  read on the machine.

## 0048 power: supply: macsmc-power: initialise work items before the notifier

- Target: `integration/aurora`. It is a plain race fix, so it is also a candidate for upstream Asahi.
- Title: `power: supply: macsmc-power: initialise work items before the notifier`
- Text:

  > Probe initialises `critical_work` twice (before `devm_work_autocancel()`, which does it itself, and
  > again with `dbg_log_work` after `blocking_notifier_chain_register()`). An SMC critical-battery event
  > between the two would see its queued work re-initialised. This initialises both before the notifier
  > is registered and drops the later INIT_WORK()/INIT_DELAYED_WORK().
  >
  > LLM use: written with an LLM assistant (Claude); `Assisted-by: LLM` in the commit.

- Note: the J716s still boots with `initcall_blacklist=macsmc_power_driver_init`; the R3-S test (battery
  driver on, 0048 + 0049) is what will show whether the 7.8 s probe hang is gone. Say so in the PR if it
  has not run by then.

## 0049 power: supply: macsmc-power: read battery identity strings at their key size (Dj)

- Not ours to send. It is the macsmc-power part of Aurora's `54b12371013e` ("mfd: macsmc: Support T6050
  power and pcIO consumers", branch `j716c/t6050-platform`). Drop it from the series when that commit
  reaches `integration/aurora`; until then, ask Dj or Erik whether they want the macsmc-power part split
  out as its own PR (it applies unchanged to integration).

## 0050 drm/sysfb: simpledrm: report an eDP connector for an Apple built-in panel

- Origin: edimoldovan/linux-aurora `9dee12b1266c`, tested by him on J714c; ours is a re-application.
  Coordinate with him: either he opens the PR and we add a `Tested-by` for J716s, or we open it with
  his authorship credited (`Co-developed-by` needs his `Signed-off-by`, so ask him first).
- Target: `integration/aurora`.
- Missing for upstream: a dt-bindings change documenting `apple,internal-panel` on
  `apple,simple-framebuffer` (`display/simple-framebuffer.yaml`). Not in this series.
- Text:

  > simpledrm registers its connector as Unknown. Desktop sessions decide lid behaviour and the notch
  > layout from the connector type (Hyprland/Omarchy only lock and suspend on lid close with an internal
  > connector). With `apple,internal-panel` on the framebuffer node simpledrm registers an eDP connector;
  > without it nothing changes.
  >
  > LLM use: re-applied and the message edited with an LLM assistant (Claude); `Assisted-by: LLM` in the
  > commit.

## 0051 reset: apple-cio: Add the T6050 reconfiguration register

- Target: `integration/aurora`; reviewer: whoever owns `reset-apple-cio.c` (its header already lists T6050).
- Title: `reset: apple-cio: Add the T6050 reconfiguration register`
- Text:

  > `t6050-die0.dtsi` uses `apple,t6050-cio-reset`, which no driver matches. T6050 has the T8142 bit
  > layout (request BIT(2n), busy BIT(2n+1)) at offset 0x60 of the page instead of 0x30. This makes the
  > register offset part of the variant and adds the T6050 entry. A T8142 fallback in a DT (what we used
  > on J716s so far) would hit the register at 0x30.
  >
  > Not built or run with this change yet, and no consumer of the reset (usb4_3_acio) is enabled on any
  > T6050 board, so the offset is from the ADT/PMGR analysis in this file's header and the die0 comment,
  > not from a request seen to complete. LLM use: written with an LLM assistant (Claude);
  > `Assisted-by: LLM` in the commit.

- Before sending: build it (`make drivers/reset/reset-apple-cio.o`) and, when USB4 is enabled, confirm a
  deassert completes.

## 0052 mfd: macsmc: Match the T6050 SMC

- Superseded by Aurora's `j716c/t6050-platform` (`54b12371013e`, `64f198a02f63`), which matches the same
  string and adds a T6050 cell list. Options: (a) drop 0052 when that lands; (b) if it is far off, offer
  0052 as the minimal step so T6050 boards get an SMC on `integration/aurora` now (binding entry has the
  same shape as theirs, so the later merge is trivial).
- Title: `mfd: macsmc: Match the T6050 SMC`
- Text:

  > `apple,t6050-smc` is matched by no driver on integration, so a T6050 board has no RTC, power button,
  > lid, reboot or SMC GPIOs. This adds the match on the generic path, which J716s has been running
  > through an `apple,t8103-smc` DT fallback. The j716c/t6050-platform branch matches the same string
  > and will replace this.
  >
  > Not built with this entry yet (same code path as the fallback, tested). LLM use: written with an
  > LLM assistant (Claude); `Assisted-by: LLM` in the commit.

## 0053 dt-bindings: cpufreq: apple,cluster-cpufreq: Add T6050

- Target: discussion first, with the owner of the platform branch's `soc_t6050_info`. Their T6050 entry
  verifies transitions, uses a 2 ms timeout and refuses to probe without `apple,firmware-managed-thermal`.
  We measured the T8112 status layout and run stock code through the T8112 fallback. Two consistent
  outcomes: (a) this binding (fallback allowed) plus their driver entry, which then takes precedence;
  (b) their binding with a single string, and we move J716s to their driver entry when it lands and drop
  the board-file override in 0057.
- Title: `dt-bindings: cpufreq: apple,cluster-cpufreq: Add T6050`
- Text:

  > The T6050 cluster DVFS block has the T8112 layout (J716s: status +0x50, current p-state bits 9:5,
  > target 4:0), and stock apple-soc-cpufreq drives all three clusters through the T8112 fallback. This
  > allows `apple,t6050-cluster-cpufreq` with that fallback, like T6020/T6030/T6031/T6041/T8122. A
  > T6050 driver entry still takes precedence.
  >
  > LLM use: written with an LLM assistant (Claude); `Assisted-by: LLM` in the commit.

## 0054 arm64: dts: apple: t6050-max: List the CPUs in the ADT's order

- Target: `integration/aurora` after PR #945, or as a fixup offered to PR #945 (Erik Bourget, J716c).
  Ask first how their m1n1 handles J716c: stock m1n1 matches CPU nodes by position and stops at the
  first mismatch, so either their loader matches by MPIDR (then the order is cosmetic for them) or the
  J716c ADT order differs from the J716s one (then a per-board order is needed).
- Title: `arm64: dts: apple: t6050-max: List the CPUs in the ADT's order`
- Text:

  > m1n1's `dt_set_cpus()` compares DT CPU node N with ADT cpu N. With the sixth core of each cluster
  > listed last, the J716s stops at `FDT: DT CPU 5 MPIDR mismatch: 0x40100 != 0x40005`. This lists the
  > 18 cores in the ADT's order, which the labels already follow (cpu5 = 40005). A fused-off core is
  > still in the ADT and m1n1 prunes its node by position. `t6050-ultra.dtsi` is unchanged (no J775D
  > ADT checked).
  >
  > Tested on J716s (18 CPUs up). Not booted on J716c. LLM use: written with an LLM assistant (Claude);
  > `Assisted-by: LLM` in the commit.

## 0055 arm64: dts: apple: t6050: Describe the SMC's second GPIO bank

- Target: the J716s DT PR (it is its first consumer). Useful to J716c too once its AFE reset can use gp1c
  or when its pcIO driver lands.
- Text: as the commit; LLM disclosure as above.

## 0056 dt-bindings: arm: apple: Add the MacBook Pro (16-inch, M5 Pro)

- Target: the J716s DT PR. Note to reviewers: J716c (PR #945) has no `apple.yaml` entry either; offer to
  add it in the same patch if Erik wants.

## 0057 arm64: dts: apple: Add J716s (MacBook Pro 16-inch, M5 Pro)

- Target: new PR "arm64: dts: apple: Add J716s (MacBook Pro 16-inch, M5 Pro)" on `integration/aurora`,
  depending on PR #945 (J716c DT and the T6050 dtsi), #936 (NVMe), #939 (Type-C), #937/#938 (N1), and on
  0051-0056. The three `j716c/thunderbolt` PHY commits are needed for USB3 on the left-front port, not
  for the DT to build.
- Text:

  > The M5 Pro MacBook Pro 16-inch, one T6050 die like the J716c. The board file starts from J716c and
  > adds the J716s N1 platform ID, the keyboard backlight PWM and the ATC0 gadget, the left-front Type-C
  > port (SN201202x hpm1 + graph; USB3 works with the loader-filled PHY tunables), the trackpad AFE reset
  > on SMC gp1c, `apple,internal-panel` for simpledrm, and the T8112 cpufreq fallback (see 0053). The
  > right port, ATC3 and the SMC sensors stay off.
  >
  > Tested on J716s: NVMe root, keyboard and trackpad, USB3 left-front, SMC, 18 CPUs, simpledrm. The
  > DTB is equivalent to the hand-edited one we have been booting (differences listed in the PR: two
  > compatibles now matched by drivers, one unreferenced ANS power state dropped). `make dtbs` clean;
  > `dtbs_check` not run yet. LLM use: written with an LLM assistant (Claude); `Assisted-by: LLM` in the
  > commit.

- Before sending: run `make dtbs_check` (needs dt-schema) on t6050-j716s.dtb and fix what it reports
  (the connector graph against `apple,t6050-dp-phy.yaml` and `apple,dwc3.yaml` is the likely spot). `make W=1`
  gives one warning: `gpio@67700000` has a unit name and no `reg`, as in t6030/t6031.

## 0058 arm64: configs: Add a J716s fragment

- Ours. Aurora carries board fragments (`j813.config`, `j813-usb4.config`), so it can be offered with the
  DT PR; drop the USB network adapters and userspace lines (Landlock, nftables, zram, devmem) if reviewers
  want only the boot path.
