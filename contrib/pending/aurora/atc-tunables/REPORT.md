# J716s ATC1 (left-front) combo-PHY tunables

## Result

* `j716s-typec-fixed7.dts` is fixed6 plus 14 `apple,tunable-*` properties in
  `phy@2ab000000`. Nothing else changed: a diff of the decompiled fixed6 and fixed7
  DTBs shows only the 14 additions.
* `t6050-j716s-typec-fixed7.dtb` compiles with the worktree's `scripts/dtc/dtc`.
  It gives the same 123 warnings as fixed6 and no new ones. After decompiling,
  all 14 properties are present and match the ADT records word for word, checked
  with a script.
* No other change was needed in the DT. The phy node already has everything else
  the binding requires: `apple,port-index = <1>`, `apple,guest-port-reserved`,
  `mode-switch`, `orientation-switch`, `mboxes`, `#reset-cells`, 11 reg windows
  and 4 power domains. The dwc3 already has `resets = <&phy 0>` and
  `phys = <&phy PHY_TYPE_USB2(3)>, <&phy PHY_TYPE_USB3(4)>`.
* `gen-atc-tunables.py --check-dts` confirms that each tunable's bank lies in the
  matching DT reg window, with the same base and size as the ADT, for ATC1, ATC2
  and ATC3.

## How the driver parses them (worktree aurora-j716s @ da5a44d086e6)

* Format: `<offset mask value>` u32 triples. `devm_apple_tunable_parse()`
  (`drivers/soc/apple/tunable.c`) needs `length % 12 == 0`, `offset % 4 == 0`
  and `offset <= resource_size - 4`. A missing property gives `-ENOENT`.
  `apple_tunable_apply()` does `reg = (reg & ~mask) | value` at
  `bank_base + offset`.
* Offsets are relative to the bank base, never to "core":
  `atc_step`/`combo_tunable` apply at `dp->banks[bank]` (`atc-t6050-dp.c:250`,
  `atc-t6050-combo.h:50-60`).
* Required, in probe order:
  1. `tunable_names[0..8]` always (`atc-t6050-dp.c:723-731`). These print
     `missing or invalid <prop>`.
  2. `[9..10]` (`aus40cmn-shm`, `cio4pll`) only when `mode-switch` is present,
     which it is here.
  3. `usb2-default`, `usb2-host` and `pipe-default` in `combo_setup()`
     (`atc-t6050-combo.h:398-409`). These are required too, but fail with no
     message of their own: only `-ENOENT`, which the driver core logs at debug
     level.
* Bank windows: a core bank (2..35) runs from `core + bank_offset` to the end of
  "core", size 0x2c000 (`atc-t6050-dp.c:643-650`). Named banks use their own DT
  resource.

## Mapping (ADT -> DT), ATC1 values

ADT record: 12 bytes, `offset:24 | size:8 (=32)`, mask, value
(`m1n1-r2 src/kboot_atc.c:42-47`). **The driver's bank number is the ADT reg
index of `/arm-io/atc-phyN`.** Bank 44 is the exception: it is `usb-drdN` reg[3].
I checked every bank against the J716s ADT, and `t6050-die0.dtsi:302` says the
same. So the DT triple is the ADT record verbatim, with no rebasing. Aura's
T6040/J614s table (`aura/src/kboot_atc.c:1002-1023`) maps the same ADT names but
adds a "core" bias, because that driver applies through "core". The T6050 driver
doesn't.

