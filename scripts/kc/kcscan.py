#!/usr/bin/env python3
"""Scan a macOS kernelcache fileset: string xrefs, IMPDEF sysreg use, PMGR CPU_START immediates.
usage: kcscan.py kernelcache.macho [kext-substring ...]"""
import struct, sys, re, bisect
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, CS_MODE_LITTLE_ENDIAN
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG

KC = sys.argv[1]; WANT = sys.argv[2:] or ["AppleARMPlatform","AppleT6050PMGR","AppleT6050","com.apple.kernel"]
d = open(KC,'rb').read()

def lcs(off):
    ncmds = struct.unpack_from('<I', d, off+16)[0]; o = off+32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from('<II', d, o); yield cmd, o, sz; o += sz

segs = {}  # top-level: name -> (vm, size, fileoff)
ents = []
for cmd, o, sz in lcs(0):
    if cmd == 0x19:
        n = d[o+8:o+24].rstrip(b'\0').decode(); vm, vs, fo, fs = struct.unpack_from('<QQQQ', d, o+24); segs[n] = (vm, vs, fo)
    elif cmd == 0x80000035:
        vmaddr, fileoff, eid = struct.unpack_from('<QQI', d, o+8); ents.append((vmaddr, fileoff, d[o+eid:d.index(b'\0', o+eid)].decode()))
def va2off(va):
    for n, (vm, vs, fo) in segs.items():
        if vm <= va < vm+vs: return fo + (va-vm)
    return None
# per-kext sections
kexts = {}
for vmaddr, fileoff, name in ents:
    secs = []
    for cmd, o, sz in lcs(fileoff):
        if cmd == 0x19:
            nsects = struct.unpack_from('<I', d, o+64)[0]; so = o+72
            for _ in range(nsects):
                sn = d[so:so+16].rstrip(b'\0').decode(); sg = d[so+16:so+32].rstrip(b'\0').decode()
                addr, size = struct.unpack_from('<QQ', d, so+32); secs.append((sg, sn, addr, size)); so += 80
    kexts[name] = secs
text_ranges = []  # (start,end,kext)
for name, secs in kexts.items():
    for sg, sn, a, s in secs:
        if sg == '__TEXT_EXEC' and sn == '__text' and s: text_ranges.append((a, a+s, name))
text_ranges.sort(); starts = [r[0] for r in text_ranges]
def kext_of(va):
    i = bisect.bisect_right(starts, va)-1
    return text_ranges[i][2] if i >= 0 and va < text_ranges[i][1] else None

# strings of interest -> VA
PAT = re.compile(rb'configMiscCores|cpu-impl-reg|cpm-impl-reg|startCPU|cpu-uttdbg|cpu_start|cpu-id|reset-handler|AppleARMCPU::|CPU_START|SPTM|sptm_cpu|resume-cpu|cpu_resume|cpu-start')
str_va = {}
for name, secs in kexts.items():
    for sg, sn, a, s in secs:
        if sn in ('__cstring', '__os_log', '__const') and s and sg in ('__TEXT','__TEXT_EXEC'):
            off = va2off(a)
            if off is None: continue
            blob = d[off:off+s]
            for m in PAT.finditer(blob):
                st = blob.rfind(b'\0', 0, m.start())+1; en = blob.find(b'\0', m.end())
                if en - st < 200: str_va[a+st] = (blob[st:en].decode('latin1'), name)
print(f"{len(str_va)} interesting strings")

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM | CS_MODE_LITTLE_ENDIAN); md.detail = True; md.skipdata = True
hits = []
for start, end, name in text_ranges:
    if not any(w in name for w in WANT): continue
    off = va2off(start); code = d[off:off+(end-start)]; print(f"scan {name} {start:#x}-{end:#x} ({end-start:#x})")
    last_pacibsp = start; adrp = {}
    for ins in md.disasm(code, start):
        if ins.mnemonic in ('pacibsp','paciasp'): last_pacibsp = ins.address
        if ins.id == 0: continue
        ops = ins.operands
        if ins.mnemonic == 'adrp':
            adrp[ops[0].reg] = ops[1].imm
        elif ins.mnemonic == 'add' and len(ops) == 3 and ops[2].type == ARM64_OP_IMM and ops[1].type == ARM64_OP_REG and ops[1].reg in adrp:
            tgt = adrp[ops[1].reg] + ops[2].imm
            if tgt in str_va: hits.append(('STR', ins.address, last_pacibsp, name, str_va[tgt][0]))
            if ops[2].shift.value == 12 and ops[2].imm == 0x88: hits.append(('IMM88', ins.address, last_pacibsp, name, ins.op_str))
            adrp[ops[0].reg] = tgt
        elif ins.mnemonic == 'add' and len(ops) == 3 and ops[2].type == ARM64_OP_IMM and ops[2].shift.value == 12 and ops[2].imm == 0x88:
            hits.append(('IMM88', ins.address, last_pacibsp, name, ins.op_str))
        elif ins.mnemonic in ('movz','mov','movk') and ops[-1].type == ARM64_OP_IMM and ops[-1].imm in (0x88000,0x88004,0x88008,0x8800):
            hits.append(('IMM88', ins.address, last_pacibsp, name, ins.op_str))
        elif ins.mnemonic in ('msr','mrs') and re.search(r's3_[0-7]_c15_|s3_[0-7]_c11_', ins.op_str):
            hits.append((ins.mnemonic.upper(), ins.address, last_pacibsp, name, ins.op_str))
        if ins.mnemonic not in ('adrp','add'): 
            if ins.mnemonic in ('ldr','str','ldp','stp','ldrb','strb') and ops[0].type==ARM64_OP_REG and ops[0].reg in adrp and ins.mnemonic.startswith('ld'): adrp.pop(ops[0].reg, None)
import collections
byfn = collections.defaultdict(list)
for h in hits: byfn[(h[3], h[2])].append(h)
for (name, fn), hs in sorted(byfn.items()):
    kinds = collections.Counter(h[0] for h in hs)
    interesting = any(h[0] in ('STR','IMM88') for h in hs)
    if not interesting and len(hs) < 3: continue
    print(f"\n== {name} fn@{fn:#x}  {dict(kinds)}")
    for h in hs[:40]: print(f"   {h[1]:#x} {h[0]:5} {h[4]}")
