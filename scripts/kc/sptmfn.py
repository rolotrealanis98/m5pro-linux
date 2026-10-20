#!/usr/bin/env python3
"""sptmfn.py sptm.macho VA [VA..] [--n=N]: disassemble N instructions (default 160) from each VA, annotating strings and sysregs."""
import sys, struct, re
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d = open(sys.argv[1],'rb').read(); n = 160
vas = []
for a in sys.argv[2:]:
    if a.startswith('--n='): n = int(a[4:])
    else: vas.append(int(a,16))
ncmds = struct.unpack_from('<I', d, 16)[0]; o = 32; segs=[]
for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, o)
    if cmd == 0x19:
        nm = d[o+8:o+24].rstrip(b'\0').decode(); vm, vs, fo, fs = struct.unpack_from('<QQQQ', d, o+24); segs.append((nm,vm,vs,fo,fs))
    o += sz
def off(va):
    for nm,vm,vs,fo,fs in segs:
        if vm<=va<vm+vs: return fo+(va-vm)
def cstr(va):
    o_=off(va)
    if o_ is None: return None
    en=d.find(b'\0',o_,o_+160); s=d[o_:en]
    return s.decode('latin1') if s and all(32<=c<127 or c in(9,10) for c in s) else None
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.skipdata=True
for va in vas:
    print(f"\n==== sptm fn {va:#x}")
    code = d[off(va):off(va)+4*n]; adrp={}
    for ins in md.disasm(code, va):
        note=''
        w = struct.unpack_from('<I', d, off(ins.address))[0]
        if w == 0x00201420: note='  ; GENTER'
        elif w == 0x00201400: note='  ; GEXIT'
        if ins.id and ins.mnemonic=='adrp': adrp[ins.op_str.split(',')[0]] = int(ins.op_str.split('#')[1],16)
        elif ins.id and ins.mnemonic=='add' and ins.op_str.count(',')==2 and '#' in ins.op_str and 'lsl' not in ins.op_str:
            rd,rn,imm=[x.strip() for x in ins.op_str.split(',')]
            if rn in adrp:
                t=adrp[rn]+int(imm[1:],16); s=cstr(t); note=f'  ; -> {t:#x}'+(f' "{s[:80]}"' if s else ''); adrp[rd]=t
        elif ins.id and ins.mnemonic in ('ldr','ldrsw','str') and '#' in ins.op_str:
            m=re.match(r'(\w+), \[(\w+), #(0x[0-9a-f]+)\]', ins.op_str)
            if m and m.group(2) in adrp: note=f'  ; [{adrp[m.group(2)]+int(m.group(3),16):#x}]'
        print(f"{ins.address:#x}  {ins.mnemonic:8} {ins.op_str}{note}")