| DT property | ADT source | bank (DT window) | tuples | required | present in ADT |
|---|---|---|---|---|---|
| apple,tunable-axi2af | atc-phy1 tunable_ATC0AXI2AF (900 B) | 41 axi2af 0x2a8000000/0x8000 | 75 | always | yes |
| apple,tunable-fabric | tunable_ATC_FABRIC (780 B) | 40 fabric 0x2ab244000/0x4000 | 65 | always | yes |
| apple,tunable-common-cfg | tunable_ATC_COMMON_CFG (12 B) | 43 common-cfg 0x2ab250000 | 1 | always | yes |
| apple,tunable-lioa | tunable_ATC0AXI2AF_LIOA (60 B) | 42 lioa 0x2a8020000 | 5 | always | yes |
| apple,tunable-lane0-rx-clock | tunable_LN0_RX_CFG_TX_OF_RXCLK (48 B) | 20 core+0xd000 | 4 | always | yes |
| apple,tunable-lane1-rx-clock | tunable_LN1_RX_CFG_TX_OF_RXCLK (48 B) | 29 core+0x1d000 | 4 | always | yes |
| apple,tunable-lane0-rx-eq | tunable_LN0_RX_EQ_DFLT (36 B) | 18 core+0xb000 | 3 | always | yes |
| apple,tunable-lane1-rx-eq | tunable_LN1_RX_EQ_DFLT (36 B) | 27 core+0x1b000 | 3 | always | yes |
| apple,tunable-auspll | tunable_AUSPLL_CORE (72 B) | 8 core+0x3200 | 6 | always | yes |
| apple,tunable-aus40cmn-shm | tunable_AUS40CMN_SHM (12 B) | 5 core+0xa00 | 1 | Type-C | yes |
| apple,tunable-cio4pll | tunable_CIO4PLL_CORE (48 B) | 10 core+0x3a00 | 4 | Type-C | yes |
| apple,tunable-usb2-default | tunable_USB2PHY_DFLT (24 B) | 0 usb2phy 0x2aaa90000 | 2 | combo | yes |
| apple,tunable-usb2-host | tunable_USB2PHY_HOST (12 B) | 0 usb2phy | 1 | combo | yes |
| apple,tunable-pipe-default | **usb-drd1** tunable_PIPE_HANDLER_DEFAULT (12 B) | 44 pipehandler 0x2aaa84000 | 1 | combo | yes |

Every record has size 32, an aligned offset and an offset inside its window. No
record sets bits outside its mask. Largest offsets: axi2af 0x401c (window 0x8000),
fabric 0x18c, lane RX EQ 0x6a0.

**`apple,tunable-pipe-default` gap: resolved.** It isn't on `atc-phy1`. It is
`tunable_PIPE_HANDLER_DEFAULT` on `/arm-io/usb-drd1`: `<0x44 0x4 0x4>`. That
node's reg[3] is the DT `pipehandler` window, and its reg[4] is the same address
as atc-phy1 reg[1] (`usb2-digital`). The generator asserts that pairing. Aura's
J614s table gets the same property from the same place
(`aura/src/kboot_atc.c:1013`, there named `apple,tunable-pipehandler`).

ADT tunables the driver doesn't consume, so they are not emitted:
`tunable_USB2PHY_DEV` (device mode; the combo is host-only), and
`tunable_LN0/LN1_RX_TOP_CIO_DFLT`, `tunable_UC_REGS_CIO_DFLT` and
`tunable_LN0/LN1_RX_EQ_CIO_DFLT` (USB4/CIO; the last three are empty).

## Per-port fragments

`atcN-tunables.dtsi-fragment.txt` exists for N = 0..3:

* **ATC0** (left-back, ADT port-number 1, core 0x2a3000000): this is the debug
  port. fixed6 has no combo node for it (`usb@2a2280000` is plain `snps,dwc3`),
  and the driver refuses port-index 0. The fragment is for reference only.
* **ATC1** (left-front, core 0x2ab000000): these values went into fixed7.
* **ATC2** (right, core 0x383000000): matches the DT node `phy@383000000`
  (port-index 2, disabled in fixed6). Paste the fragment there when you enable
  that port.
* **ATC3** (core 0x38b000000) is HDMI (ADT `port-type 6`) and has no `usb-drd3`.
  The generator therefore flags a missing `pipe-default` and exits 1. fixed6
  declares this node `apple,t6050-combo-phy` with port-index 3, still disabled.
  If it is ever enabled, it should be an `apple,t6050-dp-phy` (8 regs, no
  usb2/pipe) instead.

The ports differ only in `axi2af` (QoS words at 0x0-0x48 and 0x404) and
`aus40cmn-shm` (a 5-bit trim at +0x4, mask 0x7c: 0x50 / 0x44 / 0x48). All other
values are identical across ATC0-2.

## Risks

1. **Per-unit values in the DTB.** The AUS40CMN_SHM field looks like the
   fuse-derived VREG trim that iBoot bakes into the ADT on T602x and later (m1n1
   stopped reading ATC fuses there). Treat fixed7 as specific to this machine:
   don't commit it to a shared tree, and don't boot it on another J716s. The
   lasting fix is m1n1 (M1N1-PORT.md).
