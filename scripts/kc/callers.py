#!/usr/bin/env python3
"""callers.py kernelcache slotoff... : all kexts: blraa/braa sites whose preceding 12 instructions load one of the slot
offsets (mov x17,#off / add x16,x16,#off / movk), with enclosing function start."""
import sys, struct
argv = sys.argv; sys.argv=[argv[0], argv[1]]
exec(open('kcscan.py').read().split('# strings of interest')[0])
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.skipdata=True
vm,vs,fo = segs['__TEXT_EXEC']
slots = {int(a,16) for a in argv[2:]}
for s,e,name in text_ranges:
    code = d[fo+(s-vm):fo+(e-vm)]; last = s; recent = []
    for ins in md.disasm(code, s):
        w = struct.unpack_from('<I', d, fo+(ins.address-vm))[0]
        if w in (0xd503237f, 0xd503233f): last = ins.address
        if not ins.id: continue
        recent.append(ins); recent = recent[-12:]
        if ins.mnemonic in ('blraa','braa','blr','br'):
            for r in recent[:-1]:
                if r.mnemonic in ('mov','add','movz') and '#' in r.op_str:
                    try: imm = int(r.op_str.split('#')[-1].split(',')[0], 16)
                    except ValueError: continue
                    if imm in slots: print(f"{ins.address:#x} fn@{last:#x} {name} slot +{imm:#x}"); break
