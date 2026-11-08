# SPDX-License-Identifier: MIT
# Read-only: does the T6050 expose the GICv3 *virtual* CPU interface (ICH_*) although PFR0.GIC == 0, like the M1?
# Every mrs runs under m1n1's exception guard (SKIP): an undefined register raises ProxyError here, m1n1 survives.
from m1n1.setup import *
from m1n1.proxy import ProxyError
regs = {"ICH_VTR_EL2": (3,4,12,11,1), "ICH_HCR_EL2": (3,4,12,11,0), "ICH_VMCR_EL2": (3,4,12,11,7),
        "ICH_MISR_EL2": (3,4,12,11,2), "ICH_EISR_EL2": (3,4,12,11,3), "ICH_ELRSR_EL2": (3,4,12,11,5),
        "ICH_LR0_EL2": (3,4,12,12,0), "ICH_AP0R0_EL2": (3,4,12,8,0), "ICH_AP1R0_EL2": (3,4,12,9,0),
        "ICC_SRE_EL2": (3,4,12,9,5), "ICC_SRE_EL1": (3,0,12,12,5), "ICC_CTLR_EL1": (3,0,12,12,4),
        "ICC_PMR_EL1": (3,0,4,6,0), "ICC_IGRPEN1_EL1": (3,0,12,12,7)}
for n, enc in regs.items():
    try:
        v = u.mrs(enc, silent=True); print(f"{n:16s} = {v:#x}")
    except ProxyError as e:
        print(f"{n:16s} : trap (undefined at EL2)")
try:
    vtr = u.mrs((3,4,12,11,1), silent=True)
    print(f"ICH_VTR_EL2 decode: ListRegs={ (vtr&0x1f)+1 } PREbits={ ((vtr>>26)&7)+1 } PRIbits={ ((vtr>>29)&7)+1 } SEIS={ (vtr>>22)&1 } A3V={ (vtr>>21)&1 } nV4={ (vtr>>20)&1 } TDS={ (vtr>>19)&1 } DVIM={ (vtr>>18)&1 }")
except ProxyError: pass
