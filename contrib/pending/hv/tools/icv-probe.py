# SPDX-License-Identifier: MIT
# Read-only except ICH_HCR_EL2.En, which is set for the test and cleared again.
# Question: with the virtual interface enabled, do ICC_*_EL1 accesses from EL1 reach the ICV_* registers?
from m1n1.setup import *
from m1n1.proxy import ProxyError
ICH_HCR = (3,4,12,11,0); ICH_VMCR = (3,4,12,11,7); ICH_LR0 = (3,4,12,12,0)
print("modes:", list(u.exec_modes.keys()))
print(f"ICH_HCR_EL2 before = {u.mrs(ICH_HCR):#x}")
def el1_mrs(enc, label):
    try:
        v = u.mrs(enc, silent=True, call="el1"); print(f"  EL1 mrs {label:16s} = {v:#x}")
    except ProxyError: print(f"  EL1 mrs {label:16s} : trapped/undefined")
print("-- virtual interface disabled (En=0):")
el1_mrs((3,0,12,12,4), "ICC_CTLR_EL1"); el1_mrs((3,0,12,12,5), "ICC_SRE_EL1")
u.msr(ICH_HCR, 1)
print(f"-- virtual interface enabled: ICH_HCR_EL2 = {u.mrs(ICH_HCR):#x}")
for enc, l in (((3,0,12,12,4), "ICC_CTLR_EL1"), ((3,0,12,12,5), "ICC_SRE_EL1"), ((3,0,4,6,0), "ICC_PMR_EL1"),
               ((3,0,12,12,7), "ICC_IGRPEN1_EL1"), ((3,0,12,12,0), "ICC_IAR1_EL1"), ((3,0,12,12,3), "ICC_BPR1_EL1"),
               ((3,0,12,11,3), "ICC_RPR_EL1"), ((3,0,12,8,0), "ICC_IAR0_EL1")):
    el1_mrs(enc, l)
# The ack test below wedged the proxy on 2026-11-08: with group 1 enabled and LR0 pending the virtual IRQ is
# taken at EL1 inside the proxy's EL1 call, where m1n1 has no IRQ handler (that is the virtual interface working).
# Run it only inside a real guest with vectors, or set ICV_ACK_TEST=1 knowingly (power-hold is the way back).
import os
if os.environ.get("ICV_ACK_TEST") == "1":
  # a pending virtual interrupt via LR0  : state=pending(1<<62), group1 (1<<60), prio 0xa0, intid 40 (SPI); then ack from EL1
  u.msr(ICH_LR0, (1 << 62) | (1 << 60) | (0xa0 << 48) | 40)
  print(f"  LR0 = {u.mrs(ICH_LR0):#x}  ELRSR = {u.mrs((3,4,12,11,5)):#x}")
  try:
      pmr = u.mrs((3,0,4,6,0), silent=True, call="el1"); print(f"  EL1 ICC_PMR_EL1 = {pmr:#x}")
      u.msr((3,0,4,6,0), 0xff, silent=True, call="el1"); u.msr((3,0,12,12,7), 1, silent=True, call="el1")
      iar = u.mrs((3,0,12,12,0), silent=True, call="el1"); print(f"  EL1 ICC_IAR1_EL1 (expect 40 or 1023) = {iar:#x}")
      print(f"  LR0 after ack = {u.mrs(ICH_LR0):#x} (state bits 63:62: 2 = active)")
      if iar == 40: u.msr((3,0,12,12,1), 40, silent=True, call="el1"); print(f"  LR0 after EOI = {u.mrs(ICH_LR0):#x}")
  except ProxyError: print("  EL1 ack sequence trapped")
u.msr(ICH_LR0, 0); u.msr(ICH_HCR, 0)
print(f"restored: ICH_HCR_EL2 = {u.mrs(ICH_HCR):#x}  LR0 = {u.mrs(ICH_LR0):#x}")
