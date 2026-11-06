# J716s ATC1: "dummy PIPE park failed" (R3-N)

Inputs: `~/Work/agents/aurora-kernel/r3n-dmesg.txt:302-304`, worktree
`/Volumes/linux-cs/wt-aurora` (aurora-j716s @ da5a44d086e6, read only), m1n1 tree
`~/Work/agents/m1n1-r2/tree` (m1n1-r2 @ d5b29b03; R3-N actually ran ccbb51bc, `7497c0b1...`),
`aurora-silicon/aura` @ 671c0ce, `edimoldovan/m1n1` `t6050-aurora` @ fc277aa, J716s runtime ADT
`~/Work/studio-artifacts/adt-runtime-j716s.bin`.

## Diagnosis in five lines

1. The kernel's cold park accepts the pipehandler `MUX_CTRL & 0x73` only as 0, 2 or 0x42. It read **0x22**.
2. m1n1 writes 0x22 in `usb_phy_bringup()` (`src/usb.c:175`). It runs from `kboot_boot()` → `usb_init()` (`src/kboot.c:2988`) before every kernel handoff.
3. 0x22 means dummy clock and dummy data in the **T8103** field layout (clock 5:3, data 2:0). T6050 uses the T8142 layout (clock 6:4, data 1:0). There, 0x22 means **USB4 clock with dummy data**.
4. The other printed words are m1n1's writes too: `20=00009332` is m1n1's literal `NONSELECTED_OVERRIDE` value (`src/usb.c:177`). `1c=00000010` is m1n1's `AON_GEN=RESET_N` after the kernel cleared bit 0 and set the clamp. The controller domain stayed up from m1n1 to the kernel.
5. The fix: on T6050, m1n1 parks the PIPE as 0x42 (patch 0020). The kernel's park then returns 0 at once, and dwc3-apple can assert its reset and probe. Nothing in the DT is involved.

## 1. What "dummy PIPE park" does

Call path: `dwc3_apple_probe()` → `reset_control_assert()` (`drivers/usb/dwc3/dwc3-apple.c:960-963`) →
`combo_reset_assert()` (`drivers/phy/apple/atc-t6050-combo.h:325-343`):

1. It refuses if `id != 0` or `pipe_active` is set (`-EBUSY`), or if the PHY is already faulted (`-EIO`) (`combo.h:331-334`).
2. `AON_GEN` (bank 44 +0x1c): it clears bit 0 (`DWC3_RESET_N`, the controller goes into reset), then sets bit 4 (`DWC3_FORCE_CLAMP_EN`) (`combo.h:335-336`).
3. It calls `apple_t6050_usb3_pipe_cold_dummy()` (`drivers/phy/apple/usb-t6050/apple_t6050_usb3_pipe.h:17-37`):
   * It fails (-1) if `AON_GEN` bit 0 is still set (`:23-24`).
   * `mux = MUX_CTRL(+0x0c) & 0x73`. It fails (-1) unless `mux` is 0, 2 or 0x42 (`:25-27`).
   * If `mux` is 0x42 it returns 0 at once (`:28-29`).
   * Otherwise it writes clock = 0, waits 10 us, sets data = 2, waits 10 us, sets clock = 4, waits 10 us, and checks that the value reads back as 0x42 (`:30-36`).
4. On failure it calls `combo_pipe_fault()` (`combo.h:83-93`), which prints the words and sets `dp->faulted = true`. From then on every PHY op returns `-EIO` (`combo.h:98, 128, 170, 205, 224, 248, 264, 298, 333, 351`). dwc3-apple fails with -5, the role switch never registers, and sn201202x defers forever (`r3n-dmesg.txt:495`).

**Bank and offsets.** All the printed words are bank 44. That is the `"pipehandler"` reg window of the PHY node (`combo.h:384`, minimum size 0x48), which is ADT `usb-drd1` reg[3] = **0x2aaa84000** on J716s ATC1. It is the same block m1n1 calls `drd_regs_unk3` (`m1n1 src/usb.c:136`). Register names are from `drivers/phy/apple/atc.c:496-531`:

| off | name | read | meaning |
|---|---|---|---|
| 0x00 | OVERRIDE | 0 | no RXVALID/RXDETECT override |
| 0x04 | OVERRIDE_VALUES | 0x16 | RXDETECT0/1 and PHY_STATUS bits set. Not written by m1n1 or the kernel before this point (iBoot or reset value), and not checked by the park. |
| 0x0c | MUX_CTRL | **0x22** | T6050 layout: clock 2 (USB4), data 2 (dummy). This is the failing check. |
| 0x10 | LOCK_REQ | 0 | no lock requested |
| 0x14 | LOCK_ACK | 0 | no lock held |
| 0x1c | AON_GEN | 0x10 | the kernel's own step 2: reset asserted, clamp on |
| 0x20 | NONSELECTED_OVERRIDE | 0x9332 | m1n1's literal value: DUMMY_PHY_EN (bit 15), NATIVE_RESET (bit 12), NATIVE_POWER_DOWN = 2 |

