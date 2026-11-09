# N1 / apcie0 deep decode: PMGR, GPIO, ECAM and port 0 bring-up, macOS 27.3 single-core on J716s (T6050)

Input: `captures/trace-cpus1-n1x-20261109-0203.log` (12,284 lines; 11,106 MMIO events; run dir `20261108-210203-guest-nodisk-trace`, i.e. no root volume). Group `n1x` = `apcie0.ecam` (0x1cb0000000+0x300000), `gpio0.pcie` (0x29c000000+0x4000), `pmgr.apcie` (0x280900100+0x200), `apcie0.reg1..39`. ASYNC trace, no timestamps; hooks went in at the first SPTM AMCC read (L585), before any apcie access (first apcie MMIO L1625). The log has no guest console text, so the "chip reset" / "warm reset" console lines cannot be tied to trace lines directly. The log ends inside the third teardown (L11917, then 368 gpio events to L12285).
Helper (extended, old `apcie`/`ave` output verified byte-identical on the previous log): `captures/n1-ave-decode.py LOG apcie|ave|gpio|pmgr|ecam|iters|timeline [FIRST LAST]`, run with `python3 -I`. `iters` prints the milestone list used below.

Labels: **[F]** fact read from the log (raw values quoted), **[I]** inference, **[ADT]** `studio-artifacts/adt-runtime-j716s.bin`, **[REF]** our m1n1 0022-0028 / Linux `pcie-apple.c` / `pinctrl-apple-gpio.c`. `Lnnnn` = log line. No ADT serial/MAC-like value is quoted; the `centauri-alpha` ADT node carries a local MAC: **present, not copied**.

## 0. Headlines

- **[F] macOS never touches the N1's config space in this capture.** 0 ECAM accesses to bus 1 or bus 2 (0x1cb0100000..0x1cb02fffff), although the window covers them. ECAM traffic is bus 0 only: root port 00:00.0 (N1, port 0), root port 00:01.0 (SD reader, port 1) and one vendor-ID probe of 00:02.0..00:1f.0 (all `0xffffffff`, L2657-2686). So there is no BAR sizing/assignment, MSI/MSI-X or vendor-capability traffic for the endpoint to report (section 2).
- **[F] Port 0 is brought up three times and the link comes up every time** (`INTSTAT 0x1000` at the first read after LTSSM start: L3577, L7824, L10760; root-port LnkSta `0x3011` = DLLLA, **Gen1 x1**). Nothing PCIe-related happens during the ~20 s link-up window except the idle gpio loop; then PME_Turn_Off is issued (never reaches L2) and the port is torn down and redone (section 1.9).
- **[F] PMGR: macOS performs no power-up writes for the APCIE chain.** Only a generic flag-clear plus AUTO_ENABLE sweep (L1475-1537). `APCIE_SYS_GP`, `APCIE_PHY_SW`, `APHY_GP_AUS5` are only read (they sit in auto-PM idle states from boot, **[I]** powered on demand).
- **[F] PERST# (pad 80) and CLKREQ# (pad 76) are visible.** PERST# is released with a plain output-high write (`0x76a03`) two events before LTSSM start, after lane bit 10, exactly as our m1n1/Linux order. CLKREQ# pads are reconfigured early (section 1.3).
- **[F] The "2,195 polls of +0x118/+0x11c" are a read/write/read loop of an unchanged pad value on pads 70/71 (and 68/69), 6,056 events = 55% of the whole log, not N1 handshake traffic** (section 1.3). I count 1,925 rounds on pads 70/71 (5,774 events) plus 94 on pads 68/69 (2,019 rounds, 6,056 events); I cannot reproduce 2,195.
- **[F] Root-port DBI sequence is now visible and matches the ADT tunables record for record** (section 1.5): our m1n1 0023 stage D / Linux `port_configure` are right, plus extras macOS adds after link-up (PTM, LTR, AER, L1SS/ASPM, bridge window).
- **[F] macOS programs the N1 bridge window before any endpoint exists: prefetchable `[bus 0x80000000, 0x820fffff]` (33 MiB = 32 MiB + 1 MiB), memory and I/O windows closed** (CPU `0xb80000000..0xb820fffff`). The live-macOS scan values (32 MiB BAR `0xb82000000`, alpha `0xb84010000`, ...) do not fit inside it (section 2).

## 1. Ordered bring-up of port 0 (N1) as macOS does it

Port numbering: macOS bus numbers are N1 = bus 2, SD reader = bus 1 (root port 00:00.0 gets secondary/subordinate 2, 00:01.0 gets 1). Port 0 = reg16/17/18/19/20/21 (+ `reg3` shared PHY ctl, `reg1` RC, `reg2` PHY window); port 1 = reg22-27.

### 1.1 Iteration summary (what "chip reset" / "warm reset" look like on the root-complex side)

