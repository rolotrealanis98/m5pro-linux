# m1n1: producing the T6050 combo-PHY tunables

Goal: m1n1 fills the 14 `apple,tunable-*` properties of every
`apple,t6050-combo-phy` node from the ADT at boot, so the J716s DT (and
`j716s-typec-fixed7.dts`) no longer has to carry them. The values include
per-port trims (see REPORT.md), so this is also the only way to get a DT that
works on more than one machine.

Patch draft: `m1n1-kboot_atc-t6050.patch` (in this folder). It applies cleanly with
`git apply` to `~/Work/agents/m1n1-r2/tree` at `d5b29b03`. Syntax-checked only
(`clang -fsyntax-only -target aarch64-none-elf`, no warnings with `-Wall`).
Not built, not booted.

## Why the existing code doesn't cover it

`kboot_setup_atc()` (`src/kboot_atc.c:568`) walks `/arm-io/atc-phyN` and finds
the FDT node through the alias `atcphyN`. The J716s DT has no `atcphy*` aliases,
so today m1n1 prints `FDT: Unable to find alias atcphyN` and leaves the PHY
alone. Even with an alias, `atc-phy,t6050` falls through to the T8103 table
(`atc_tunables[]`), the first missing name (`tunable_USB_ACIOPHY_TOP`) triggers
`cleanup`, and the code requires `apple,tunable-common-b`, which this driver
doesn't use.

None of the Aurora loaders has a T6050 producer either: not `aurora-silicon/aura`
@671c0ce, not `aurora-silicon/m1n1` @cf57aeb, not `edimoldovan/m1n1` `t6050-aurora`
@fc277aa. A grep for `t6050-combo`, `tunable-pipe-default`,
`tunable-usb2-default` and `tunable-lane0-rx-clock` finds nothing. The closest
model is Aura's J614s/T6040 table, `aura/src/kboot_atc.c:996-1023`
(`j614s_atc_tunables[]`, `j614s_resource_size()`, `j614s_export_atc()`). It
maps the same ADT names onto named DT resources, takes
`tunable_PIPE_HANDLER_DEFAULT` from `/arm-io/usb-drdN`, and checks bounds against
the DT `reg` size. The T6040 driver applies the lane and PLL lists through
"core", so Aura adds a bias equal to the bank offset (for example
`tunable_AUSPLL_CORE` -> core + 0x3200). The T6050 driver applies each list at
its own bank base, so the bias is 0.

## The T6050 rule

The ADT record format is the same as on older SoCs (`struct atc_tunable`,
`kboot_atc.c:42-47`: `offset:24 size:8, mask, value`, size always 32). On T6050:

* **Bank number = ADT reg index.** The driver's bank numbers (`atc-t6050-dp.c:41-61`,
  `atc-t6050-combo.h:383-385`) equal the reg indices of `/arm-io/atc-phyN`.
  Bank 44 is the exception: it is `usb-drdN` reg[3]. Checked on the J716s ADT:
  reg[2..35] = core + {0, 0x400, ... 0x29000} matches `core_banks[]` exactly, and
  reg[38..43] / usb-drd reg[3] equal the DT `usb-control`, `reset`, `fabric`,
  `axi2af`, `lioa`, `common-cfg` and `pipehandler` windows. The kernel DT's own
  comment says the same (`t6050-die0.dtsi:302`).
* **Offsets copy verbatim**: `reg_offset = 0`.
* **Window for the bounds check** = the kernel's (`tunable.c`: `offset % 4 == 0`,
  `offset <= size - 4`). For a named bank it is the size of its DT resource. For a
  core bank it is `core_size - bank_offset`, because `atc-t6050-dp.c:643-650` ends
  every core bank at the end of "core".