**Expected state on entry.** The controller is in reset (the driver does this itself). The PIPE mux is either
off/reset (0 or 2) or already on the dummy producer in the T6050 layout (0x42). This is a "cold" park: the
driver assumes nobody has used the pipehandler, or that whoever did left it parked the T6050 way. The
switch and stop helpers (`pipe.h:44-96`, `:102-140`) also only accept 0x42 or 0x10 (native USB3). Any other
state counts as an unknown producer that the driver must not reroute (comment at `pipe.h:54`).

**What our values say.** The PIPE handler was never touched by a T6050-aware agent. It holds exactly what
m1n1's generic `usb_phy_bringup()` writes (`src/usb.c:175-177`): `MUX_CTRL=0x22`, `AON_GEN=1`,
`NONSELECTED_OVERRIDE=0x9332`. The kernel then changed only `AON_GEN` (0x1 → 0x10). The hardware did
respond: LOCK_ACK = 0 with LOCK_REQ = 0 is consistent, and the registers read back the values written. So
nothing is "not responding". The driver refused, by design, to park from a mux state it does not recognise.
The layout difference is documented in the same worktree: `PIPEHANDLER_MUX_CTRL_CLK_T8103 GENMASK(5,3)` /
`_DATA_T8103 GENMASK(2,0)` against `_CLK_T8142 GENMASK(6,4)` / `_DATA_T8142 GENMASK(1,0)`, with clock
1 = USB3, 2 = USB4, 4 = DUMMY and data 0 = USB3, 1 = USB4, 2 = DUMMY (`atc.c:505-517`). The T8142 ATC
config uses the new layout (`atc.c:6567-6568`), and `pipe.h:80` says "T6050 clock bits are 6:4, not the
older 5:3". In the T8103 layout, (4<<3)|2 = 0x22. In the T6050 layout, (4<<4)|2 = 0x42.

## 2. What aura, edimoldovan's m1n1 and our m1n1 leave behind on T6050

| | aura @671c0ce | edi m1n1 t6050-aurora @fc277aa | ours (m1n1-r2 / R3-N ccbb51bc) |
|---|---|---|---|
| `usb_init()` before the kernel | yes, `src/kboot.c:9335-9339` (skipped only on T8140) | yes, `src/kboot.c:6444-6447` | yes, `src/kboot.c:2988` |
| HPM/PD power-up in `usb_init()` | yes (`src/usb.c:337-346, 377`) | yes (`src/usb.c:311-320, 351`) | yes, 0018 (`src/usb.c:284-327`) |
| `usb_phy_bringup()` on every port | yes, **except ports whose ADT `usb-drdN` has `usb-device-disable`** (`src/usb.c:136-143, 190-193`) | yes, all ports (`src/usb.c:165-207, 353-354`) | yes, all ports (`src/usb.c:145-180, 329-330`) |
| pipehandler writes there | MUX 0x22, AON_GEN 1, NONSEL 0x9332 (`src/usb.c:225-227`) | the same (`src/usb.c:202-204`) | the same (`src/usb.c:175-177`) |
| T6050-specific PIPE code | none (no T6050 in `usb.c` or `kboot_atc.c`) | `usb_t6050_host_prep()` (`src/usb.c:444-521`, called from `src/main.c:338-343` after `usb_iodev_shutdown`): bringup again, dwc3 to host, PIPE overrides 0x00/0x04, **mux left at 0x22** | none |
| dwc3 for a proxy | only on the proxy path (`main.c:213, 269`) | only on the proxy path (`main.c:119-120, 157-158, 220-221`) and in host_prep | stage-2 with a payload: no (`main.c:83` needs `lp_sip0 == 127` and no display). Stage-1's proxy brings up "USB0/1/2" and `usb_iodev_shutdown()` stops dwc3 (`main.c:203`, `usb_dwc3.c:1269-1299`: device stop, CSFTRST, DART unmap). Clocks and the domain stay on. |
| USB shutdown/park before the jump | `usb_iodev_shutdown()` only (dwc3 device side) | the same, then host_prep | the same |
| PHY left in reset? | no: AON_GEN = RESET_N (controller out of reset) | no, controller running in host mode | no: AON_GEN = RESET_N |
| PIPE handler programmed by the loader? | yes, with the T8103 value | yes, with the T8103 value | yes, with the T8103 value |

