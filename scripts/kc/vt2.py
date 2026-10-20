#!/usr/bin/env python3
"""vt2.py kernelcache kext-substr [targetVA...] : main vtable of the kext (longest run of pointers into any __TEXT_EXEC),
print slot offsets (relative to vtable+0x10) for the given targets, and resolve given slot offsets (0x...) to targets."""
import sys, struct
argv = sys.argv; sys.argv=[argv[0], argv[1]]
exec(open('kcscan.py').read().split('# strings of interest')[0])
BASE = 0xfffffe0007004000; TX = segs['__TEXT_EXEC']
def decode(v): return BASE + (v & 0xffffffff) if v >> 63 else BASE + (v & 0x7ffffffffff)
def is_code(t): return TX[0] <= t < TX[0]+TX[1]
targets = {int(a,16) for a in argv[3:]}
for name in [n for n in kexts if argv[2] in n]:
    for sg, sn, a, s in kexts[name]:
        if sg == '__DATA_CONST' and sn == '__const':
            off = va2off(a); vals = struct.unpack_from(f'<{s//8}Q', d, off)
            runs = []; run = 0
            for i, v in enumerate(vals):
                if v and is_code(decode(v)): run += 1
                else:
                    if run >= 40: runs.append((run, i-run))
                    run = 0
            for n, start in runs:
                print(f"{name}: vtable run {n} entries, vtable+0x10 = {a+8*start:#x}")
                for i in range(n):
                    t = decode(vals[start+i])
                    if t in targets or t+4 in targets or (8*i) in targets: print(f"   slot +{8*i:#x} -> {t:#x} ({kext_of(t)})")