2. **Bank choice for RX EQ (18/27 = core+0xb000/0x1b000).** The ADT doesn't say
   which reg a tunable belongs to; the bank comes from Aurora's traced sequences
   (`usb-t6050/apple_t6050_usb_phy.h:52-62,122-132`). The offsets (0x698-0x6a0)
   fit that 0x1000 block, and the rx-clock/PLL/SHM banks agree with Aura's
   independent T6040 biases. Since the values are applied verbatim to the bank
   the driver chose, any error here would be the driver's, not the DT's.
3. **Duplicated lists.** If a future m1n1 appends these properties without
   deleting first, the lists double. That still parses, and re-applying idempotent
   masks is harmless, but it hides bugs. The patch draft deletes first.
4. **Next failures after the tunables**, all of which the driver logs:
   * `cannot attach <usb-aon|common|wrapper|usb> domain`
   * `cannot initialize PHY firmware IPC` (mailbox@2ab148000 is enabled)
   * `PHY firmware start failed`
   * `bank%u+%x timeout`
   * `start of mode N failed`
   * `USB3 PIPE switch failed (...): pipe 00=...`

   Silent `-EINVAL` is possible from the reg-size checks, but the windows match
   the ADT. Also possible: `USB3 PIPE switch failed (n), the port runs USB2 only`,
   a warning; USB2 still works.
5. **dwc3 tunables in fixed6** (not changed): they match ADT `usb-drd1`, except
   that `apple,tunable-gbl-default` has an extra tuple `<0x10 0xfff80000 0x680000>`
   (GCTL.PWRDNSCALE = 13), which comes from the Aurora DT, not the ADT. The ADT's
   `AUSBC_DEBUG_DEFAULT` and `BULK_FABRIC_DEFAULT` aren't applied, because the DT
   has no `drd-ausbc`/`drd-bulk` windows; they are optional.

## Confirming on the next boot (photograph / grep)

```
dmesg | grep -Ei '2ab000000|2aa280000|usb-pd|sn201202|role switch|xhci|dwc3|usb [0-9]'
ls /sys/bus/platform/drivers/apple-t6050-dp-phy/      # expect: 2ab000000.phy
ls /sys/class/phy/ /sys/class/typec_mux/ /sys/class/typec/
cat /sys/kernel/debug/devices_deferred                 # expect no 2aa280000.usb, no usb-pd@a
```

The PHY prints **nothing** when it probes successfully. Success means these
three lines are gone:

* `apple-t6050-dp-phy 2ab000000.phy: error -ENOENT: missing or invalid apple,tunable-axi2af`
* `dwc3-apple 2aa280000.usb: ... Failed to get reset control`
* `sn201202x ...: waiting for the USB role switch` for the left-front `usb-pd@a`

Instead, `2ab000000.phy` shows up under the driver in sysfs.

The dwc3 core stays off until the first cable event (`dwc3-apple.c:72-75`).
Plug a USB stick into the **left-front** port, then expect:

* `xhci-hcd xhci-hcd.N.auto: xHCI Host Controller`
* `new USB bus registered, assigned bus number N`
* `usb N-1: new high-speed USB device number 2 using xhci-hcd`, or SuperSpeed on
  the USB3 bus

Possibly also `apple-t6050-dp-phy 2ab000000.phy: USB3 PIPE switch failed (-n), the port runs USB2 only`.
That is acceptable for now: USB2 works.

Failure lines to photograph if they appear:

* `2ab000000.phy: start of mode`
* `PHY firmware`
* `bank..+.. timeout`
* `pipe 00=`
* `USB2 host start failed`
* `USB2 port reset failed`
* `dwc3-apple 2aa280000.usb: Failed to`
* `USB3 PHY setup failed`

## Open points

* ATC1 is the only port with tunables in the DT. ATC2 (right) needs its node set
  to `status = "okay"` plus its fragment, or the m1n1 patch.
* The m1n1 patch is a draft: syntax-checked, not built or booted.
* The bank choice for RX EQ comes from the driver's traced sequences, not the ADT
  (risk 2).