So neither Aurora loader parks the PIPE the T6050 way either. Both would hand the kernel 0x22 on every port
they bring up, and 0x22 fails `cold_dummy()` the same way on any T6050. Why it still works for them:

* The Aurora driver work was tested on **J775D** (M5 Ultra; commits e12115750327, dc5f10049de5,
  96145a9c7a01 all say "on J775D"), where ports 1-5 are handled and port 0 is "the boot loader's debug
  link" (da5a44d086e6). aura skips any port whose ADT `usb-drd` carries `usb-device-disable`. On a desktop
  that plausibly covers every port except the DFU/debug one, so those pipehandlers stay at their reset
  value and the cold park succeeds. I could not check a J775D ADT. **The J716s ADT has no
  `usb-device-disable` on usb-drd0/1/2** (checked: drd0 has `ncm-interrupt-ep-disabled, host-mac-address,
  device-mac-address, port-type, port-number`, and drd1/drd2 also have `usb-restore-disable`). On our
  laptop, aura would write 0x22 on ATC1 too.
* In-tree, the Aurora **J716c DT disables ATC1/ATC3 and their usb-drd nodes**
  (`arch/arm64/boot/dts/apple/t6050-j716c.dts:110-158`, "not yet described for this board"). So "the same
  driver boots on J716c" is not evidence for this port's USB path.
* edi's `usb_t6050_host_prep()` targets the generic dwc3 plus `apple,t6050-usb2-phy` (its own comment,
  `src/usb.c:429-435`: "the Type-C PHY is a new generation Linux cannot drive yet"). That is a USB2-only
  model, and the combo PHY's cold park never runs there.

## 3. Does the PHY node lack anything that explains this?

No. The failure happens at the first PHY call in dwc3-apple's probe (`dwc3-apple.c:960`). Before it, only
reset and phy lookups run (`:937-958`). The park reads and writes nothing except bank 44, and does not use
tunables, mode-switch, orientation or the connector graph.

* **Power domains**: the bank-44 reads returned live values (m1n1's 0x9332 and the kernel's AON_GEN
  write), so `ps_atc1_usb` was on. The dwc3 node holds it (`power-domains = <0x18>`), and so does the PHY
  as its 4th "usb" domain. `PM: genpd: Not disabling unused power domains` (`r3n-dmesg.txt:309`,
  `pd_ignore_unused`) keeps the boot state, which is why m1n1's values survived. A power cycle of that
  domain would have reset the mux and hidden the bug.
* **`apple,tunable-pipe-default`** (`<0x44 0x4 0x4>`, from ADT `usb-drd1 tunable_PIPE_HANDLER_DEFAULT`,
  checked word for word) is applied only in `combo_usb3_mode()` right before `pipe_switch()`
  (`combo.h:278`), long after the park. Offset 0x44 bit 2 is the USB2 config enable (`atc.c:554-555`). It
  has nothing to do with the mux check.
* **`mode-switch` / `orientation-switch` / `mboxes` / 4 domains / `#reset-cells` / port-index 1**: all
  present in fixed7. The usb-pd connector graph is present and linked (fw_devlink cycle notes at
  `r3n-dmesg.txt:178-182`). `sn201202x: waiting for the USB role switch` is a consequence: the role
  switch is registered only by a probed dwc3-apple.
* **dwc3 `apple,tunable-*`**: ours are identical to the Aurora tree's (`t6050-die0.dtsi:596-606`, the
  usb_drd3 block that J716c inherits): gbl-default (2), gbl-host (9 incl. 0x580/0x584), dbg, cfg-host,
  link (4), cio. Neither has `apple,tunable-ausbc` / `-bulk` (optional, `dwc3-apple.c:240-272`, and the DT
  lacks the drd-ausbc/drd-bulk windows). They are applied after the reset, so they can't affect the park.
* **Next possible snags** once the park passes (not caused by the DT): `combo_reset_deassert()` needs
  `usb2_active`, so a combo start after a Type-C orientation/mux event (`combo.h:344-363`). The USB3
  switch can end in "USB3 PIPE switch failed (-3), the port runs USB2 only" (LOCK_ACK timeout,
  `combo.h:279-283`). That is a soft fallback, not a probe failure.

## 4. Recommendation (smallest change, best odds)

**(a) m1n1 side: chosen.** Patch **0020**
(`patches/0020-usb-t6050-park-the-PIPE-on-the-dummy-producer-in-the.patch`, m1n1 branches `pipe-park`
on d5b29b03 and `pipe-park-r2` on ccbb51bc): in `usb_phy_bringup()`, on T6050/T6051 only, instead of
`write32(MUX_CTRL, 0x22)`:

