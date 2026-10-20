#!/usr/bin/env python3
"""xref.py kernelcache kext-substring VA [VA..]: list branch/bl sites in that kext targeting each VA, with enclosing function start."""
import sys, struct
argv = sys.argv; sys.argv = [argv[0], argv[1]]
exec(open('kcscan.py').read().split('md = Cs')[0])
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.skipdata = True
vm,vs,fo = segs['__TEXT_EXEC']
targets = {int(a,16) for a in argv[3:]}
for s,e,n in text_ranges:
    if argv[2] not in n: continue
    code = d[fo+(s-vm):fo+(e-vm)]; last = s
    for ins in md.disasm(code, s):
        if not ins.id: continue
        w = struct.unpack_from('<I', d, fo+(ins.address-vm))[0]
        if w in (0xd503237f, 0xd503233f): last = ins.address
        if ins.mnemonic.startswith(('b', 'cb', 'tb')) and '#0x' in ins.op_str:
            t = int(ins.op_str.split('#')[-1], 16)
            if t in targets: print(f"{ins.address:#x} fn@{last:#x} {ins.mnemonic} {ins.op_str}  -> {t:#x}")
