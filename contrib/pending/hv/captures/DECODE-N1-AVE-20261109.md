# apcie0 (N1) and ave0 MMIO decode: macOS 27.3 single-core boot on J716s (T6050)

Input: `captures/trace-cpus1-ave-n1-20261109-0129.log` (3,931 lines; 2,752 MMIO events (2,137 apcie0, 615 ave0) plus 44 PMGR-hook lines; ASYNC trace, no timestamps; last line L3931 is a half-finished register-table write, so the capture was cut). Helper: `captures/n1-ave-decode.py` (`python3 -I n1-ave-decode.py LOG apcie|ave`). Offline only.

Labels: **[F]** fact read from the log (raw words quoted), **[I]** inference, **[ADT]** from `studio-artifacts/adt-runtime-j716s.bin`, **[REF]** from our m1n1/Linux sources. `Lnnnn` = log line number. No ADT serial/MAC-like value is quoted.

Address note [F]: the Python ADT reader prints bus addresses (apcie0.reg1 = `0x214000000`); the trace and m1n1 print CPU addresses = bus + `0x200000000` (arm-io `ranges`: child 0 -> parent 0x200000000, size 0x3c0000000). Both name the same registers. The 256 MiB ECAM (`0x1cb0000000`) is outside that range and is not translated.

Hook set [F]: `hv27-trace.py` group `n1` = apcie0 reg[1..39] only (ECAM reg[0] not traced). The hooks went in "late" (L585, at the first SPTM AMCC read). Every traced range is unmapped from the guest and emulated, so each access is a trap.

## 0. Summary

- **[F] Port 0 (the N1) is brought up by macOS exactly three times in the window, and the link came up each time it was observed.** Evidence: `INTSTAT(0x100) = 0x1000` (LINK_UP) pending at L2333 and L3852, `LINKSTS(0x208) = 0x9b001001` (bit0 UP, bit2 BUSY clear) read 10x at L3357 and L3877. The third bring-up starts at L3926 and the trace ends 6 events later.
- **[F] Each bring-up is followed by a port teardown within the same iteration.** After link-up the only MMIO is a counter read-out (`0x4000..0x401c`) and then the PME_Turn_Off teardown. Everything between (ECAM config cycles, DART, BAR assignment, firmware load) is not in the traced windows.
- **[F] PME_Turn_Off never completes for port 0.** `0x88 = 0x11`, then ten reads of `LINKSTS = 0x9b001001`; bit 6 (L2) never sets (L3357-3366 and L3877-3886). Port 1 (SD reader) reaches `0x9b00134d` (bit 6 set) at the first read (L3299). macOS then continues without retrying.
- **[F] macOS never touches the shared PHY tunables in the window.** Zero accesses to reg4 (PHY IP), reg5 (AXI2AF), reg6 (pcieclkgen), reg7-15 and the AUS5 pair (reg10/11). So no `apcie-axi2af/phy/phy-ip/auspma/cio3pllcore/pcieclkgen` tunable writes, and no APCIE_* PMGR power-chain accesses in the log (the existing PMGR hook only printed ATC0_COMMON/FAB8_SOC/SIO/UART/ATC0_USB on die 0; whether it would print an APCIE_* access is not verified). Either iBoot/earlier code did them, or macOS does them before the hook was installed. **Open question, see section 3.**
- **[F] The PERST# pad (gpio0 pad 80, `0x29c000000 + 4*80`), CLKREQ# (pad 76) and the SMC `gP13`/`bpli` writes are not in any traced window**, so "chip reset" / "warm reset" cannot be seen here; only the root-complex side of "PCI configuration apcie0" can.
- **[F] ave0: no firmware boot.** The only AVE-owned MMIO is a one-off power-up of VENC0_SYS with 128 register read-modify-writes in reg0 `0xdc000-0xdc868` and one write to reg2 `+0x118`, then power-down. reg1 (`0x2283800000`, 8 MiB) and reg4 are never touched. Most of "ave0.reg3" is die-1 PMGR PS registers, not an AVE block (section 2).

## 1. apcie0

### 1.1 Register map, role and what macOS did

ADT: `/arm-io/apcie0`, compatible `apcie,t6050`, `#ports` 4, 40 reg entries = 16 shared + 6 per port x 4. Only `pci-bridge0` (port 0, `centauri-builtin`, `function-perst = GPIO 80`, `function-reset = pKW4 gP13 0x00800000`, `function-warm_reset = pKW4 bpli 0x01000000`, `maximum-link-speed 3`, `msi-vector-base 0`) and `pci-bridge1` (port 1, SD reader, `maximum-link-speed 1`, `manual-enable-s2r`, `msi-vector-base 32`) exist; ports 2 and 3 have no bridge node.

Role column: names agree with m1n1 `pcie_t6050.c` (REG_* defines) and the J716s DT (`reg-names`) where those exist; **[I]** where the role comes from the access pattern only.

