#!/usr/bin/env python3
"""fn.py kernelcache VA [VA...] : print the function enclosing each VA, annotated (string refs, bl targets, genter/hvc)."""
import sys, struct, re
sys.argv_saved = sys.argv; sys.argv = [sys.argv[0], sys.argv[1]]
exec(open('kcscan.py').read().split('md = Cs')[0])
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.skipdata = True
vm,vs,fo = segs['__TEXT_EXEC']
def word(va): return struct.unpack_from('<I', d, fo + (va-vm))[0]
def is_prologue(va):
    w = word(va); return w in (0xd503237f, 0xd503233f) or (w & 0xffc003e0) == 0xa98003e0 and ((w>>10)&0x7f)  # pacibsp/paciasp or stp x29,x30,[sp,#-N]!
def func_bounds(va):
    s = va
    if word(va) in (0xd503245f, 0xd503249f, 0xd50324df): s = va + 4   # vtable target = bti c landing pad
    while s > vm and not is_prologue(s): s -= 4
    e = s + 4
    while e < vm+vs and e - s < 0x4000:
        if word(e) in (0xd503237f, 0xd503233f): break   # next function prologue
        e += 4
    return s, e
def cstr(va):
    off = va2off(va)
    if off is None: return None
    en = d.find(b'\0', off, off+120)
    s = d[off:en]
    return s.decode('latin1') if s and all(32 <= c < 127 or c in (9,10) for c in s) else None
for a in sys.argv_saved[2:]:
    va = int(a, 16); s, e = func_bounds(va)
    print(f"\n==== {kext_of(va)} fn {s:#x}..{e:#x} (contains {va:#x})")
    code = d[fo+(s-vm):fo+(e-vm)]; adrp = {}
    for ins in md.disasm(code, s):
        w = word(ins.address); note = ''
        if w == 0x00201420: note = '  ; GENTER (SPTM call)'
        elif w == 0x00201400: note = '  ; GEXIT'
        elif (w & 0xffe0001f) == 0xd4000002: note = '  ; HVC'
        if ins.id and ins.mnemonic == 'adrp':
            rd = ins.op_str.split(',')[0]; adrp[rd] = int(ins.op_str.split('#')[1], 16)
        elif ins.id and ins.mnemonic == 'add' and ins.op_str.count(',') == 2 and '#' in ins.op_str:
            rd, rn, imm = [x.strip() for x in ins.op_str.split(',')]
            if rn in adrp and 'lsl' not in imm:
                t = adrp[rn] + int(imm[1:], 16); cs_ = cstr(t)
                note = f'  ; -> {t:#x}' + (f' "{cs_[:70]}"' if cs_ else f' ({kext_of(t) or "data"})'); adrp[rd] = t
        elif ins.id and ins.mnemonic in ('ldr','ldrsw') and '#' in ins.op_str:
            m = re.match(r'(\w+), \[(\w+), #(0x[0-9a-f]+)\]', ins.op_str)
            if m and m.group(2) in adrp: note = f'  ; [{adrp[m.group(2)]+int(m.group(3),16):#x}]'
        elif ins.id and ins.mnemonic == 'bl':
            t = int(ins.op_str[1:], 16); note = f'  ; {kext_of(t)}'
        print(f"{ins.address:#x}  {ins.mnemonic:8} {ins.op_str}{note}")
