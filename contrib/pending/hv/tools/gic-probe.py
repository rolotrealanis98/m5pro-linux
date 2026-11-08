# SPDX-License-Identifier: MIT
# Read-only: ID registers and GIC hypervisor-interface presence seen from m1n1 (EL2) on the T6050.
from m1n1.setup import *
def rd(name):  # unused
    try: return u.mrs(name)
    except Exception as e: return f"ERR {e}"
pfr0 = u.mrs(ID_AA64PFR0_EL1); gic = (pfr0 >> 24) & 0xf
print(f"ID_AA64PFR0_EL1 = {pfr0:#018x}  GIC field = {gic} ({'GICv3 system register interface present' if gic else 'no GIC sysreg interface'})  EL2={ (pfr0>>8)&0xf } EL3={ (pfr0>>12)&0xf }")
pfr1 = u.mrs(ID_AA64PFR1_EL1); print(f"ID_AA64PFR1_EL1 = {pfr1:#018x}")
mmfr1 = u.mrs(ID_AA64MMFR1_EL1); print(f"ID_AA64MMFR1_EL1 = {mmfr1:#018x}  VH={ (mmfr1>>8)&0xf } VMIDBits={ mmfr1&0xf } HAFDBS={ (mmfr1>>0)&0xf }")
mmfr0 = u.mrs(ID_AA64MMFR0_EL1); print(f"ID_AA64MMFR0_EL1 = {mmfr0:#018x}  PARange={ mmfr0&0xf }")
print(f"HCR_EL2 = {u.mrs(HCR_EL2):#x}  CurrentEL = {u.mrs(CurrentEL):#x}")
# GIC hypervisor control registers exist only when the GIC field is non-zero; encodings per ARM ARM
regs = {"ICH_VTR_EL2": (3,4,12,11,1), "ICH_HCR_EL2": (3,4,12,11,0), "ICH_VMCR_EL2": (3,4,12,11,7),
        "ICC_SRE_EL2": (3,4,12,9,5), "ICC_SRE_EL1": (3,0,12,12,5), "ICC_CTLR_EL1": (3,0,12,12,4)}
if gic:
    for n, enc in regs.items():
        try: print(f"{n} = {u.mrs(enc):#x}")
        except Exception as e: print(f"{n}: ERR {e}")
else:
    print("skipping ICH_*/ICC_* reads: PFR0.GIC says no system-register GIC interface")
print("ADT /arm-io/aic compatible:", u.adt["/arm-io/aic"].compatible)
for n in ("/arm-io/aic",):
    node = u.adt[n]; print(n, "reg:", [hex(x) for r in node.reg for x in (r.addr, r.size)])
