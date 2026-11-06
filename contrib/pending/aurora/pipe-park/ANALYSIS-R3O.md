# R3-O: "bank2+260 timeout: 881 & 400", start of mode 3 failed

Inputs: `~/Work/agents/aurora-kernel/r3o-dmesg.txt` (read only), worktree `/Volumes/linux-cs/wt-aurora`
(aurora-j716s @ da5a44d086e6, read only), aurora-silicon/linux branch `j716c/thunderbolt` (read via
`gh api`, saved in `ref/aurora-tb/`), J716s runtime ADT.

## Diagnosis in five lines

1. Mode 3 is `COMBO_DP2`: DisplayPort Alt Mode pin assignment D, which carries USB3 plus 2 DP lanes
   (`atc-t6050-dp.c:71`, `atc-t6050-combo.h:185-224`). The PD controller's firmware entered it on its own
   with the Anker hub (the billboard device advertises DP).
2. The DP mode change made tipd drop the USB role (`tipd/core.c:1191-1196`), and the PHY then shut down
   USB, firmware included (`apple_t6050_usb_phy.h:176-230`, FIRMWARE 0 at `:210`). It restarted for
   mode 3 with `mf_normal_init` (`atc-t6050-typec-data.h:48-117`).
3. bank 2 is the start of "core" (0x2ab000000). +0x260 bit 10 is **UC_TNBL_DONE**: the PHY firmware
   reports it has finished lane calibration/tunables (`atc-t6050-typec-data.h:114`). The first start's
   identical poll (`apple_t6050_usb_phy.h:102`) passed at 0.722 s. The second start timed out with 0x881.
4. Cause, confirmed by Aurora's own fix: the CIO80 PHY firmware is preloaded by iBoot, its `__DATA`
   segment included, and it keeps its state there. Restarted after a stop, it runs on what the last run
   left behind and never finishes calibrating. So **every second PHY start fails** (USB, DP or CIO), on
   every port, until reboot.
5. The fix is kernel-side: Aurora `b8f2be0fef93` "restart the PHY firmware on its original data" saves
   the 64 KiB data SRAM at the first start and writes it back before every later one. It is on
   `j716c/thunderbolt` but not in PR #939, which is why our tree lacks it. Neither m1n1 nor the DT can fix this.

## 1. Mode 3, the 0x260 poll, and the RTKit re-init

**Timeline** (`r3o-dmesg.txt:412-522`):

| time | event | code |
|---|---|---|
| 0.722 | first combo start (COMBO_USB). The PHY firmware wakes: "RTKit: Initializing". The 0x260 poll passes. | `combo.h:123-161`, `apple_t6050_usb3_init_normal` (`usb_phy.h:35-106`) |
| 0.743-0.756 | xhci buses 1/2 up | dwc3-apple role host |
| 1.108-1.269 | the hub enumerates on bus 1 (USB2, high-speed) | |
| 1.313-1.645 | xhci removed, buses deregistered | tipd: DP connection appeared, so `dp_mode_changed` → `usb_role_switch_set_role(NONE)` (`core.c:1083, 1191-1196`) → dwc3 exit → `combo_usb3_poweroff` → `pipe_stop` + `combo_quiesce` → `apple_t6050_usb3_shutdown` (FIRMWARE 0, POWER 0) + `usb2_stop` |
| 1.780 | tipd `typec_mux_set(DP state D)` → `combo_mux(COMBO_DP2)` → `combo_stop` (domains usb, common, usb-aon off, `combo.h:93-121`) → `combo_start(COMBO_DP2)` → `atc_start` → `mf_normal_init`. Its FIRMWARE 1 wakes the firmware again: the second "RTKit: Initializing". | `combo.h:146-149`, `dp.c:320-348`, `dp.c:174-200` |
| 2.788 | after 5 ms plus a 1 s poll, bank2+0x260 reads 0x881; bit 0x400 never sets | `typec-data.h:112-114`, message from `dp.c:252-258` |
| 2.791 | "start of mode 3 failed (-110)". `dp->faulted = true` (`combo.h:150-154`). | |
| 3.8-5.9 | every later `combo_mux` returns -EIO (`combo.h:212-213`), so SAFE fails three times and revalidation gives up (`core.c:1210-1231, 990`) | |

