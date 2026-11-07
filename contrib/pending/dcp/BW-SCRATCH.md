# J716s internal DCP `apple,bw-scratch` = PMC window + 0x20000

Static result, 2026-11-07, from the macOS 27.0 (26A428), 27.2 (26B123) and 27.3 beta kernelcaches (all three
agree). Not yet confirmed on hardware: stage C is its first test.

DT (mk-fixed9.py `BW_SCRATCH_OFFSET = 0x20000`, internal `dcp@48ae00000`):

    apple,bw-scratch = <&pmc_metadata 0 5 0x20000>;   /* fixed8/daily: <0x12 0x00 0x05 0x20000> */

`pmc_metadata` is the existing `pmc-metadata@286700000` node (reg 0x286700000+0x114000, the window the ADT also
lists as disp0/dispext0 reg[4]); cell 0 = its reg[0], cell 1 = 5 = the number of `disp-N` regs, cell 2 = offset.
The D003 reply then carries 0x286720000.

How macOS computes it (D003 `rt_bandwidth_setup_ap`):

1. AppleMobileDispT605X-DCP `IOMFB::UPPipeAP_H17GSCD::rt_bandwidth_setup_ap` looks up the provider's platform
   function `function-bw_req_interrupt0`, calls it with (0, 0, &md) and replies `{ md->getPhysicalAddress(), 0 }`.
   One function serves internal and external pipes.
2. ADT: `/arm-io/disp0 function-bw_req_interrupt0 = <pmgr 'BIRQ' 0x96>`; `dispext0` has 0x36.
3. ApplePMGR's `BIRQ` function (PMC mode) -> `_getBWRReqMemoryPMC(irq)` -> `ApplePMC::getBWRMemory(irq)`: finds
   the 24-byte `/arm-io/pmgr bwr-agent` entry whose u32 at +4 equals irq and takes its byte at +2 (DISP_INT 0,
   DISP_EXT0 3), then the SoC PMC's virtual: T6050 = `0x20000 + (index << 14)`.
4. Base: register group 0x22 (PMC DVFM) = logical region 0x81 + 0x700000; AppleT6050PMGR maps region 0x81 to
   `/arm-io/pmgr reg[8]` (0x86000000, +0x200000000 through arm-io ranges) -> 0x286700000.
   Result `withPhysicalAddress(0x286700000 + 0x20000 + 0x4000 * index, 8)`.

Cross-checks: DISP_EXT0 (index 3) gives 0x2c000, the value Aurora's t6050-dieX.dtsi dcpext0 uses; Aurora's T604x
internal DCP also sits at its PMC window + 0x20000. No Aurora T6050 board describes the internal DCP yet.