| ADT (atc-phyN unless noted) | DT property | DT resource + bank offset | bank |
|---|---|---|---|
| tunable_ATC0AXI2AF | apple,tunable-axi2af | axi2af + 0 | 41 |
| tunable_ATC_FABRIC | apple,tunable-fabric | fabric + 0 | 40 |
| tunable_ATC_COMMON_CFG | apple,tunable-common-cfg | common-cfg + 0 | 43 |
| tunable_ATC0AXI2AF_LIOA | apple,tunable-lioa | lioa + 0 | 42 |
| tunable_LN0_RX_CFG_TX_OF_RXCLK | apple,tunable-lane0-rx-clock | core + 0xd000 | 20 |
| tunable_LN1_RX_CFG_TX_OF_RXCLK | apple,tunable-lane1-rx-clock | core + 0x1d000 | 29 |
| tunable_LN0_RX_EQ_DFLT | apple,tunable-lane0-rx-eq | core + 0xb000 | 18 |
| tunable_LN1_RX_EQ_DFLT | apple,tunable-lane1-rx-eq | core + 0x1b000 | 27 |
| tunable_AUSPLL_CORE | apple,tunable-auspll | core + 0x3200 | 8 |
| tunable_AUS40CMN_SHM | apple,tunable-aus40cmn-shm | core + 0xa00 | 5 |
| tunable_CIO4PLL_CORE | apple,tunable-cio4pll | core + 0x3a00 | 10 |
| tunable_USB2PHY_DFLT | apple,tunable-usb2-default | usb2phy + 0 | 0 |
| tunable_USB2PHY_HOST | apple,tunable-usb2-host | usb2phy + 0 | 0 |
| usb-drdN: tunable_PIPE_HANDLER_DEFAULT | apple,tunable-pipe-default | pipehandler + 0 | 44 |

## Finding the node

Don't use aliases. Use the "core" address instead:
`adt_get_reg(atc-phyN, "reg", 2)` is the first core bank, and the combo PHY's
`reg-names = "core"` window starts there. Walk
`fdt_node_offset_by_compatible(dt, -1, "apple,t6050-combo-phy")` and pick the
node whose "core" address matches. The soc `ranges` are 1:1 on J716s
(`<0x02 0x00 0x02 0x00 0x03 0xc0000000>`).

Ports with no DT node are skipped silently:
* ATC0 is the debug port. The driver refuses port-index 0.
* ATC3 is HDMI, ADT `port-type 6`. It has no `usb-drd3`, so a combo node there
  could never get `pipe-default`.

## What the patch does

1. Adds the `t6050_atc_tunables[]` table above, `t6050_fdt_reg()` (a lookup by
   reg-names, the same as Aura's `j614s_resource_size()`), `t6050_find_phy()` and
   `dt_copy_atc_t6050_tunables(dt, port)`.
2. Calls `fdt_delprop` on all 14 properties first. A hand-made DT such as fixed7
   then gets replaced instead of doubled: `dt_append_atc_tunable()` uses
   `fdt_appendprop_u32`.
3. Appends each list through the existing `dt_append_atc_tunable()` with
   `reg_offset = 0` and `reg_size = window`. That function already checks
   size == 32, alignment and bounds.
4. On any failure it deletes all 14 properties. The driver then fails cleanly
   with `-ENOENT` instead of running with a partial set, and the boot log shows
   `FDT: Unable to set up T6050 ATC tunables for /arm-io/atc-phyN`.
5. `kboot_setup_atc()` takes this path when `chip_id` is T6050 or T6051 and returns
   before the alias loop.

Expected m1n1 log on J716s: `kboot: /arm-io/atc-phy1: T6050 combo PHY tunables passed`
(and atc-phy2 if its node is present; it is `status = "disabled"` in fixed6, which
the patch does not change).

## Not covered / follow-ups

* `apple,tunable-ausbc` and `apple,tunable-bulk` for the dwc3 (ADT
  `tunable_AUSBC_DEBUG_DEFAULT`, `tunable_BULK_FABRIC_DEFAULT`) need
  `drd-ausbc` / `drd-bulk` reg windows in the DT first. They are optional in
  `dwc3-apple.c:309`.
* The dwc3 tunables (gbl-default/host, dbg, cfg-host, link, cio) are hand-copied
  into fixed6 today. A follow-up could produce them from `usb-drdN` the way Aura's
  J614s rows 11-15 do (`controller_target`, windows 0xc100/0xb00/0x300).
* Upstreaming: the Aurora kernel binding names these properties, so the table
  belongs in Aurora's `aura`/`m1n1` next to the J614s one. Offer it there once it
  has booted once on J716s.