**What mode 3 is.** `enum combo_mode { COMBO_SAFE, COMBO_USB, COMBO_DP4, COMBO_DP2 }` (`dp.c:71`).
`combo_mux()` maps `TYPEC_DP_STATE_D` to `COMBO_DP2` (`combo.h:195-199`). tipd reports pin assignment D
from the controller's DATA_STATUS (`core.c:803`). The controller firmware does discovery and Enter Mode
itself; Linux only publishes it (`core.c:1283-1286`).

**What bank2+0x260 bit 0x400 is.** Bank 2 is the first core bank, core+0 (`dp.c:41-42`), at
0x2ab000000. The poll is the last step of every PHY bring-up sequence, right after the firmware is
started: USB normal/reverse (`usb_phy.h:102, 172`) and DP multifunction normal/reverse
(`typec-data.h:114, 185`). Aurora's commit names the bit: "UC_TNBL_DONE did not come". That is the PHY
microcontroller signalling that it has finished applying its tunables and calibrating the lanes. It is
not an analog PLL bit: the AUSPLL/CIO4PLL tunables are written by the host earlier in the same sequence
(`typec-data.h:72-74, 82`). It is not an RTKit ack either: RTKit came up, and "Initializing" was printed.
In 0x881, bits 0, 7 and 11 are set and bit 10 never comes. I have no names for the other bits.

**What feeds it.** Domains usb-aon, common and wrapper (`combo.h:131-133` and ATC_POWER/`combo_wrapper`
→ domain[2]), plus the 4th "usb" domain for the USB2 banks. Tunables: the 11 PHY lists, applied in the
sequence before the firmware starts (`typec-data.h:63-82`). Then the firmware enable at bank 38
(usb-control) +0x40 bit 0 and the CPU run at +0x28 bit 4 (`dp.c:183-187`). All of these were the same
on the first start, which passed. Only the firmware's own data SRAM differed.

**Is the second RTKit re-init expected?** Yes. `atc_firmware(false)` sends a power-down to ep 0x20,
puts the IOP to sleep and re-inits the RTKit state (`dp.c:189-194`, `rtkit.c:1707-1722`).
`atc_firmware(true)` wakes it, and a woken RTKit firmware says HELLO again (`rtkit.c:214`). The HELLO is
not the problem. The problem is what the firmware finds in `__DATA` when it resumes.

**Where `__DATA` is** (J716s ADT `/arm-io/acio-phy-cpu1`, `iop-aciophy1-nub`: `pre-loaded 1`,
`running 1`, `reconfig-firmware`, `user-power-managed 1`):

| segment | phys | iova | size |
|---|---|---|---|
| __TEXT | 0x2ab040000 | 0x100000 | 0x20000 |
| __DATA | 0x2ab0c0000 | 0x10000000 | 0x10000 |

`__DATA` is exactly the DT `firmware-data` window (`reg` entry 10 of `phy@2ab000000`) that the driver
maps as `fw_data`. This is the window Aurora's fix saves and restores (64 KiB).

**Aurora's fix** (`ref/aurora-tb/b8f2be0fef93.patch`, Erik Bourget, 2026-11-04): "every second
connection of a port failed, in USB as in CIO mode, until reboot. Save the data SRAM when the firmware
is first started and put it back before every later start." It adds 15 lines to `atc_firmware()`.

## 2. m1n1 or DT instead?

**m1n1: no.**
* The failure happens inside Linux, at Linux's second firmware start, after Linux has already stopped
  the firmware and powered the domains off.
