#!/usr/bin/env python3
"""funcs.py kernelcache kext-substr 'StringPattern' ... : for each cstring matching a pattern in that kext, find its
adrp+add xref sites, treat each site as inside a cold stub, find branches into that stub from the kext, and print
the enclosing function start of each branch site (manual decoding, no capstone)."""
import sys, struct, re, bisect
argv = sys.argv; sys.argv = [argv[0], argv[1]]
exec(open('kcscan.py').read().split('# strings of interest')[0])
vm,vs,fo = segs['__TEXT_EXEC']; words = struct.unpack_from(f'<{vs//4}I', d, fo)
def W(va): return words[(va-vm)//4]
pats = [re.compile(p.encode()) for p in argv[3:]]
kext = [n for n in kexts if argv[2] in n]
# strings
strs = {}
for n in kext:
    for sg,sn,a,s in kexts[n]:
        if sg=='__TEXT' and sn=='__cstring':
            off = va2off(a); blob = d[off:off+s]
            for p in pats:
                for m in p.finditer(blob):
                    st = blob.rfind(b'\0',0,m.start())+1; en = blob.find(b'\0',m.end()); strs[a+st] = blob[st:en].decode('latin1')
# xref sites in kext text
ranges = [(s,e) for s,e,n in text_ranges if n in kext]
def in_kext(va): return any(s<=va<e for s,e in ranges)
sites = {}
for s,e in ranges:
    adrp = {}
    for va in range(s, e, 4):
        w = W(va)
        if (w & 0x9f000000) == 0x90000000:
            rd=w&31; imm=(((w>>5)&0x7ffff)<<2)|((w>>29)&3)
            if imm & (1<<20): imm -= 1<<21
            adrp[rd] = ((va & ~0xfff)+(imm<<12), va)
        elif (w & 0xff800000) == 0x91000000:
            rn=(w>>5)&31; imm=(w>>10)&0xfff
            if rn in adrp and adrp[rn][1] >= va-16:
                t = adrp[rn][0]+imm
                if t in strs: sites.setdefault(va, strs[t])
def is_fn_start(va):
    w = W(va); return w in (0xd503237f,0xd503233f,0xd50324ff,0xd503245f)  # pacibsp paciasp bti c bti j
def stub_start(va):
    while not is_fn_start(va): va -= 4
    return va
def fn_start(va):  # pacibsp/paciasp only
    while W(va) not in (0xd503237f,0xd503233f): va -= 4
    return va
def branch_target(va):
    w = W(va)
    if (w & 0x7c000000) == 0x14000000:  # b / bl
        imm = w & 0x3ffffff; imm -= (1<<26) if imm & (1<<25) else 0; return va + 4*imm
    if (w & 0xff000010) == 0x54000000 or (w & 0x7e000000) == 0x34000000:  # b.cond / cbz cbnz
        imm = (w>>5)&0x7ffff; imm -= (1<<19) if imm & (1<<18) else 0; return va + 4*imm
    if (w & 0x7e000000) == 0x36000000:  # tbz tbnz
        imm = (w>>5)&0x3fff; imm -= (1<<14) if imm & (1<<13) else 0; return va + 4*imm
    return None
stubs = {}
for va, s in sites.items(): stubs.setdefault(stub_start(va), s)
print(f"{len(strs)} strings, {len(sites)} xref sites, {len(stubs)} stubs")
callers = {}
for s,e in ranges:
    for va in range(s, e, 4):
        t = branch_target(va)
        if t is None: continue
        st = max((x for x in stubs if x <= t), default=None)
        if st is not None and t - st < 0x200 and t in range(st, st+0x200):
            f = fn_start(va)
            if f not in stubs: callers.setdefault(f, set()).add(stubs[st])
for f, names in sorted(callers.items()):
    print(f"fn@{f:#x}  " + " | ".join(sorted(n[:80] for n in names)))
