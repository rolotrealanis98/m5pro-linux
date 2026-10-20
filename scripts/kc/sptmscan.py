import sys, struct, re
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d = open(sys.argv[1],'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]; o = 32; segs=[]
for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, o)
    if cmd == 0x19:
        n = d[o+8:o+24].rstrip(b'\0').decode(); vm, vs, fo, fs = struct.unpack_from('<QQQQ', d, o+24); segs.append((n,vm,vs,fo,fs))
    elif cmd == 5: # LC_UNIXTHREAD
        pc = struct.unpack_from('<Q', d, o+16+32*8)[0]; print(f"entry pc {pc:#x}")
    o += sz
for s in segs: print(f"SEG {s[0]:14} vm={s[1]:#x} size={s[2]:#x} fileoff={s[3]:#x}")
def cstr(va):
    for n,vm,vs,fo,fs in segs:
        if vm<=va<vm+vs:
            off=fo+(va-vm); en=d.find(b'\0',off,off+200); s=d[off:en]
            return s.decode('latin1') if s and all(32<=c<127 or c in(9,10) for c in s) else None
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.skipdata=True
for n,vm,vs,fo,fs in segs:
    if 'EXEC' not in n: continue
    code = d[fo:fo+fs]; adrp={}; last=vm; genter=0
    for ins in md.disasm(code, vm):
        w = struct.unpack_from('<I', d, fo+(ins.address-vm))[0]
        if w in (0xd503237f,0xd503233f): last = ins.address
        if w == 0x00201420: genter += 1
        if not ins.id: continue
        if ins.mnemonic=='adrp': adrp[ins.op_str.split(',')[0]] = int(ins.op_str.split('#')[1],16)
        elif ins.mnemonic=='add' and ins.op_str.count(',')==2 and 'lsl #12' in ins.op_str and '#0x88' in ins.op_str:
            print(f"{ins.address:#x} fn@{last:#x} {ins.mnemonic} {ins.op_str}   <-- 0x88000 offset")
        elif ins.mnemonic in ('mov','movz','movk') and re.search(r'#0x8800[0-9a-f]?$', ins.op_str):
            print(f"{ins.address:#x} fn@{last:#x} {ins.mnemonic} {ins.op_str}")
        elif ins.mnemonic=='add' and ins.op_str.count(',')==2 and '#' in ins.op_str and 'lsl' not in ins.op_str:
            rd,rn,imm=[x.strip() for x in ins.op_str.split(',')]
            if rn in adrp:
                t=adrp[rn]+int(imm[1:],16); s=cstr(t)
                if s and re.search(r'cpu|CPU|core|resume|wake|reset|RVBAR|rvbar|impl', s): print(f"{ins.address:#x} fn@{last:#x} str \"{s[:100]}\"")
    print(f"{n}: {genter} GENTER words")