| reg | trace address (+size) | role | R / W in window | what macOS does there |
|---|---|---|---|---|
| 0 | `0x1cb0000000` (+0x10000000) | ECAM (not traced) | n/a | |
| 1 | `0x414000000` (+0x4000) | RC common ("rc") | 2 / 3 | `+0x04=0` (lane-cfg 0); `+0x54=0x140`; `+0x50` 0 -> 1 (RC run); `+0x58` reads 1 (ready) at once |
| 2 | `0x417000000` (+0x800000) | PHY window; common block at `+0x4000` | 2 / 1 | only `+0x4000`: `0x80300000` (bit31 refclk ok) then `|1` = `0x80300001` (refclk enable) |
| 3 | `0x417020000` (+0x4000) | shared GP PHY control ("phy-shared", m1n1 "H") | 21 / 4 | `+0x00`, `+0x04`, `+0x08`, see 1.2 |
| 4 | `0x417800000` (+0x1b4000) | PHY IP (pll/auspma tunable target) | 0 / 0 | none |
| 5 | `0x416000000` (+0x1000000) | AXI2AF | 0 / 0 | none |
| 6 | `0x415044000` (+0x4000) | pcieclkgen (cio3pllcore / pcieclkgen tunables) | 0 / 0 | none |
| 7,8,9,14,15 | `0x487000000`/`0x487020000`/`0x486000000`/`0x487020000`(+0x10000)/`0x487800000` | **[I]** second (storage, APCIE_ST*) PHY complex: PHY window, PHY ctl, AXI2AF, PHY ctl (big), PHY IP | 0 / 0 | none |
| 10,11 | `0x417980400`, `0x417980800` (+0x4000) | AUS5 top / aon of the GP PHY (m1n1 REG_AUS5_TOP/AON) | 0 / 0 | none |
| 12,13 | `0x415980400`, `0x415980800` | **[I]** the same pair for the second complex | 0 / 0 | none |
| 16 | `0x410028000` (+0x8000) | port 0 control block | 117 / 826 | main subject of 1.3 |
| 17 | `0x41003c000` (+0x4000) | **[I]** port 0 LTSSM debug/trace unit (compare m1n1 pcie.c "port N LTSSM debug"); the same unit on port 1 (reg23) is read back as an LTSSM history, see 1.5 | 2 / 12 | config only for port 0: `+0x10=2`, `+0x1c=8`, `+0x08=0x3fff`, `+0x0c=0xffffc000`, `+0x20` RMW to 2, `+0x14=1` |
| 18 | `0x417010000` (+0x4000) | port 0 lane PHY (`PHY_LANE_CFG`) | 43 / 27 | 1.3 step 12 |
| 19 | `0x410024000` (+0x4000) | port 0 Intr2AXI | 0 / 2 | `+0x80 = 1` (PCIEC_INTR2AXI_ENABLE) |
| 20 | `0x410048000` (+0x4000) | **[I] unknown**, no Linux/m1n1 user | 4 / 4 | `+0x00`: iter A `0x11000` -> `0xff01` -> readback `0xff01` -> `0x8000ff01`; iter B `0xff01` -> `0xff01` -> `0xff01` -> `0x8000ff01` |
| 21 | `0x410044000` (+0x4000) | **[I] unknown** | 0 / 2 | `+0x00 = 0x10` |
| 22-27 | port 1: ctl `0x411028000`, LTSSM dbg `0x41103c000`, lane `0x417014000`, i2axi `0x411024000`, `0x411048000`, `0x411044000` | same roles for the SD reader | 22: 514/403, 23: 50/39, 24: 25/15, 25: 0/1, 26: 3/2, 27: 8/1 | same as port 0 plus a full read-out (1.5) |
| 28-33 | port 2 (`0x412...`) | no bridge node | 0 / 0 | none (its lane reg30 `0x417018000` is touched once, below) |
| 34-39 | port 3 (`0x413...`) | no bridge node | 0 / 0 | none (lane reg36 `0x41701c000` touched once) |

All 2,137 apcie0 accesses come from two guest PCs only: `0xfffffe003dc5bf68` (32-bit read helper) and `0xfffffe003dc5c238` (write helper); no information on the caller.

### 1.2 Shared GP init (iteration A only, L1415-L1455)

Executed once, at the start of the first bring-up; never again in the window.

| L | access | value | note |
|---|---|---|---|
| 1415 | W rc+0x04 | 0 | lane-cfg 0 (m1n1 `write32(rc+4,0)`) |
| 1416-17 | R/W phy-ctl+0x00 | `0xf7c030d0` -> `0xf3c030d0` | clears bit 26. **Not in m1n1 0023.** |
| 1418-25 | R/W lane regs 18, 24, 30, 36 `+0x00` | `0x33000070` -> `0x23000070` each | clears bit 28 on all four lanes, incl. unused ports 2/3. m1n1 only FAILs if bit 28 is set |
| 1426 | R phy+0x4000 | `0x80300000` | refclk ok (bit 31), no wait loop visible |
| 1427-28 | R/W phy-ctl+0x04 | `0x20` -> `0x30` | set bit 4 (Gen5 PHY start) |
| 1429 | R phy-ctl+0x08 | `0x10` | bit 4 set at the first read |
| 1430-31 | R/W phy-ctl+0x04 | `0x30` -> `0x10` | clear bit 5 |
| 1432-47 | poll phy-ctl+0x08 | `0x10` x15, then `0x11` | 16 reads until bit 0 sets |
| 1448-49 | R/W phy+0x4000 | `0x80300000` -> `0x80300001` | refclk enable |
| 1450-51 | R/W phy-ctl+0x00 | `0xf3c030dc` -> `0xfbc030dc` | set bit 27 (low nibble moved `0x0` -> `0xc` by hardware between the two reads) |
| 1452-55 | W rc+0x54=0x140; R rc+0x50=0; W rc+0x50=1; R rc+0x58=1 | | RC run/ready, first read ready |

