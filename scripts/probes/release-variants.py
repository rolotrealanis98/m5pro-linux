#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Try several PMGR release sequences on different T6050 secondaries, each watched by a crumb stub at
the locked RVBAR (m1n1 base) that also arms the watchdog for an 8 s reset: a reset is proof of
execution even if the DRAM crumb were invisible. Stage-1 m1n1 only. Arm the outer watchdog first:
    wdt-arm.py 150 && release-variants.py && wdt-arm.py --off
"""
import sys, time
from m1n1.setup import *
from m1n1.asm import ARMAsm

adt = u.adt
cpus = {c.name: c for c in adt["/cpus"] if c.name.startswith("cpu") and c.name != "cpus"}
base = u.base
for n in ("cpu1","cpu2","cpu3","cpu4","cpu5"):
    assert (p.read64(cpus[n].cpu_impl_reg[0]) & 0xffffffffff000) == base, f"{n}: RVBAR not this image (chainloaded?)"
lwr = u.mrs((3,0,11,0,0)); print(f"window first 32 bytes: {iface.readmem(lwr, 32).hex()}")

buf = u.memalign(0x4000, 0x4000); p.memset32(buf, 0, 0x4000); p.dc_civac(buf, 0x4000)
wdt = adt["/arm-io/wdt"].get_reg(0)[0]
stub = ARMAsm(f"""
    ldr  x0, crumbs
    mrs  x1, mpidr_el1
    ubfx x2, x1, #0, #8
    ubfx x3, x1, #8, #8
    orr  x2, x2, x3, lsl #3
    str  x1, [x0, x2, lsl #3]
    dsb  sy
    ldr  x0, wdt
    ldr  w1, alarm
    str  w1, [x0, #0x14]
    str  wzr, [x0, #0x10]
    mov  w1, #4
    str  w1, [x0, #0x1c]
    dsb  sy
1:  wfe
    b    1b
    .align 3
crumbs: .quad {buf:#x}
wdt:    .quad {wdt:#x}
alarm:  .word {8 * 24_000_000}
""", base)
assert len(stub.data) <= 0x80
def write_slot0(data):
    flags = p.mmu_disable()
    try: iface.writemem(base, data)
    finally: p.mmu_restore(flags)
    p.dc_civac(base, 0x80); p.ic_ivau(base, 0x80)
orig = iface.readmem(base, 0x80); write_slot0(stub.data)
assert iface.readmem(base, len(stub.data)) == stub.data
print(f"RVBAR slot 0 at {base:#x} = crumb+wdt stub; crumbs at {buf:#x}")

pmgr = adt["/arm-io/pmgr"].get_reg(0)[0]; sb = pmgr + 0x88000
def status(c): return p.read64(c.cpu_impl_reg[0] + 0x100)
def ps(c): return p.read32(pmgr + 8 * c.cpu_id)       # MCPU0_0 @ +0, MCPU0_1 @ +8, ...
def crumbs():
    p.dc_ivac(buf, 0x4000); return [(i, v) for i in range(64) if (v := p.read64(buf + 8*i))]
def xnu_release(c):
    p.write32(sb + 4, 1 << c.cpu_id); p.write32(sb + 8 + 4 * c.cluster_id, 1 << c.cluster_core_id)
variants = [
    ("cpu1", "control: XNU sequence (+0x4 die bit, +0x8+4*cl cluster bit)", lambda c: xnu_release(c)),
    ("cpu2", "W1: W1C the +0x0 stop bit first, then XNU sequence", lambda c: (p.write32(sb + 0, 1 << c.cpu_id), xnu_release(c))),
    ("cpu3", "W5: PMGR core ps target=0xf first, wait, then XNU sequence", lambda c: (p.write32(pmgr + 8*c.cpu_id, (ps(c) & ~0xf) | 0xf), time.sleep(0.01), xnu_release(c))),
    ("cpu4", "W2: cluster bit (+0x8+4*cl) before die bit (+0x4)", lambda c: (p.write32(sb + 8 + 4*c.cluster_id, 1 << c.cluster_core_id), p.write32(sb + 4, 1 << c.cpu_id))),
    ("cpu5", "W7: XNU sequence, then also +0x10 and +0x14 = BIT(cpu)", lambda c: (xnu_release(c), p.write32(sb + 0x10, 1 << c.cpu_id), p.write32(sb + 0x14, 1 << c.cpu_id))),
]
for n, desc, fn in variants:
    c = cpus[n]
    print(f"\n{n}: {desc}\n   before: status {status(c):#x} ps {ps(c):#x} CPU_START {' '.join(f'+{o:#x}={p.read32(sb+o):#x}' for o in (0,4,8,0xc,0x10,0x14))}")
    fn(c); time.sleep(0.1)
    print(f"   after:  status {status(c):#x} ps {ps(c):#x} CPU_START {' '.join(f'+{o:#x}={p.read32(sb+o):#x}' for o in (0,4,8,0xc,0x10,0x14))}")
    hits = crumbs()
    print(f"   crumbs: {[(i, hex(v)) for i, v in hits] or 'none'}")
    if hits: print("   >>> EXECUTION at RVBAR; the stub armed an 8 s watchdog reset"); break
write_slot0(orig); print("\nslot 0 restored")
