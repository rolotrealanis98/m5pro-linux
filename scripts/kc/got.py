#!/usr/bin/env python3
"""got.py kernelcache target-VA... : find __auth_got/__got slots (any kext) whose chained-fixup target is one of the VAs,
then the __auth_stubs stub that loads that slot, then bl sites to that stub and their enclosing function."""
import sys, struct
argv = sys.argv; sys.argv=[argv[0], argv[1]]
exec(open('kcscan.py').read().split('# strings of interest')[0])
BASE = 0xfffffe0007004000
targets = {int(a,16) for a in argv[2:]}
vm,vs,fo = segs['__TEXT_EXEC']; words = struct.unpack_from(f'<{vs//4}I', d, fo)
def W(va): return words[(va-vm)//4]
def decode(v):
    if v >> 63: return BASE + (v & 0xffffffff)          # auth rebase
    return BASE + (v & 0x7ffffffffff)                   # plain rebase (kernel format)
slots = {}
for n, secs in kexts.items():
    for sg, sn, a, s in secs:
        if sn in ('__auth_got', '__got'):
            off = va2off(a)
            for i in range(s//8):
                v = struct.unpack_from('<Q', d, off+8*i)[0]
                t = decode(v)
                if t in targets: slots[a+8*i] = (t, n)
print(f"{len(slots)} GOT slots")
# stubs: adrp xN,page; ldr x16,[xN,#off]; braa/br x16
def fn_start(va):
    while W(va) not in (0xd503237f,0xd503233f): va -= 4
    return va
for sva, (t, n) in slots.items():
    secs = kexts[n]; stub_va = None
    for sg, sn, a, s in secs:
        if sn == '__auth_stubs' or sn == '__stubs':
            for va in range(a, a+s, 4):
                w = W(va)
                if (w & 0x9f000000) == 0x90000000:
                    imm=(((w>>5)&0x7ffff)<<2)|((w>>29)&3); imm -= (1<<21) if imm&(1<<20) else 0
                    page = (va & ~0xfff) + (imm<<12); w2 = W(va+4)
                    if (w2 & 0xffc00000) == 0xf9400000 and page + ((w2>>10)&0xfff)*8 == sva: stub_va = va
    print(f"slot {sva:#x} -> {t:#x} in {n}: stub {stub_va:#x}" if stub_va else f"slot {sva:#x} -> {t:#x} in {n}: no stub")
    if not stub_va: continue
    for s_, e_, kn in text_ranges:
        if kn != n: continue
        for va in range(s_, e_, 4):
            w = W(va)
            if (w & 0xfc000000) == 0x94000000:
                imm = w & 0x3ffffff; imm -= (1<<26) if imm&(1<<25) else 0
                if va + 4*imm == stub_va: print(f"   bl @ {va:#x}  fn@{fn_start(va):#x}")