Same as m1n1 0023 stage S (and upstream t602x) except the bit-26 and lane-bit-28 clears, and except that the tunable/AUS5/AXI2AF steps that surround it in m1n1 do not appear.

### 1.3 Per-port bring-up, in order (port 0 = reg16/17/18/19/20/21; port 1 identical with reg22-27)

Iteration A runs ports 0 and 1 back to back, then interleaves the lane and LTSSM steps. Line numbers below are port 0 in iteration A unless stated.

1. **Reset table** (L1456-1468), writes: `0x088=0x110, 0x100=0xffffffff, 0x148=0xffffffff, 0x210=0xffffffff, 0x080=0, 0x084=0, 0x104=0xfffffff0, 0x124=0x100, 0x16c=0, 0x13c=0, 0x800=0x00100100, 0x808=0x001001ff, 0x82c=0x00010000`.
2. **RID2SID clear** `0x3000..0x30fc` = 0 (64 words, L1469-1532); **MSI map clear** `0x3800..0x3bfc` = 0 (256 words, L1533-1788).
3. **Late table** (L1789-1794): `0x130=0x03020000, 0x140=0x10, 0x144=0x253770, 0x21c=0, 0x834=0, 0x83c=0`.
4. **Config tunables as read-modify-write** (L1795-1802; ADT `apcie-config-tunables` has 4 records: `0x140 |=1`, `0x144 mask 0xffffff = 0x253770`, `0x8a8 |=1`, `0x8ac |=1`): R `0x82c`=0x10000; R `0x140`=0x10 -> W `0x11`; R `0x144`=0x253770 (no write, already equal); R `0x8a8`=0 -> W 1; R `0x8ac`=0 -> W 1.
5. **App clock** (L1803-04): R `0x800`=0x100100 -> W `0x100101` (EN).
6. **Reset release handshake** (L1805-1813): R `0xa8`=0; R `0x82c`=0x10000 -> W `0x10001`; R reg18+0 = `0x23000070` (lane read); poll `0xa8`: `0x0`, `0x1`; R `0x82c`=0x10001 -> W `0x1` (clears bit 16); R `0x804` = `0x5` (READY, no loop).
7. **LTSSM debug unit config** (L1814-1820, reg17): W `+0x10=2`, `+0x1c=8`, `+0x08=0x3fff`, `+0x0c=0xffffc000`; R `+0x20`=0 -> W 2; W `+0x14=1`.
8. **APPCLK CGDIS cleared** (L1821-22): R `0x800`=0x100101 -> W `0x100001`. **macOS clears bit 8 here; m1n1 0023 and Linux set/keep it.**
9. **BUSY wait** (L1823-1831): R `0x208` interleaved with R reg18+0 (always `0x23000070`): `0xc300220c` x4, then `0xab001208`. Bit 2 (BUSY) clears on the 5th read. Bit 0 (UP) is 0.
10. **Counters / Intr2AXI / reg20,21** (L1832-1838): W `0x4020=3`; W reg19+0x80=1; reg20 and reg21 as in the table above.
11. **Interrupt, MSI setup** (L1839-1875): W `0x104=0xff5527ff`; W `0x100=0x00aad800`; W `0x124=1`; W `0x16c=0xfffff000` (ADT `msi-address`); W `0x170=0`; MSI map `0x3800+4i = 0x80000000|i` for i = 0..31 (port 1: `0x3880+4i = 0x80000020|i`, i.e. vectors 32..63, matching ADT `msi-vector-base` 0 / 32).
12. **[ECAM work, untraced]** Root-port DBI tunables, Gen3 x1 policy, etc. would sit here; the log has a gap of port 1's whole step 1-11 (L1876-2296) and nothing for port 0.
13. **Interrupt unmask** (L2297-98): W `0x104 = 0xff55270f` (port 1, then port 0).
14. **Lane PHY** (L2299-2312, port 0 reg18): `0x23000070` -> W `0x23000071` (CLK0REQ) -> R `0x75` x2 (ack bit 2) -> W `0x77` (CLK1REQ) -> R `0x7f` x2 (ack bit 3) -> W `0x6f` (clear bit 4) -> W `0x26f` (bit 9) -> W `0x66f` (bit 10). Same bits and order as m1n1 stage E / Linux `apple_pcie_t6050_port_train`. No visible delay marker.
15. **LTSSM start** (L2313-14): R `0x80`=0 -> W `0x80 = 1`. **No PERST# access is visible between steps 14 and 15 (gpio0 untraced).**
16. **Link up** (port 0): no LINKSTS poll. First port-0 access after start is `R 0x100 = 0x1000` at L2333 (LINK_UP latched, 19 trapped accesses after the start, mostly port 1 traffic), again 0x1000 at L2335. Port 1: `0x1000` x2 at L2329-30.
17. **After link-up** (L2336-2342): lane `0x2300066f` -> W `0xa300066f` (**sets bit 31, REFCLK CGEN**, L2337); W `0x2b0 = 0` then `1`; W `0x100 = 0x1000` (ack); **RID2SID: W `0x3004 = 0x80010200`** (slot 1: valid, SID 1, RID `0x200` = bus 2 dev 0 fn 0). Port 1: `0x3004 = 0x80010100` (RID `0x100`, bus 1). So macOS numbers the SD-reader bus 1 and the N1 bus 2, with 00:00.0 / 00:01.0 as the two root ports.