* m1n1 never touches the PHY coprocessor or its SRAM. 0018 only does PD to S0, and 0020 only does the
  usb2phy and the pipehandler mux. So it has no influence here, and R3-O's m1n1 stays as it is.
* aura does not hold the ATC in reset or set up the CIO/USB4 side on T6050: it has no T6050 code in
  `usb.c` or `kboot_atc.c` (see ANALYSIS.md section 2).
* The fix's snapshot comes from the first Linux start, so it captures whatever iBoot left. That is the
  same state the first start succeeded with.

**DT: no knob avoids it.**
* DP entry is done by the sn201202x firmware (`core.c:1283-1286`). The driver has no module parameter
  and the binding has no property to refuse an alt mode. A connector without the SS endpoint,
  `data-lanes` or similar does not stop the controller from entering DP with the partner.
* `maximum-speed = "high-speed"` on the dwc3 only limits the controller. The PHY still gets the DP mux
  event, the role still goes through NONE, and the firmware still restarts.
* Removing `mode-switch` from the PHY would stop every `combo_start`, so no USB at all.
* Even with no DP, the bug hits any second start: an unplug and replug, a role change, or suspend.

## 3. Recommendation

**(c) kernel: add Aurora's three T6050 PHY fixes from `j716c/thunderbolt`** (`patches/kernel-r3q/`).
`git am` applies them in order on aurora-j716s (checked on a scratch copy of the three files), and each
also passes `git apply --check` on the worktree. Not built: you build.

| # | Aurora commit | what | needed? |
|---|---|---|---|
| 0003 | b8f2be0fef93 restart the PHY firmware on its original data | the fix for this failure | **yes, the minimum** |
| 0002 | e604b7f414b4 carry on when the PIPE lock is not acknowledged | On J716c the lock ACK never comes and USB3 fell back to USB2. This lets the USB3 switch go ahead (with a warning). Needed for SuperSpeed on the hub's VIA USB3 part. | recommended |
| 0001 | 6f93def30893 park the PIPE from a dummy producer on any clock | the kernel twin of m1n1 0020 (same logic as my earlier `kernel-0001`). Redundant with 0020, but harmless, and matches Aurora. | optional |

`patches/kernel-0001-t6050-cold-park-accept-loader-0x22.patch` from the first round is superseded by
0001 here (same change). Use one or the other.

**(a) m1n1** and **(b) DT**: no change. R3-Q reuses R3-O's m1n1 and fixed7.

**Workaround on the current R3-O kernel: boot with the hub unplugged, plug it in after boot.**
* That plug then makes the first PHY start, and first starts work.
* If the controller reports DP pin D straight away, that first start is mode 3 and should come up
  (USB2 + USB3 on the other pair; no display consumer).
* If it reports USB first and DP a moment later, as at boot (USB at 0.72 s, DP at ~1.3 s), the DP switch
  is a second start and fails exactly the same way.
* Either way it is one plug per boot: unplug and replug fails.
* Worth one try only to confirm the diagnosis (expect "RTKit: Initializing" once, then either USB
  working or the same timeout after the second "Initializing"). It is not a fix.

## Risks

* 0003's snapshot is taken at the first `atc_firmware(true)` with the domains on (they are, in the
  sequence before that step). If the first start ever fails, the saved image is whatever that run
  started from, which is still the boot state.
* Mode 3 then runs the DP lane setup for 2 lanes plus USB3 on the other pair. Nothing in fixed7
  consumes DP on ATC1, so no link training should run. If tipd waits for a display route, USB goes on
  regardless ("A shared display route can be busy while the dock's USB path is usable", `core.c:1316`).
* 0002 makes the USB3 switch ignore a missing lock ACK. Aurora tested this on J716c, not J716s. If USB3
  misbehaves, drop 0002 and the port stays USB2 (`combo.h:279-283`).
* The xhci teardown and re-enumeration at the DP switch (~1.3 s) will still happen on every boot with
  this hub. Devices disconnect once, then come back.