1. `AON_GEN`: clear `DWC3_RESET_N`, set `FORCE_CLAMP_EN`. This is the kernel's `combo_reset_assert()`
   step 2, because stage-1's proxy may have left dwc3 running.
2. Clock field 6:4 to 0, wait 10 us. Data field 1:0 to 2, wait 10 us. Clock to 4, wait 10 us. This is the
   kernel's `cold_dummy()` sequence.
3. Print `usb: usb-drdN: PIPE on the dummy producer, MUX_CTRL <before> -> <after>`.

The existing `AON_GEN = RESET_N` and `NONSELECTED_OVERRIDE = 0x9332` writes follow unchanged. The kernel
then finds 0x42 and returns 0 without touching the mux (`pipe.h:28-29`). `pipe_switch()` also accepts
0x42 as its starting point (`pipe.h:55`). Other SoCs keep the 0x22 write, so nothing changes off T6050.

The alternatives I rejected:
* Skipping `usb_phy_bringup()` on non-tether ports also removes the USB2 PHY setup and makes stage-1's
  0x22 the final value.
* Leaving the ATC1 block in reset doesn't help: the mux value persists while the domain is on.

Built: `build/m1n1-plain-r2-pipepark.bin` (ccbb51bc + 0020, the R3-N m1n1 plus this change only) and
`build/m1n1-plain-pipepark.bin` (d5b29b03 + 0020). Both are 0x400000 bytes with no warnings, and the
recipe reproduces `7497c0b1...` and `2c46317d...` byte for byte. Payload: `R3-O-RECIPE.md`.

**(b) DT side**: nothing to change. No property influences the check.

**(c) Kernel side, fallback only**: `patches/kernel-0001-t6050-cold-park-accept-loader-0x22.patch`. In
`cold_dummy()`, accept any state whose data select is off or dummy (`mux == 0 || (mux & 3) == 2`), so
0x22 gets re-parked. Live USB3 (0x10) and USB4 producers are still refused. `git apply --check` passes on
the worktree. It is **not applied and not built**. Use it only if a loader you don't control (aura, edi)
must boot this kernel on J716s.

## 5. 0021: kboot_atc T6050 tunables

`patches/0021-kboot-atc-produce-the-T6050-combo-PHY-tunables-from-.patch` is the
`~/Work/agents/atc-tunables/m1n1-kboot_atc-t6050.patch` draft plus two changes: it is clang-formatted, and
it skips ports without a `usb-drdN` node silently (ATC3/HDMI would otherwise print a misleading "Unable
to set up" line). It applies on top of 0020 or alone; the files don't overlap. It builds without warnings
(`build/m1n1-plain-r2-pipepark-atc.bin`, `build/m1n1-plain-pipepark-atc.bin`).

**Values: identical.** `tools/emulate-0021.py` runs 0021's table and checks against the J716s runtime
ADT. For ATC1 it produces all 14 lists, and each one equals fixed7's property word for word
(175 tuples). No other `apple,tunable-*` is in fixed7's PHY node. fixed6 and fixed7 differ only by these
14 properties (decompiled diff). So with 0021, the fixed6 DTB plus m1n1 gives the kernel the same PHY node
contents as fixed7. Property order inside the node differs; values and order within each list match. 0021
deletes any existing copy first, so fixed7 also works (it gets replaced with the same values). Expected
m1n1 lines: `kboot: /arm-io/atc-phy1: T6050 combo PHY tunables passed`, and the same for atc-phy2
(fixed6 has the node, disabled). atc-phy0 has no DT node and atc-phy3 has no usb-drd3, so both are
skipped silently.

## Risks

* 0020 changes every T6050 port m1n1 brings up, including drd0 (the left-back tether port). In
  fixed6/fixed7 that port is a plain `snps,dwc3` high-speed gadget with no PHY driver, so it now runs on
  the dummy PIPE clock instead of the "USB4" clock it got by accident. For USB2-only use the dummy
  producer is the intended source; on T8103-era Macs 0x22 means exactly that. Still, if the tether
  stops enumerating on a kernel that uses it, 0020 is the suspect. In R3-N that node did not probe at
  all (`r3n-dmesg.txt:260`, no dwc3 line).
* If `usb_phy_bringup()` fails early for a port on stage-2 (pmgr enable), stage-1's 0x22 stays. The panel
  line is then missing for that port.
* The kernel fallback patch is unbuilt. 0021 is built but not yet booted. R3-P tests 0020 and 0021
  together, so boot it only after R3-O.