| | iteration I (cold) | iteration II | iteration III |
|---|---|---|---|
| lines | L1136-L7273 (ports 0 and 1) | L7273-L10209 | L10209-L11917 (log cut) |
| shared GP PHY init | yes (L1625-1656) | no | no |
| port 1 (SD reader) | up L3701, torn down L5693-5803 (reached L2, `0x9b00134d`) | no | no |
| root-port enumeration | full (bus numbers, BAR probe, windows, cap walk) L2606-2886 | config **restore** of saved root-port state L7759-7807 | same as II |
| LnkCtl2 target speed (0xa0) | `0x43` (Gen3 = ADT maximum-link-speed) L2074 | `0x41` (Gen1) L7687 | `0x41` L10623 |
| RID2SID slot 1 `0x80010200` | after link-up L3685 | before training L7702 (also L7273) | L10638 (also L10209) |
| INTMSK before start | `0xff5527ff` L2095, `0xff55270f` L3079 | `0xff552700` L7722 | `0xff552700` L10658 |
| config tunables `0x8a8/0x8ac` | R/W (0 -> 1) L2000-2003 | read only (already 1) L7619 | same |
| PERST# pad | 0x76a02 -> 0x76a00 (L1605) -> 0x76a03 (L3574) | 0x76a02 -> 0x76a03 (L7821) | same (L10757) |
| LTSSM start / link up | L3576 / L3577 | L7823 / L7824 | L10759 / L10760 |
| link status | LnkSta `0x3011` (Gen1 x1) | `0x3011` | `0x3011` |
| teardown | L7154-7273 | L10090-10209 | counter read-out only (L11909-11917), then log ends |
| port counter0 at teardown | `0x1d06d507` (486,987,015) | `0x1ca5ad3d` (480,619,837) | `0x0dbc87fa` (230,459,386) |
| DevCtl (`0x78`) after link-up | `0x81f` | `0x81f` -> `0x83f` (bit 5 set, L7905) | `0x83f` from the start |

II and III are the same sequence except DevCtl bit 5 persisting. **[F]** The only differences between I and II/III are: no shared init and no port 1, saved/restored root-port config instead of the first enumeration, LnkCtl2 target 3 -> 1, RID2SID route order, the INTMSK value, and `0x8a8/0x8ac` already set. **[I]** The target-speed drop to Gen1 after the first iteration agrees with the N1 ROM personality linking Gen1 only (ADT `ignore-link-speed-mismatch` set on bridge0); I cannot tell which iteration is the console's "chip reset" and which the "warm reset" (the SMC keys `gP13`/`bpli` are not traced).
Port counter0 (`0x4000`, enabled by `0x4020 = 3` before training, read at disable after `0x4020 = 7`): **[I]** it looks like a duration counter; at 24 MHz iterations I and II are 20.29 s and 20.03 s, III 9.60 s (at 100 MHz: 4.9, 4.8, 2.3 s). The clock is unknown. If 24 MHz, macOS holds the link ~20 s before PME_Turn_Off, then retries (a fixed wait for an endpoint that never gets enumerated, **[I]**); III was shorter, so it is not a fixed timer (or the capture was stopped).

### 1.2 PMGR (window 0x280900100+0x200, ps group 1; names from ADT `/arm-io/pmgr devices`)

Reads at first sight (L1402-1429), i.e. the state iBoot/m1n1 leave **[F]**:

| device (addr) | first read | decode |
|---|---|---|
| APCIE_GP (0x280900118) | `0xff` | active, no flags, no auto |
| APCIE_ST0 / ST1 (0x128/0x130) | `0x2ff` | active, WAS_CLKGATED |
| FAB6_SOC (0x138), ANS (0x140), FAB7_SOC (0x178) | `0xf0000ff` | active, auto state f |
| APCIE_SYS_GP (0x148) | `0x1000030f` | target f, **actual 0**, AUTO_ENABLE, was pwr+clk gated (idle, auto-PM) |
| APCIE_SYS_ST0 (0x150) | `0x1f0003ff` | active (storage) |
| APCIE_SYS_ST1 (0x158) | `0x1000030f` | auto-idle |
| APCIE_SYS_GP_OC / ST0_O / ST1_O (0x160-0x170) | `0x300` | off |
| APCIE_PHY_SW (0x1b0) | `0x1400024f` | target f, actual 4 (clock-gated), AUTO_ENABLE, auto state 4 |
| APHY_ST0/ST1/GP_AUS5_A (0x240/0x248/0x258) | `0x2ff` | active |
| APHY_ST0_AUS5 (0x268) | `0x1f0003ff` | active |
| APHY_ST1_AUS5 / GP_AUS5 (0x270/0x280) | `0x1000030f` | auto-idle |

Writes (all of them; **no PS target is ever raised, no device is powered up, no APCIE_* access after L1581**):
- Pattern per device with a flag/active byte, same as the PMGR die-0 sweep already seen for UART/SIO: `R, R, W (v & ~0x300), R, W (v | 0x10000000)`.
- APCIE_GP L1475-79: `0xff -> 0xff -> 0x100000ff`. APCIE_ST0 L1480-84 and APCIE_ST1 L1485-89: `0x2ff -> 0xff -> 0x100000ff`. FAB6_SOC L1490-94 and ANS L1495-99 and FAB7_SOC L1506-10: `0xf0000ff -> 0xf0000ff -> 0x1f0000ff`. APHY_ST0/ST1/GP_AUS5_A L1517-31: `0x2ff -> 0xff -> 0x100000ff`.
- APCIE_SYS_GP/ST0/ST1, APCIE_PHY_SW, APHY_ST0/ST1/GP_AUS5: **read twice, never written** (L1500-1537).
- Later PMGR traffic in the window (L3060-3174, L3469-3535, L4877-4898) is ISPSENS0, GLOBAL_AUX_HPD_0/1, I2C0/I2C5/I2C6, SCODEC: not PCIe.
- **[I]** macOS relies on auto-PM (AUTO_ENABLE) to ramp APCIE_SYS_GP / APCIE_PHY_SW / APHY_GP_AUS5 when the shared PHY is accessed (L1626 onwards). I cannot see their state during the training because they are not re-read.
- **[REF]** m1n1 0023 stage A raises these three to target f with auto off and polls AUS5 top `+0x94` bit 1; Linux 0094 keeps the six-device chain always on with auto-PM off. Both are stricter than macOS, not contradicted by it.

