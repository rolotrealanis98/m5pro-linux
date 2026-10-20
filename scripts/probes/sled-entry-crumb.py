#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Does a released T6050 secondary start executing INSIDE a CTXR slice of iBoot's WFI sled?
Unlike omarchy-m5's smp-sled-crumb.py (one stub at the end, reached by `bl` hops that may cross
CTXR slices), this plants a self-contained crumb stub at the START of every CTXR slice and fills
the rest of each slice with `bl <slice start>` (intra-slice only). Run on the installed stage-1
m1n1, watchdog armed:
    wdt-arm.py 120 && sled-entry-crumb.py [cpu1 cpu6 cpu12] && wdt-arm.py --off
"""
import sys, time
from m1n1.setup import *
from m1n1.asm import ARMAsm

names = sys.argv[1:] or ["cpu1", "cpu6", "cpu12"]
adt = u.adt
cpus = {c.name: c for c in adt["/cpus"] if c.name.startswith("cpu") and c.name != "cpus"}
rd = lambda op: u.mrs((3, 0, 11, op[0], op[1]))
lwr, upr = rd((0, 0)), rd((0, 1)); size = upr + 0x1000 - lwr
print(f"SMP-RO window [{lwr:#x}, {lwr+size:#x}) size {size:#x}; top_of_kernel_data {u.ba.top_of_kernel_data:#x}")
assert 0 < size <= 0x10000 and lwr % 0x1000 == 0
slices = {"A": (rd((2, 2)), rd((2, 3))), "B": (rd((2, 4)), rd((2, 5))), "C": (rd((2, 6)), rd((2, 7))), "D": (rd((3, 0)), rd((3, 1)))}
for k, (lo, hi) in slices.items(): print(f"CTXR_{k} = [{lo:#x}, {hi+0x1000:#x})  CTL={u.mrs((3,0,11,5,2+'ABCD'.index(k))):#x}")

orig = iface.readmem(lwr, size)
print(f"window holds {sum(1 for i in range(0,size,4) if orig[i:i+4]==b'\\x7f\\x20\\x03\\xd5')} wfi of {size//4} words")
buf = u.memalign(0x4000, 0x4000); p.memset32(buf, 0, 0x4000); p.dc_civac(buf, 0x4000)

img = bytearray(orig)
for k, (lo, hi) in slices.items():
    end = hi + 0x1000
    if lo < lwr or end > lwr + size: print(f"slice {k} outside the window, skipped"); continue
    stub = ARMAsm(f"""
        mov  x9, x30
        ldr  x0, crumbs
        mrs  x1, mpidr_el1
        ubfx x2, x1, #0, #8
        ubfx x3, x1, #8, #8
        ubfx x4, x1, #16, #1
        orr  x2, x2, x3, lsl #3
        orr  x2, x2, x4, lsl #5
        add  x0, x0, x2, lsl #5
        str  x1, [x0]
        str  x9, [x0, #8]
        mrs  x5, CurrentEL
        str  x5, [x0, #16]
        mov  x6, #{ord(k)}
        str  x6, [x0, #24]
        dsb  sy
    1:  wfe
        b    1b
        .align 3
    crumbs: .quad {buf:#x}
    """, lo)
    assert len(stub.data) <= 0x100
    img[lo-lwr:lo-lwr+len(stub.data)] = stub.data
    for a in range(lo + 0x100, end, 4):
        img[a-lwr:a-lwr+4] = (0x94000000 | (((lo - a) >> 2) & 0x3ffffff)).to_bytes(4, "little")  # bl slice start
    print(f"slice {k}: stub at {lo:#x}, {(end-lo-0x100)//4} x `bl {lo:#x}`")
iface.writemem(lwr, bytes(img)); p.dc_civac(lwr, size); p.ic_ivau(lwr, size)
assert iface.readmem(lwr, 16) == bytes(img[:16]), "window write did not stick"

sb = adt["/arm-io/pmgr"].get_reg(0)[0] + 0x88000
for n in names:
    c = cpus[n]; im = c.cpu_impl_reg[0]
    before = p.read64(im + 0x100)
    p.write32(sb + 4, 1 << c.cpu_id)
    p.write32(sb + 8 + 4 * c.cluster_id, 1 << c.cluster_core_id)
    time.sleep(0.05)
    print(f"released {n:<6} (type {c.cluster_type}, cluster {c.cluster_id} core {c.cluster_core_id}): status {before:#x} -> {p.read64(im+0x100):#x}")
time.sleep(0.5)
p.dc_ivac(buf, 0x4000)
hits = 0
for i in range(64):
    mp = p.read64(buf + 32*i)
    if mp:
        hits += 1; ret, el, sl = p.read64(buf+32*i+8), p.read64(buf+32*i+16), p.read64(buf+32*i+24)
        print(f"  CRUMB {i:2d}: MPIDR {mp:#x} slice {chr(sl)} entered via x30={ret:#x} CurrentEL {el>>2&3}")
if not hits: print("  no crumbs: no released core executed the start of any CTXR slice")
iface.writemem(lwr, orig); p.dc_civac(lwr, size); p.ic_ivau(lwr, size); print("window restored")