Port 1 only (L2343-L2898): R `0x100 = 0x20000800` x2 (bit 11 LINK_BWMGMT + bit 29), the LTSSM history read-out (1.5), and a full 459-read register image (1.5). There is no equivalent read-out for port 0.

### 1.4 What happens to port 0 afterwards (iterations A-C)

| iteration | lines | content |
|---|---|---|
| A | L1415-L2342 (+ port 1 read-out L2343-2898) | shared init, both ports enabled, both links up |
| (ave0 / PMGR die 1 power cycle) | L2899-L3278 | no apcie traffic |
| teardown A | L3279-3338 port 1, L3339-3405 port 0 | PME_Turn_Off, L2 wait, port disable (below) |
| B | L3406-L3858 | **port 0 only** re-enable: RID2SID `0x3004` rewritten (L3406), reset table (L3408-3420), RID2SID/MSI clears, ..., lane PHY (L3838-49), LTSSM start `0x80 = 1` (L3851), `R 0x100 = 0x1000` x2 right after (L3852-53), lane bit 31 (L3855), `0x2b0 = 0,1`, `0x100 = 0x1000` ack (L3856-58) |
| teardown B | L3859-L3925 | as teardown A |
| C | L3926-L3931 | re-enable begins (RID2SID `0x3004`, reset table), trace ends |

Differences between iteration A and B for port 0 [F]:
- B has no shared init, no port 1, and the RID2SID route (`0x3004 = 0x80010200`) is written before link training (L3406, L3781) instead of after (L2341).
- Link-up is already latched at the first `INTSTAT` read after the LTSSM start in B (L3852), i.e. within one trapped access. The N1 was not reset between A and B as far as the traced windows show (gpio0/SMC untraced). Link-down samples before start: `0xc3002204, 0xc3002204, 0xab001200` (L3773-77) vs A's `0xc300220c x4, 0xab001208` (the extra bit 3 is the only difference).

**Teardown sequence (port 0, L3339-L3420, repeated L3859-L3931); matches Linux `apple_pcie_t6050_port_disable` + `reset_root_port` step for step [F/REF]:**
1. W `0x4020 = 7`; read `0x4000..0x401c` (`0x4000 = 0x1cfe6441` in teardown A, `0x1ca4e00c` in teardown B; the other seven = 0).
2. R `0x104` x2 = `0xff552700`; W `0x104 = 0xff5527f0`; W `0x100 = 0xf0`.
3. R `0x800` = 0x100001 -> W `0x100101` (CGDIS set).
4. W `0x88 = 0x11` (PME_Turn_Off); R `0x88` = `0x1`, then `0x10` (bit 0 cleared).
5. Poll `0x208`: port 0 `0x9b001001` x10 (no L2), port 1 `0x9b00134d` x1 (L2 set).
6. Lane reg18 `0xa300066f` -> W `0x2300066f` (clear bit 31).
7. R `0x804` = `0xd`; R `0x820` = 0; R `0x13c` = 0 -> W `0x100`.
8. R `0xa8`=1; R `0x82c`=1 -> W `0x1000001` (bit 24); R `0xa8`=`0x10001`; R `0x82c` -> W `0x1010001` (bit 16); W `0x1010000` (clear bit 0); W `0x10000` (clear bit 24).
9. R `0x13c`=0x100 -> W 0.
10. Lane: `0x2300066f` -> `0x2300026f` (clear bit 10) -> `0x2300006f` (bit 9) -> `0x2300007f` (set bit 4) -> `0x2300007e` (clear CLK0REQ) -> R `0x7a` -> `0x23000078` (clear CLK1REQ).
11. W `0x100 = 0xffffffff`; R `0x800` = 0x100101 -> W `0x100100` (clear EN); R `0x804` = `0x6` x2 (READY clear); R/W `0x100 = 0`.
12. W `0x3004 = 0x80010200` (route re-written), then the reset table (step 1 above).

### 1.5 Values the hardware returned: status and LTSSM

Port 0 [F]:

| register | value | meaning |
|---|---|---|
| LINKSTS `0x208`, link down, before LTSSM start | `0xc300220c` / `0xc3002204` (BUSY set), `0xab001208` / `0xab001200` (BUSY clear) | UP = 0 |
| LINKSTS after link-up | `0x9b001001` (x10 at L3357, x10 at L3877) | bit0 UP, bit2 BUSY clear, bit 12 set, bit 6 (L2) clear |
| INTSTAT `0x100` | `0x1000` (L2333, L2335, L3852-53) | bit 12 LINK_UP |
| STATUS `0x804` | `0x5` after reset release (L1813, L3763), `0xd` in the link-up state (L3369, L3889), `0x6` after disable | bit 0 READY; bit 3 appears with link up |
| `0xa8` (pipe-reset status) | `0x0`, `0x1` while releasing; `0x1` / `0x10001` in teardown | |
| counters `0x4000..0x401c` | first word nonzero (`0x1cfe6441`, `0x1ca4e00c`), rest 0 | no error counts |