### 1.3 GPIO (gpio0.pcie = 0x29c000000, pad n at +4n, IRQ regs at +0x800..)

Pad register layout used: [REF `pinctrl-apple-gpio.c`] bit0 DATA, 3:1 MODE (1 OUT, 7 IN/IRQ off; DATA reads the pin level when not OUT), 6:5 PERIPH, 9 INPUT_ENABLE, 18:16 GRP. Bit 4 is not defined there.
Roles **[ADT]**: `pci-bridge0 function-perst` = GPIO 0x50 (80), `function-clkreq` = GPIO 0x4c (76, flags 2); `pci-bridge1` perst 0x51 (81), clkreq 0x4d (77); `/arm-io/apcie0 function-debug_gpio` = GPIO 0x6d (109). **The earlier guess (PERST# at +0x140, CLKREQ# at +0x130) is confirmed** by the ADT and by the traffic.

Order [F]:
1. L1136-1200, 1205-1351 (+L1201-1204): ascending read of all 216 pad registers (pc `…86c8`). Boot values: pad 80 `0x76a02` (OUT, data 0: PERST# asserted), pad 81 `0x76a02`, pads 76/77 `0x76a21` (PERIPH 1, level high), pads 58-75 `0x76a21`/`0x76221`/`0x76a20`.
2. L1352-1400: `W 0xffffffff` to 49 IRQ registers (`0x800..0x818`, `0x840..` ... `0x998..`: seven words in each of seven groups): ack/clear all pad IRQ state. (pc `…87c0`)
3. L1602-1624, **before any root-complex register is touched**:
   - pad 52 (`spi4` cs0) `0x80422f -> 0x804202` (unrelated).
   - **pad 80 PERST#0 `0x76a02 -> 0x76a00`** (L1604-05): OUT-low to MODE 0 (not OUT). A later read at L3573 returns `0x76a00` (DATA = 0). **[I]** In non-OUT modes DATA is the pin level (Linux `apple_gpio_get`), so the line reads low, i.e. PERST# stays asserted from boot until the release (held low outside the SoC). Pad 81 PERST#1 the same (L1608-09).
   - **pad 76 CLKREQ#0 `0x76a21 -> 0x76a11`** (L1606-07), pad 77 (L1610-11). PERIPH 1 -> 0 and bit 4 set, DATA stays 1 (CLKREQ# idle high). The same `0x…21 -> 0x…11` change is applied to pads 58/59 (L1615-18), 70/71 (L1619-22), 68/69 (L3145-52), 60-67 (L3146-3182), 72-75 (L3183-3190). **[I]** a 20-pad CLKREQ#-class group (58-77); only 76/77 are named in the ADT.
   - pad 109 `debug_gpio` `0x7000e -> 0x70002 -> 0x70202` (OUT low, then input-enable).
   - pad 143 `0x76a03 -> 0x76a03` (L1624), later `0x76a02` (L3090); not named in the ADT.
4. **PERST# release** (iteration I, L3573-3576): lane bit 10 set (`0x2300066f`, L3572), then `R 0x140 = 0x76a00`, **`W 0x140 = 0x76a03`** (OUT high, L3574), `R 0x80 = 0`, **`W 0x80 = 1` LTSSM start** (L3575-76), link-up reads L3577-78. No GPIO access between lane bit 10 and the release; no delay is visible (no timestamps). Port 1 likewise (L3698-3702).
5. **PERST# assert in teardown** (L7231-32, L10167-68): after the PME_Turn_Off L2 poll gave up, `R 0x76a03 -> W 0x76a02` (OUT low), then lane bit 31 clear (L7233-34). Release again at L7821 and L10757 (`0x76a02 -> 0x76a03`) right after lane bit 10 and before LTSSM start. So the steady state is OUT-low/OUT-high only; the `0x76a00` state exists only between boot and the first release.
6. L3455-3559: pad 138 (`spi2/mesa` interrupt) IRQ service (`0x6a0f`, `0x6a05`/`0x6a01`, status `0x810 = 0x400` acked): unrelated.
7. **The `+0x118/+0x11c` (pads 70/71) and `+0x110/+0x114` (pads 68/69) loops** [F]: every round is `R pc …aa7c`, `W pc …aabc`, `R pc …a49c` on one pad, writing back the **unchanged** value `0x76a11`, alternating 71,70,71,70... (and 68,69... earlier). The same read/write helper (`aa7c`/`aabc`) performs the PERST#/CLKREQ# changes above, `a49c` is a read-back. Rounds: pads 68/69 47+47 (L3149-3523), pads 70/71 962+963 (L3488-12285). They fill the waits between PCIe milestones (L3191-3454 and L3457-3523 in iteration I before the lane PHY step, L4899-5690, L5804-7153, L7930-10089, L10883-11908, L11918-12285), plus two short bursts inside post-link-up sequences (L10802-19). **[I]** a periodic pad-config refresh/monitor of the CLKREQ#-class pads, not an N1 handshake and not a poll for a value to change (the value never changes). They cost ~6k hv traps; use `gpio` mode output to skip them.

### 1.4 Shared GP PHY init (iteration I only, L1625-1656)

Identical to the previous decode (previous section 1.2): `rc+0x04 = 0`; phy-ctl `+0x00` bit 26 clear; lane regs 18/24/30/36 `+0x00` bit 28 clear (`0x33000070 -> 0x23000070`); `phy+0x4000` read (`0x80300000`); phy-ctl `+0x04` bit 4 set (`0x20 -> 0x30`), `+0x08` poll (`0x10` x7, then `0x11`; L1639, L1642-48), `+0x04` bit 5 clear; `phy+0x4000 |= 1`; phy-ctl `+0x00` bit 27 set (`0xf3c030dc -> 0xfbc030dc`); `rc+0x54 = 0x140`, `rc+0x50 = 1`, `rc+0x58` reads 1. **[F]** reg4 (PHY IP), reg5 (AXI2AF), reg6 (pcieclkgen), reg7-15 are never accessed even though the hooks were in before L1625: macOS does not apply `apcie-axi2af/phy/phy-ip/auspma/cio3pllcore/pcieclkgen` tunables in this window.

### 1.5 Port 0 control block and root-port config, in macOS order (iteration I; values raw)

| step | lines | what |
|---|---|---|
| B reset table | L1657-1669 | `0x88=0x110, 0x100=0xffffffff, 0x148=0xffffffff, 0x210=0xffffffff, 0x80=0, 0x84=0, 0x104=0xfffffff0, 0x124=0x100, 0x16c=0, 0x13c=0, 0x800=0x100100, 0x808=0x1001ff, 0x82c=0x10000` |
| RID2SID / MSI clear | L1670-1989 | `0x3000..0x30fc` x64 = 0; `0x3800..0x3bfc` x256 = 0 |
| late table | L1990-95 | `0x130=0x03020000, 0x140=0x10, 0x144=0x253770, 0x21c=0, 0x834=0, 0x83c=0` |
| config tunables | L1996-2003 | `0x140 \|= 1` (0x10 -> 0x11), `0x144` equal, `0x8a8 \|= 1`, `0x8ac \|= 1` |
| APPCLK, reset handshake | L2004-2014 | `0x800 \|= 1`; `0x82c` bit 0 set, `0xa8` poll (0, 1), `0x82c` bit 16 clear; `0x804 = 5` (READY) |
| LTSSM debug unit (reg17) | L2015-21 | `+0x10=2, +0x1c=8, +0x08=0x3fff, +0x0c=0xffffc000, +0x20 \|= 2, +0x14=1` |
| CGDIS | L2022-23 | `0x800: 0x100101 -> 0x100001` (macOS **clears** bit 8) |
| BUSY wait | L2024-32 | `0x208 = 0xc300220c` x4, then `0xab001208` (BUSY clear on the 5th read) |
| **root-port DBI (D)** | L2033-2087 | see below |
| counters, Intr2AXI, reg20/21 | L2088-94 | `0x4020 = 3`; reg19 `+0x80 = 1`; reg20 `+0 = 0xff01` then `0x8000ff01` (was `0x11000`); reg21 `+0 = 0x10` |
| INTMSK, MSI | L2095-2131 | `0x104 = 0xff5527ff`, `0x100 = 0x00aad800`, `0x124 = 1`, `0x16c = 0xfffff000`, `0x170 = 0`, MSI map `0x3800+4i = 0x80000000\|i`, i = 0..31 |
| port 1 same | L2132-2605 | (ECAM L2509-2561) |
| bus-0 enumeration | L2606-2886 | 1.6 |
| error enable, dump | L2887-3053 | `0x78 \|= 0xf`; config dump of both root ports |
| link-start prelude | L3068-3082 | LnkCtl `0x80: 0x400 -> 0xc00` (adds LABIE, bit 11); AER root cmd `0x12c = 0x7`, root status clear (`0x130 = 0xff`); `0x104 = 0xff55270f` (L3079) |
| lane PHY | L3560-3572 | `0x800` read `0x100001`; lane `0x23000070 -> 0x23000071` (CLK0REQ) -> reads `0x75` x2 -> `0x77` (CLK1REQ) -> reads `0x7f` x2 -> `0x6f` (bit 4 clear) -> `0x26f` (bit 9) -> `0x66f` (bit 10) |
| PERST# release, LTSSM, link up | L3573-3578 | pad 80 `0x76a03`; `0x80 = 1`; `0x100` reads `0x1000` x2 |
| post link-up | L3579-3685 | 1.7 |

Root-port DBI sequence (L2033-2087; **matches the ADT tunables** `pcie-rc-tunables` (4 records), `pcie-rc-gen3/4/5-shadow-tunables` (3 records each) [ADT]):

| L | access | value |
|---|---|---|
| 2033-37 | R 00:00.0 `+0x04, +0x34, +0x40, +0x50, +0x70` | `0x100000, 0x40, 0xc9c35001 (PM), 0x807005 (MSI), 0x420010 (PCIe, root port, v2)` |
| 2038-39 | `0x8bc` MISC_CONTROL_1 | `0xbff48 -> 0xbff49` (DBI RO write enable) |
| 2040-41 | `0x78` DevCtl | `0x102810 -> 0x100810` (tunable `0x78 mask 0x7000 = 0`: MRRS 512 -> 128) |
| 2042-43 | `0x194` | `0 -> 2` (tunable mask 2) |
| 2044-47 | `0xb80`, `0xb88` | `0x1d203220 -> 0x1d7f1e1e` each (tunables) |
| 2048-54 | gen3 shadow | `0x890` (sel 0) R/W `0x2000`; `0x154: 0x74747474 -> 0x75757575`; `0x8a8: 0xc001061 -> 0xc000061` |
| 2055-62 | gen4 shadow | `0x890: 0x2000 -> 0x1002000` (sel 1); `0x178: 0x4444 -> 0x5555`; `0x8a8: 0x4001021 -> 0x4000021`; `0x890: 0x1402000 -> 0x402000` |
| 2064-69 | gen5 shadow | `0x1ac: 0x4444 -> 0x5555`; `0x890: 0x2000 -> 0x2002000` (sel 2, **left at 2**); `0x8a8: 0x4059f21 -> 0x4000021` |
| 2070-71 | `0x194` | `2 -> 3` (bit 0; Linux `rc_rmw(0x194, 0, BIT(0))`) |
| 2072-75 | `0x9c` LnkCap2 `0x180003e` (read); `0xa0` LnkCtl2 | `0x45 -> 0x43` (target Gen3); port 1: `-> 0x41` |
| 2076-77 | `0x710` PORT_LINK_CTRL | `0x30120 -> 0x10120` (link mode x2 -> x1) |
| 2078-79 | `0x80c` | `0x301302ff -> 0x301301ff` (lanes 2 -> 1; bit 17 speed-change already set) |
| 2080-81 | `0x7c` LnkCap | `0x737825 -> 0x737815` (max width x2 -> x1; max speed field stays 5) |
| 2082-83 | `0x8bc` | `0xbff49 -> 0xbff48` (lock) |
| 2084-85 | `0x80` | `0x10110000 -> 0x10110400` (LBMIE) |
| 2086-87 | `0x80c` | `0x301301ff` read and written back |

### 1.6 Root-port enumeration, before training (iteration I, L2606-2886)

[F] 00:00.0 and 00:01.0 are both vendor/device `0x100c106b`, class `0x06040001` (PCI bridge), header type 1, no BARs (BAR0/1 write `0xffffffff` read back 0), IO base/limit read 0, prefetch window `0x10001` (64-bit capable). Capability list: PM `0x40`, MSI `0x50` (64-bit), PCIe `0x70` (root port, v2); extended: AER `0x100`, SECPCI `0x148`, PL16 `0x158`, LMR `0x17c`, PL32 `0x18c`, L1SS `0x1b8`, VSEC `0x1c8`, DLF `0x2c8`, PTM `0x2d4`, VSEC `0x2e0`.
Writes: latency timers `+0xd`/`+0x1b = 0x40` (read back 0); **bus numbers `0x18 = 0x20200` (00:00.0: secondary 2, subordinate 2; L2743) and `0x10100` (00:01.0)**; CMD `0x4 = 0x7`; windows closed (`0x1c = 0xf0`, `0x20 = 0xfff0`, `0x24 = 0xfff0`, `0x28 = 0xffffffff`, `0x2c = 0`, `0x30 = 0`). The link is still down; no endpoint config cycle follows.

### 1.7 After link-up, port 0 (iteration I, L3579-3685; same in II/III)

1. L3579-80: LnkSta `0x82` reads `0x3011` (Gen1, x1, DLLLA).
2. L3581-82: lane `0x2300066f -> 0xa300066f` (bit 31, REFCLK CGEN); L3585-86: port `0x2b0 = 0`, then `1` (role unknown).
3. PTM (ADT `enable-ptm`): `0x2dc` R/W 0 (L3583-84); table with index in `0x328` = 0..4 and `(0x318, 0x31c)` = `(0x9c,0x251) (0x4d,0x128) (0x77,0x112) (0x3c,0x8a) (0x1e,0x44)` (reads return `0xa`/`0x12` each time) (L3587-3616); `0x2dc = 1` (L3617-18). **[I]** per-link-rate PTM latency table.
4. `0x98` DevCtl2 `0 -> 0x400` (LTR enable) L3619-20.
5. Error housekeeping L3622-3631: DevCtl `0x78: 0x81f -> 0x817`; `0x114 = 0x8000`; `0x104 = 0x100000`; `0x110 = 0xa000`; `0x114 = 0`; DevSta `0x7a = 0x9`; DevCtl `0x78 = 0x81f`.
6. **Windows, L3632-3659: first all closed again, then the prefetchable window `0x24 = 0x82008000` (base `0x80000000`, limit `0x820fffff`), `0x28 = 0`, `0x2c = 0`; memory window `0x20 = 0xfff0` (closed).** In II/III macOS restores the saved value `0x82018001` (the same window with the 64-bit bits) at L7767.
7. L1SS: `0x1c4 = 0`, `0x1c0 = 0x4055000f` ( = ADT `pci-l1ss-enable`), then LnkCtl `0x80: 0xc00 -> 0xc02` (ASPM L1, = ADT `pci-aspm-default` 2) L3678-3681.
8. L3682: INTSTAT ack `0x100 = 0x1000`. L3685: **RID2SID `0x3004 = 0x80010200`** (valid, SID 1, RID 0x200 = 02:00.0).
9. No LnkCtl2/LnkCtl retrain for port 0 (port 1 does retrain to Gen2, L3769-72, because its ADT endpoint node says `expected-link-speed 2`; the N1 nodes have none). [F]

### 1.8 Teardown (port 0, iteration I L7154-7273; II L10090-10209)

1. L7154-7199: read-back (save) of the root-port config: header, caps, `0x1c0/0x1c4`, AER `0x118/0x10c/0x108/0x114/0x12c`, `0x78/0x80/0x98/0xa0/0xa8`, PTM `0x2dc`.
2. `0x4020 = 7`, counters `0x4000..0x401c`; `0x104 = 0xff5527f0`; `0x100 = 0xf0`; CMD `0x4 = 0`; bus numbers `0x18 = 0`; `0x800 = 0x100101` (CGDIS set); **`0x88 = 0x11`** (PME_Turn_Off), `0x88` reads `0x1`, `0x10`; `0x208` x10 = `0x9b001001` (no L2) (L7221-30; II L10157-66).
3. **PERST# assert** (L7231-32), lane bit 31 clear (L7233-34); `0x804 = 0xd`, `0x820 = 0`; `0x13c`: `0 -> 0x100`; **`0x728` PORT_DEBUG0 reads `0xc9c311` (II: `0x67c311`): LTSSM state field `0x11` = L0, i.e. the link is still in L0 after PME_Turn_Off and PERST#** (L7239); `0xa8` reads 1 then `0x10001`; `0x82c` `0x1 -> 0x1000001 -> 0x1010001 -> 0x1010000 -> 0x10000`; `0x13c -> 0`; lane clears `0x66f -> 0x26f -> 0x06f -> 0x07f -> 0x07e -> (read 0x7a) -> 0x078`; `0x100 = 0xffffffff`; `0x800: 0x100101 -> 0x100100`; `0x804` reads `6` x2.
4. L7273: RID2SID `0x3004 = 0x80010200`, then the reset table again (L7276). Matches Linux `reset_root_port` + `port_disable` step for step (CMD 0 and bus-number clear included).

### 1.9 What macOS does with a never-enumerated N1

**[F]** After post-link-up config (iteration I L3685) and until the next teardown, the only PCIe-related traffic is the ECAM snapshot taken for teardown. No config cycle to bus 2, no DART access, no BAR window access (none of those windows is in the trace except ECAM). **[I]** Because this run has no root volume, the N1 driver stack is not available; macOS's port-control owner times out (the counter says ~20 s if 24 MHz), powers the port down and tries again, three times. `terminate-missing-endpoint` and `manual-enable` are both set on bridge0 [ADT].

## 2. The N1 endpoint

**[F] No accesses.** Everything macOS knows about the endpoint comes from ADT and from the bridge programming:

| item | macOS in this trace | live-macOS scan (previous decode) |
|---|---|---|
| ID / BAR sizes / command | not read | control BAR0 64 KiB, second BAR 32 MiB, alpha 64 KiB, beta 64 KiB |
| bus / RID | root port secondary 2 -> RID `0x200` (function 0 only routed: slot 1 `0x80010200`) | n/a |
| bridge window | prefetch `[0xb80000000, 0xb820fffff]` bus `0x80000000..0x820fffff`, 64-bit flags (`0x82018001`); mem and I/O windows closed | not recorded |
| control BAR `0xb84020000` | outside the window | `0xb84020000` |
| 32 MiB BAR `0xb82000000` | start is inside, 32 MiB end (`0xb83ffffff`) is not | `0xb82000000` |
| alpha `0xb84010000`, beta `0xb84000000` | outside the window | those addresses |
| MSI / MSI-X, link control, vendor caps, MAC capability | none | n/a |

- **[F]** Window size `0x2100000` = 32 MiB + 1 MiB; port 1's window is `mem [0x82100000, 0x821fffff]` (`0x20 = 0x82108210`, L3740), placed directly after it. Both come from the 1 GiB 32-bit range `bus 0x80000000 -> CPU 0xb80000000` [ADT `ranges`].
- **[I]** The live layout needs `[0xb82000000, 0xb840fffff]`, which is also exactly 33 MiB, i.e. the same sizes shifted up by 32 MiB. So the window here is a pre-sized provisional one (the sizes are known before enumeration, **[I]** from IOKit built-in-device data, not from a config read); the live boot placed the same 33 MiB 32 MiB higher (allocation order or a 32 MiB reservation differs). All N1 BARs are therefore prefetchable in macOS's plan (non-prefetchable window closed). Our DT ranges (`0x02000000` 32-bit window at `0x80000000`, `0x43000000` 64-bit prefetchable window at `0xbc0000000`) are the ADT ones; I did not check where the kernel's PCI core places the N1's prefetchable BARs, only that macOS's plan keeps them in the 32-bit range.
- **[ADT]** The N1 functions macOS expects: `centauri-control` (unit 0), `centauri-alpha` (unit 1; carries a local MAC: present, not copied), `centauri-beta` (unit 2); all with `pci-aspm-default 2`, `pci-skip-rematch-reset`, `pci-max-latency 0x10081008`; control also `pci-l1ss-enable` and `mem-io-timeout`. RID2SID has only slot 1 programmed (RID `0x200`) in the log; routes for functions 1/2 would be added when their `function-dart_request_sid` calls happen (not in the trace).

## 3. Merged checklist for our Linux/m1n1 N1 training (previous 19 + new)

Columns: macOS order and value | ours today (m1n1 0022-0028, kernel K1) | mark. Items are in macOS order within each block; 1-19 keep the previous numbering.

| # | macOS (this trace) | ours | mark |
|---|---|---|---|
| 1 | reset table `0x104 = 0xfffffff0` (L1663, L7282, L10218) | Linux `0xfffffff0`; m1n1 0023 `0xffffffff` | we differ (m1n1 only): use `0xfffffff0` |
| 2 | RID2SID (`0x3000` x64) and MSI map (`0x3800` x256) cleared, then RID2SID slot 1 rewritten | Linux clears and rewrites; m1n1 leaves | we differ (m1n1 only) |
| 3 | APPCLK `0x800`: EN set, then **bit 8 (CGDIS) cleared** (L2023); set again at teardown (L7217) | both set bit 8 and keep it | we differ; effect unknown, try clearing before LTSSM start |
| 4 | lane `+0x00` bit 31 **set after link-up** (L3582, L7829, L10765), cleared in teardown | not done for T6050 | we differ |
| 5 | lane regs 18/24/30/36 bit 28 cleared (L1628-35) | m1n1 FAILs if set | we differ |
| 6 | shared PHY ctl `+0x00` bit 26 cleared first (L1626-27) | not done | we differ |
| 7 | PHY/AXI2AF/AUS5/pcieclkgen tunables **not applied by macOS** in this window (hooks were in before L1625) | m1n1 S and kernel train apply them | open: compare live register values with the ADT lists at guest entry (section 4) |
| 8 | LTSSM debug unit (reg17) 6 writes; `0x4020 = 3` at enable, `7` at disable | `0x4020 = 3` only in some paths | optional; counter0 gives a link-duration number |
| 9 | reg20 `+0 = 0xff01` then `0x8000ff01`; reg21 `+0 = 0x10`; reg19 `+0x80 = 1` (L2089-94, L7700-21, L10636-57) | reg19 yes, reg20/21 no | we differ; unknown block, copy and test |
| 10 | INTMSK `0xff5527ff` -> `0xff55270f` before start (II/III `0xff552700`); MSICFG `0x124 = 1`; MSIADDR `0xfffff000` | kernel `reset_root_port` rewrites | fine, m1n1 does not need it |
| 11 | link-up read through INTSTAT bit 12, first read after start; no LINKSTS poll | LINKSTS bit 0 poll | equivalent |
| 12 | **PERST#: input (mode 0) from L1605 until release; release = OUT-high write (`0x76a03`) right after lane bit 10, two events before LTSSM start; assert = OUT-low after the PME_Turn_Off wait, before lane bit 31 clear.** SMC `gP13`/`bpli`: still not traced | m1n1 requires `0x202` at entry, writes `0x203`; Linux `gpiod_direction_output` | we do this already (PERST# order matches); SMC side still unknown |
| 13 | RID `0x200` (bus 2) because port 1 took bus 1; slot written after link-up in I, before training in II/III | m1n1 assumes bus 1 / RID `0x100`; Linux DT `iommu-map` | only matters if port 1 is ever enabled |
| 14 | MSI map base 0, 32 vectors | DT `msi-ranges` slice | n/a |
| 15 | PME_Turn_Off `0x88 = 0x11`: bit 0 clears, **L2 never set (10 reads, all three iterations)**, `0x728` still reads LTSSM L0; macOS continues with PERST# assert | Linux waits L2 up to 500 ms and errors | we differ: do not fail on missing L2 for the N1 |
| 16 | teardown order `0x13c`, `0xa8`, `0x82c` bits 24/16/0, lane clears, EN clear, READY clear; PERST# assert and lane bit 31 clear first | same in `port_disable`/`reset_root_port` | we do this already |
| 17 | re-enable of port 0 repeated (II, III) without shared init; root-port config saved before and restored after | Linux `reset_root_port` + PCI core restore | we do this already |
| 18 | `0xa8` bit 0 poll after `0x82c` bit 0 set | same | we do this already |
| 19 | root-port DBI tunables / Gen3 x1 / LBMIE: **now compared, same records and values** (1.5); `0x194` 0 -> 2 -> 3; `0x80c` lanes `0x301301ff`; speed-change bit 17 already set | m1n1 stage D / Linux `port_configure` | we do this already |
| 20 | gpio ack-all IRQ status (L1352-1400) | pinctrl driver | n/a |
| 21 | PMGR: flag clear + AUTO_ENABLE sweep on APCIE_GP/ST0/ST1, FAB6_SOC, ANS, FAB7_SOC, APHY_*_AUS5_A; **no power-up writes**; SYS_GP/PHY_SW/AUS5 left auto-idle | m1n1 raises three to f with auto off; Linux always-on, auto off | we differ (stricter); macOS shows auto-PM is enough |
| 22 | CLKREQ#-class pads 58-77 moved `0x…21 -> 0x…11` (PERIPH 1 -> 0, bit 4 set) before RC init; includes pad 76 (N1 CLKREQ#) | pads untouched | new: test (matters only for L1.x / refclk gating; Linux runs no ASPM) |
| 23 | debug_gpio pad 109 `0x7000e -> 0x70002 -> 0x70202` | not done | new, probably irrelevant |
| 24 | root port enumerated **before** training: bus numbers (sec 2), CMD `0x7`, windows closed, latency timers (L2606-2886) | PCI core does it after the link is up | new, no action |
| 25 | after link-up: PTM table (`0x2dc`, `0x318/0x31c/0x328`), DevCtl2 LTR `0x400`, AER clears (`0x104/0x110/0x114`, DevSta `0x7a`), AER root cmd `0x12c = 7`, DevCtl `0x78 |= 0xf` (extended tag `0x20` from II on), LnkCtl bit 11 (LABIE) | not done | new, low priority |
| 26 | L1SS ctl1 `0x4055000f` and ASPM L1 `0xc02` on the root port (ADT `pci-l1ss-enable`, `pci-aspm-default`) | no ASPM on adopted ports | we differ on purpose |
| 27 | bridge window written before any endpoint: prefetch `[0x80000000, 0x820fffff]`, 64-bit, mem/IO closed | PCI core allocates | new/informational (2) |
| 28 | LnkCtl2 target Gen3 in iteration I, **Gen1 in II/III**; link is Gen1 x1 in all; no retrain for port 0 (port 1 retrains to Gen2 from its ADT `expected-link-speed`) | target Gen3 + retrain after ROM boot | informational: the N1 ROM is Gen1 only |
| 29 | `0x2b0 = 0` then `1` after lane bit 31 (L3585-86) | not done | new, role unknown |
| 30 | port counter0 `0x4000` at teardown: 486,987,015 / 480,619,837 / 230,459,386 | not read | new, optional diagnostic |

## 4. Open questions and exact next traces

Open:
1. **What triggers macOS's ECAM probe of bus 2?** In this run it never happens. Candidates **[I]**: the endpoint driver stack (absent: no root volume), a firmware-personalization step, or the port owner's 20 s window expiring first. The same capture with a root volume (dext/kext can launch) is the experiment.
2. Is the PHY-tunable state at guest entry already equal to the ADT lists? (item 7)
3. What does PERST# mode 0 do on the board (pad reads low, so held low externally) and what is the CLKREQ# `0x…11` setting for? (items 12, 22)
4. SMC `gP13` / `bpli` order relative to the root-complex steps (still invisible).
5. Which pads 58-77 belong to which ports, and what are the 70/71 and 68/69 loops for? Nothing in the ADT names them.
6. Counter0 clock rate (24 MHz vs 100 MHz) decides whether "~20 s" is real.
7. Why the bridge window starts at `0xb80000000` here and `0xb82000000` in the live scan.

Next trace ranges (CPU addresses; the hv works in 16 KiB units):
- **Same group again with the root volume present**, ECAM `0x1cb0200000..0x1cb0203000` (bus 2, functions 0-2, already in the window; bus 1 `0x1cb0100000..0x1cb0101000` for the SD reader). Keep the 0x300000 window; the endpoint traffic is a handful of dwords per function.
- **BAR windows once assigned**: control `0xb80000000..0xb80010000` and `0xb82000000..0xb82010000` (provisional vs live base); live-scan addresses `0xb84000000..0xb84030000` (beta, alpha, control); 32 MiB BAR first pages at `0xb80000000` and `0xb82000000`; whichever the bridge `0x24` write says.
- **DART for apcie0**: `dart-apcie0` `0x410000000+0x20000` and the second window `0x2803f0000+0x4000`; PIO DMA `0x410030000`, `0x410034000`, `0x410038000` (+0x4000 each). Use the `darts` style (write-only is enough for TTBR / stream enables).
- **SMC**: `/arm-io/smc` mailbox (`reg0 0x28c600000`, `reg1 0x28c050000`, `reg2 0x28c810000`) with `HV27_TRACE=smc` and `mbox-decode.py --dev smc`, to time `gP13` and `bpli` against `gpio0 +0x140`.
- **PHY tunable windows at guest entry**: a read-only dump (not a trace) of reg4 `0x417800000`, reg5 `0x416000000`, reg6 `0x415044000`, reg10/11 `0x417980400/0x417980800` compared with the ADT tunable lists (`tunables_check_local_addr` in m1n1 0023 does this) before the guest runs.
- **GPIO**: keep `0x29c000000+0x4000` but note the pad 68-71 loop is 55% of the traffic; if the overhead matters, trace writes only. IRQ pads are not needed.
- **Timing**: run SYNC mode (`HV27_TRACE_MODE=sync`) or add the arch-timer value to each print once, to put numbers on PERST# low time, lane bit 10 -> PERST# -> LTSSM, link-up, and the ~20 s window.