**Port 1 (reg22-27) healthy-link image** (L2437-L2898, 459 reads right after link-up; a ready reference for what port 0's registers should look like when up) [F]: `0x00=3, 0x04=1, 0x08=1, 0x0c=0xf0, 0x10=0x8000, 0x14=0x8000, 0x18=0xfff0, 0x20=0xffffffff, 0x80=1, 0xa8=1, 0x100=0x20000800, 0x104=0xff552700, 0x110=1, 0x124=1, 0x130=0x03020000, 0x140=0x11, 0x144=0x253770, 0x14c=3, 0x150=2, 0x16c=0xfffff000, 0x208=0x9b001001, 0x284=0x1000000, 0x2a0=0x40000000, 0x2b4=7, 0x310=0x24, 0x318=0x200004, 0x320=0x40, 0x328=0x2000080, 0x330=0x8000040, 0x338=5, 0x340=0x200900be, 0x800=0x100001, 0x804=0xd, 0x808=0x1001ff, 0x82c=1, 0x838=0x32, 0x884=0x1010101, 0x894=0x10000, 0x8a8=1, 0x8ac=1, 0x3004=0x80010100, 0x3880..0x38fc=0x80000020..0x8000003f`.

**LTSSM history, port 1 only** (reg23 `+0x30..+0x40`, L2346-2427). Procedure: W `+0x38=1`, then for idx 0..15: W `+0x34=idx`, W `+0x38=1`, R `+0x30` (always `0x2010150f`), R `+0x3c`, R `+0x40`. Raw `+0x40` words, idx 0..15: `0x8008000, 0x8008001, 0x8008002, 0x100004, 0x100007, 0x100008, 0x100009, 0x10000a, 0x10000b, 0x10000c, 0x100011, 0x90000d, 0x90000f, 0x90000e, 0x80800d, 0x80800d`; `+0x3c` rises `0xa39e6 -> 0xa42b4`.
**[I]** the low 5 bits follow the DesignWare `smlh_ltssm_state` encoding (0 Detect.Quiet, 1 Detect.Active, 2 Polling.Active, 4 Polling.Config, 7 Cfg.Linkwidth.Start, 8 Linkwidth.Accept, 9 Lanenum.Wait, a Lanenum.Accept, b Complete, c Idle, 0x11 L0, 0xd Recovery.RcvrLock, 0xf Recovery.RcvrCfg, 0xe Recovery.Speed): i.e. Detect -> Polling -> Configuration -> L0 -> Recovery with a speed change, consistent with `INTSTAT bit 11 (BWMGMT)` on port 1. This is the same state numbering Linux uses (`RC_T6050_LTSSM_L1_IDLE = 0x14`). The upper bits are unexplained. **macOS did not read the history of port 0 in this window**, so there are no LTSSM states for the N1.

### 1.6 Differences vs m1n1 0022/0023 (+0025-0027) and Linux pcie-apple: checklist for our N1 training

Sources: m1n1 `contrib/pending/wireless/patches/m1n1/0022` (DT fill-in, `kboot_n1.c`) and `0023` (training, `pcie_t6050.c`, stages A, S, B-G), `0026` (SMC gP13 pulse), `0027` (warm N1); Linux `wt-series/drivers/pci/controller/pcie-apple.c` (`t6050_hw`, `apple_pcie_t6050_*`). 0022 does DT only and trains nothing; the items below are in 0023/0026/0027 or Linux.

| # | macOS (this trace) | m1n1 0023 (+0026/27) | Linux T6050 (adopt / `reset_root_port` / kernel train) | action |
|---|---|---|---|---|
| 1 | reset table `0x104 = 0xfffffff0` | `0xffffffff` (stage B table) | `0xfffffff0` | use `0xfffffff0` |
| 2 | RID2SID (`0x3000`, 64) and MSI map (`0x3800`, 256) cleared in the reset table | **not cleared** ("untouched") | cleared in `port_enable` | clear both, rewrite after link-up |
| 3 | after READY: **APPCLK `0x800` bit 8 cleared** (`0x100101` -> `0x100001`, L1821) before link training; set again only at teardown | sets bit 8 (stays set); Linux adoption check wants `0x800 & 0x101 == 0x101` | sets bit 8 at end of `port_enable`; `retain_clocks` skips the generic clear | try clearing CGDIS before LTSSM start, set it before PME_Turn_Off (matches macOS) |
| 4 | lane `+0x00` bit 31 (CGEN) **set right after link-up** (L2337, L3855), cleared first in teardown | not done | not done for T6050 (`retain_clocks`); generic path sets `PHY_LANE_CFG_REFCLKCGEN` | add after link-up |
| 5 | lane regs bit 28 **cleared on all four lanes** at start (L1418-25) | FAILs if bit 28 set | n/a | clear it instead of failing |
| 6 | shared PHY `H+0x00` bit 26 cleared first (`0xf7c030d0 -> 0xf3c030d0`, L1416-17) | not done | n/a | add before stage S |
| 7 | PHY tunables / AXI2AF / AUS5 / pcieclkgen not touched in the window | S applies `apcie-axi2af-tunables` (78), `apcie-phy-tunables`, AUS5 `+0x5c`/`+0x94` | kernel train applies host tunable lists | decide with a trace of the early boot (section 3); do not assume macOS skips them |
| 8 | LTSSM debug unit reg17: 6 config writes before link training; counters `0x4020 = 3` | not touched | `0x4020 = 3` only in generic/tunnel paths | optional, harmless to copy; gives an LTSSM history for the N1 |
| 9 | reg20 `+0 = 0xff01 then 0x8000ff01`, reg21 `+0 = 0x10` per port | not touched | not touched | **unknown block; copy and test** (probably needed for something on the N1 path, or not) |
| 10 | INTMSK `0xff5527ff` -> `0xff55270f` before LTSSM; MSICFG `0x124 = 1`; MSIADDR `0x16c = 0xfffff000` / `0x170 = 0`; MSI map base 0 | not touched (`0x124 = 0x100` only via table) | `reset_root_port` rewrites MSI map/addr | fine for kernel; m1n1 does not need it |
| 11 | link-up detected through INTSTAT bit 12; no LINKSTS poll | polls LINKSTS bit 0, 500 ms, +100 ms | polls LINKSTS bit 0, 500 ms, +100 ms | equivalent; add an INTSTAT log line for diagnostics |
| 12 | PERST# / CLKREQ# / SMC gP13 / bpli: invisible | GPIO pad 80 written (`0x202|1`) after max(refclk-to-perst, 1 ms); SMC `gP13 = 0x00800000|0, 50 ms, |1, 50 ms, +100 ms` (0026/27) | `gpiod_direction_output(perst)`; gP13 through `pwren-gpios` | **trace GPIO/SMC (section 3)** to see macOS's real order and delays |
| 13 | RID2SID: N1 function 0 route is **RID `0x200` (bus 2)** because port 1 took bus 1 | assumes bus 1, RID `0x100`, endpoint `01:00.0` | DT `iommu-map <0x100 &dart 1 3>` | only matters if port 1 is ever enabled too |
| 14 | MSI map base 0 (32 vectors) | n/a | DT `msi-ranges` slice 64..127 | kernel-side choice, not an N1 issue |
| 15 | PME_Turn_Off: `0x800 |= 0x100`, `0x88 = 0x11`, wait `0x88` bit 0 clear (2 reads), poll L2: **port 0 never reaches L2 (10 reads), macOS goes on** | warm N1: LTSSM off, PERST# asserted, link down within 100 ms | waits L2 up to 500 ms; error return if it never comes | do not fail on a missing L2 for the N1; fall through to PERST# + port disable |
| 16 | teardown order `0x13c`, `0xa8`, `0x82c` bits 24/16/0, lane clears, EN clear, `0x804` READY clear | n/a | same order (`port_disable`) | already matched |
| 17 | port bring-up of port 0 repeated (A, B, C) without redoing shared init | training once per boot | `reset_root_port` does disable/enable/configure/train only | already matched |
| 18 | `0xa8` bit 0 polled after `0x82c` bit 0 set | `CLKRST` bit 0 poll | `0xa8` bit 0 wait | matched |
| 19 | root-port DBI tunables / Gen3 x1 policy / PCIe cap writes | stage D | `port_configure` | **untraced in macOS (ECAM); cannot compare** |

What matches already (do not change): reset table values other than `0x104`; late table (`0x130, 0x140, 0x144, 0x21c, 0x834, 0x83c`); config-tunable RMWs; APPCLK EN, `0x82c` set bit 0 / clear bit 16 handshake; `0xa8` wait; READY wait (`0x804` = 5); lane PHY CLK0/CLK1 req/ack, bit 4 clear, bits 9 and 10; the whole teardown.

## 2. ave0

ADT `/arm-io/ave0` (ave2 video encoder): reg0 `0x2083100000`(+0x45c000), reg1 `0x2083800000`(+0x800000), reg2 `0x2083050000`(+0x4000), reg3 `0x21806001c0`(+0x7e64), reg4 `0x2082000000`(+0x8000); trace addresses are +0x200000000. `pre-loaded = 1`, `segment-names __TEXT;__DATA`, `power-gates`/`clock-gates` = [VENC0_SYS_V (virtual), VENC0_PIPE4, VENC0_PIPE5, VENC0_ME0, VENC0_ME1, VENC0_DMA], one `clock-id`.

Counts in this log [F]: reg0 128 R / 128 W, reg2 0 R / 1 W, reg3 278 R / 80 W, reg1 and reg4 none. That is **406 reads, not 235** (I could not reproduce 235; the 358 reg3 lines include 80 writes).

### 2.1 reg3 is the die-1 PMGR PS-register array, not an AVE block

`0x23806001c0 + off` falls inside the second PMGR block (`/arm-io/pmgr` reg 0x2180600000, +0x1e8000, die 1). Matching the PMGR `devices` table at (`0x2180600000 + 0x1c0 + off`) names every offset. Register layout (m1n1 `hw/pmgr.py`): `[3:0]` target, `[7:4]` actual (0xf active), bit 8 WAS_PWRGATED, bit 9 WAS_CLKGATED, bits 27:24 auto state, bit 28 AUTO_ENABLE, bit 31 RESET. Values here are raw hardware (die 0 goes through the hv PMGR hook, which masks flag bits: `0x3ff -> 0xff`, L1136-1274).

| off (+0x1c0) | device | first read | decoded |
|---|---|---|---|
| 0x000 | VENC0_SYS | `0xf000300` | off (t0 a0), auto state f, was pwr+clk gated |
| 0x008 / 0x010 / 0x018 / 0x038 / 0x040 / 0x048 | MSR0 / JPG / AVD_SYS / MSR1 / MSR0_ASE_CORE / MSR1_ASE_CORE | `0xf000300` | off |
| 0x020 | PRORES | `0x300` | off, no auto (never touched again) |
| 0x058-0x070, 0x0d8-0x0f0, 0x158-0x170, 0x1d8-0x1f0 | AMCC0-15 | `0xf0003ff` | active (flags set) |
| 0x078, 0x0f8/0x100, 0x178/0x180, 0x1f8/0x200 | FAB_AFR_AMCC_0-7 | `0xf0003ff` / `0xf0002ff` | active |
| 0x0c8, 0x148, 0x1c8, 0x248 | FAB_AFC_AMCC_0-3 | `0xf0000ff` | active, no flags |
| 0x278-0x550 (24 regs) | FAB_AFR_AMCC_8-15, FAB_AFC_AMCC_4-7, B2BD_*, B2BG_* | `0xf000300` / `0xf000200` / `0x300` | off (second die side) |
| 0x7e40, 0x7e48, 0x7e50, 0x7e58, 0x7e60 (= abs 0x8000-0x8020) | VENC0_DMA, VENC0_PIPE4, PIPE5, ME0, ME1 | `0x300` | off |

Sequence [F]:
1. L1143-1221: one ascending read of all 80 registers.
2. L1227-1242: re-read of AMCC0-15 (16 regs, all `0xf0003ff`).
3. L1275-1414: for each of the 28 active AMCC/AFR/AFC devices: R, R, W `(v & ~0x300)` (e.g. `0xf0003ff -> 0xf0000ff`), R, W `|0x10000000` (`0x1f0000ff`) = clear WAS_ flags and enable auto-PM. Same pattern the PMGR hook shows on die 0 (ATC0_COMMON, FAB8_SOC, SIO, UART_P/UART0, ATC0_USB_AON/USB: L1136-1274, "Dangerous write").
4. **Media power cycles** (L2899-L3278). Each: R x3-4 until stable, W `0xf00000f` (target f), poll (`0xf00030f` -> `0xf000b4f` -> `0xf0003ff`), W `0x1f00000f` (auto-enable). Power-down: W `0xf0000ff`, R, W `0xf0003f0` (target 0), R `0xf000100` x2.
   Order: MSR1 up (L2899-2908) -> **VENC0_SYS up (L2909-2920)** -> ave0 programming (2.2) -> VENC0_SYS down (L3178-3186) -> JPG up/down (L3187-3207) -> AVD_SYS up (L3208-3220) -> MSR1_ASE_CORE up (L3221-3229) -> JPG up/down (L3230-3249) -> AVD_SYS down (L3250-3258) -> MSR0 up (L3259-3269) -> MSR0_ASE_CORE up (L3270-3278). MSR0, MSR0_ASE_CORE, MSR1, MSR1_ASE_CORE are still on at the end of the AVE traffic.
   **[I]** the five VENC0 child domains (DMA, PIPE4/5, ME0/1) are only read, never powered; only VENC0_SYS is cycled. It is a generic PMGR/boot power sweep with an AVE probe inside it, not an encoder start.

### 2.2 reg2 and reg0 (the only AVE-owned MMIO)

With only VENC0_SYS on [F]:
- L2921: W ave0.reg2 `+0x118 = 1`.
- L2922-3177, reg0 (`0x2283100000`), 128 read-then-write pairs in `0xdc000-0xdc868` (all reads return 0 except the first few):
  - `0xdc004`: `0x40 -> 0x200`; `0xdc014`: `0 -> 0`.
  - `0xdc400`: `0x2900 -> 0x52900`.
  - `0xdc404..0xdc4a4` (41 words): `0 -> 1` each.
  - `0xdc724..0xdc868` (82 words): written `0` or small values, mostly in identical pairs: `0xdc744=3, 0xdc748=2, 0xdc774/78=3, 0xdc77c/80=1, 0xdc784/88=3, 0xdc78c/90=5, 0xdc7a4/a8=1, 0xdc7ac/b0=3, 0xdc7b4..c0=4, 0xdc7dc..e8=1, 0xdc7ec..f8=2, 0xdc7fc/800=4, 0xdc804..810=3, 0xdc81c..828=7, 0xdc82c=0x1a, 0xdc830=0x19, 0xdc834..840=1, 0xdc844/48=5, 0xdc84c/50=6, 0xdc854/58=1, 0xdc85c/60=0xa, 0xdc864/68=3`.
  - last: `0xdc400: 0x52900 -> 0x52903`; `0xdc000: 0x100 -> 0x101` (bit 0 set).
- **[I]** a driver-side table load (arbiter/QoS or outstanding-request limits: pairs of equal values) followed by an enable bit. The offsets and values are not in any ADT property (searched all nodes for `0xdc004`), so they come from the kext.

No mailbox or coprocessor start [F]: reg1 (8 MiB, the usual ASC/firmware window size), reg4, and everything else in reg0 are never accessed. `pre-loaded = 1` firmware was never started. There are no accesses to `dart-ave0` in this capture (not in the group).

## 3. What to trace next (N1)

Addresses are CPU addresses (trace convention). Each hv trace range costs a trap per access; the hv works at 16 KiB granularity.

**A. ECAM (reg0, `0x1cb0000000`, 0x10000000; bus-range `<0 8>`, so 9 MiB are real).** Root complex does 00:0n.0 at `ECAM + (n << 15)`; endpoints at `ECAM + (bus << 20) + (fn << 12)`.
- Root port 0, 00:00.0: `0x1cb0000000..0x1cb0001000` (one 16 KiB page, `0x1cb0000000..0x1cb0004000`, also holds 00:00.1-3).
- Root port 1, 00:01.0 (SD reader): `0x1cb0008000..0x1cb0009000`.
- Bus 1 (RID `0x100`, SD reader in macOS, N1 in Linux/m1n1): `0x1cb0100000..0x1cb0104000`.
- Bus 2 (RID `0x200`, the N1 in macOS: centauri-control fn0, alpha fn1, beta fn2): `0x1cb0200000..0x1cb0203000`.
- Simplest: trace `0x1cb0000000..0x1cb0300000` (buses 0-2, 3 MiB). Priority: the root-port DBI sequence (`0x70+` PCIe cap, `0x194`, `0x710`, `0x80c`, `0x890`, `0x8a8`, `0x8bc`, `0xb80`, `0xb88`) and the endpoint's first reads (ID `0x1900106b`/`0x1901106b`, BARs, command register).

**B. Things the root-complex side needs and the log cannot show.**
- `gpio0` `0x29c000000` (+0x44000): pad 80 PERST# = `+0x140`, pad 76 CLKREQ# = `+0x130` (m1n1 writes `0x202|1`, mask `0x27f`).
- SMC `/arm-io/smc`: reg0 `0x28c600000` (+0x88000), reg1 `0x28c050000`, reg2 `0x28c810000`; `gP13` and `bpli` are SMC keys (mailbox). Use the existing SMC mailbox decode (`mbox-decode.py --dev smc`) with `HV27_TRACE=smc`.
- PMGR PS regs of the APCIE chain, die 0 block `0x280900000` (ps-group 1): APCIE_GP `0x280900118`, FAB6_SOC `0x280900138`, APCIE_SYS_GP `0x280900148`, APCIE_PHY_SW `0x2809001b0`, APHY_GP_AUS5_A `0x280900258`, APHY_GP_AUS5 `0x280900280` (ADT device table; a virtual no_ps APCIE_PHY_SW also exists at group 0): check the PMGR hook logs, not only masks, these.
- The PHY/tunable windows that were silent here but must be visible once to settle table item 7: install the `n1` group **earlier than the SPTM AMCC trigger**, or add a hook variant keyed on the first IOKit PCIe access. Without that it stays unknown whether macOS applies tunables or iBoot already did.

**C. N1 BAR / firmware-load side.** The N1 lives behind the root port; BARs sit in the 32-bit window `bus 0x80000000 -> CPU 0xb80000000, 1 GiB` ([ADT] `ranges`, type `0x02000000`) or the 64-bit prefetchable one `bus 0xbc0000000 -> CPU 0xbc0000000, 512 MiB` (type `0x43000000`). From the live-macOS scan (`m5scan/redacted/03-wireless-n1.txt`, a boot with a root volume): centauri-control BAR0 `0xb84020000` (+0x10000) and a 32 MiB BAR at `0xb82000000`; alpha `0xb84010000` (+0x10000); beta `0xb84000000` (+0x10000). Addresses are assigned by macOS PCI code, so re-read BAR values from the ECAM trace (A) first, then trace:
- control BAR0 (64 KiB): Linux's use is `+0x8000` stage, `+0x803c`, `+0x8040` image_response, `+0x8044/+0x8048` descriptor DMA address, `+0x804c`, `+0x807c` platform id, `+0x9000` doorbell [REF: centauri_pci.c]. macOS's equivalents are unknown: trace the whole 64 KiB.
- `0xb82000000` (+32 MiB) is the second control BAR; trace only the first 16 KiB-aligned pages unless the first pass shows traffic.
- DART for the N1 DMA (FTAB buffers are DMA-mapped): `dart-apcie0` `0x410000000` (+0x20000) and its second window `0x2803f0000` (+0x4000); `apcie0-piodma` `0x410030000`, `0x410034000`, `0x410038000` (+0x4000 each). Use the `darts` group style (write-only is enough for TTBR/stream enables).
- MSI doorbell `msi-address 0xfffff000` (not MMIO that needs tracing; for decoding MSI vectors only).

**D. Make the console loop observable.** The loop "chip reset / warm reset / PCI configuration" corresponds, on the root-complex side, to the port 0 teardown + re-enable shown here (3 repetitions in this capture). To tie console lines to trace lines, run SYNC mode (`HV27_TRACE_MODE=sync`) and interleave a marker (a guest-visible console line has no timestamp relation in ASYNC mode).

## 4. Limits of this decode

- ASYNC trace, no timestamps: "how long" a poll lasted is given as number of reads only.
- ECAM, gpio0, SMC, DART, PMGR for the APCIE chain, N1 BARs: not traced; ECAM-level success of the link (config reads, BARs, bus numbers) is unknown.
- reg20/reg21 and the `0x2b0`/`0x13c`/`0x88` registers have no known owner in our sources; their roles above are inference from the access pattern.
- The window starts when the hooks went in (L585); the apcie0 traffic starts at L1415, so anything the kernel did earlier is not covered.
