#!/usr/bin/env python3
# PTD aperture decode for hv27 traces (offline).  usage: python3 -I ptd-decode.py TRACE.log [MBOX-DECODE-OUTPUT]
# Prints: per-PC/offset table with PTD entry mapping, request-word history, MC sweeps, CLPC ticks, DVFS writes.
# Timestamps: 64-bit "stamp" word of each 16-byte PTD entry = (counter << 10) | flags, counter assumed 24 MHz [I].
import sys, re, collections, bisect, struct
RE = re.compile(r'^\[cpu\d\] \[(0x[0-9a-f]+)\] MMIO: ([RW])\.(\d)(?: \+)? +(0x[0-9a-f]+) \((pmp\.\w+), offset (0x[0-9a-f]+)\) = (0x[0-9a-f]+)')
PTD = [  # (id, idx, count, name) from J716s ADT iop-pmp0-nub ptd-range
 (2,0x1,1,'PMP-STATUS'),(3,0x8,4,'DVFS-STATE'),(4,0xc,4,'PMPTOOL'),(5,0x10,8,'PMS-PMGR-PKT'),(6,0x18,0x20,'PMS-DPE-PKT'),
 (7,0x38,0x48,'PMS-DEVC-PKT'),(8,0x80,0x10,'PMS-PWRS-PKT'),(9,0x90,0x150,'SOC-DEV-PKT'),(10,0x1e0,8,'SOC-DEV-PS-REQ'),
 (11,0x1e8,8,'SOC-DEV-PS-ACK'),(12,0x1f0,0x30,'SOC-DEV-DVFS'),(13,0x220,0x1a,'SOC-DEV-BWR'),(14,0x23a,2,'DVFS-DIE-TO-DIE'),
 (15,0x23c,0xa,'MC-DRV-TO-CTRL'),(16,0x258,2,'FAST-DIE-CE'),(17,0x25a,7,'SMC-TO-PPM'),(18,0x261,9,'MC-CTRL-TO-DRV'),
 (19,0x26a,1,'LTS-VOLT-CAP'),(24,0x270,5,'PPM-TO-SMC'),(25,0x275,5,'CLPC-TO-SMC'),(26,0x27a,0x20,'GFX-TO-SMC'),
 (27,0x29a,9,'FAST-DIE-TO-SMC'),(28,0x2a3,1,'MC-CTRL-TO-SMC'),(29,0x2a4,8,'ANE-TO-SMC'),(32,0x2b4,1,'LTS-TO-GFX'),
 (33,0x2b5,1,'PMP-TO-GFX'),(34,0x2b6,8,'PMU-TO-GFX'),(40,0x320,0x14,'PMS-VIRT-CNTR')]
DEV = "DCS AMCC SOC-NI0 SOC-NI1 SOC-NI2 SOC-NI3 SOC-NI4 SOC-NI5 SOC-NI6 SOC-NI7 SOC-NI8 SOC-NI9 MACC0 MACC1 PACC AGX ANE ISP DISPINT DISPEXT0 DISPEXT1 DISPEXT2 DISPEXT3 AVE0 AVE1 AVD MSR0 MSR1 JPEG SCODEC PRORES ATC0 ATC1 ATC2 ATC3 AUSS ANS".split()
def entry_of(off):
    if off >= 0x10000: idx, kind = (off-0x10000)//8, 'W'
    else: idx, kind = off//16, 'R'
    for _,b,n,name in PTD:
        if b <= idx < b+n: return name, idx-b, idx
    return '?', 0, idx
def bits(v): return ','.join(DEV[i] if i < len(DEV) else f'b{i}' for i in range(64) if v>>i&1)
def main():
    ev = []
    for ln, l in enumerate(open(sys.argv[1], errors='replace'), 1):
        m = RE.match(l)
        if m: ev.append((ln, m[5], int(m[1],16), m[2], int(m[3]), int(m[6],16), int(m[7],16)))
    ptd = [e for e in ev if e[1]=='pmp.ptd']
    print(f'{len(ev)} MMIO lines: {len(ptd)} pmp.ptd, {len(ev)-len(ptd)} pmp.mbox; widths {collections.Counter(e[4] for e in ptd)}')
    print('\n== per PC')
    for pc in sorted(set(e[2] for e in ptd)):
        c = collections.Counter((e[3],e[5]) for e in ptd if e[2]==pc)
        print(hex(pc), sum(c.values()), 'R', sum(v for (r,o),v in c.items() if r=='R'), 'W', sum(v for (r,o),v in c.items() if r=='W'))
    print('\n== per offset: entry mapping, counts, distinct values')
    c = collections.defaultdict(list)
    for e in ptd: c[(e[3],e[5])].append(e[6])
    for (rw,off) in sorted(c, key=lambda k:(k[1],k[0])):
        n,i,idx = entry_of(off); v = c[(rw,off)]
        print(f'{rw} {off:#07x}  {n}[{i}] idx {idx:#x}  x{len(v)}  distinct {len(set(v))}  min {min(v):#x} max {max(v):#x}')
    print('\n== PS-REQ writes (0x10f00)')
    prev = 0
    for e in ptd:
        if e[3]=='W' and e[5]==0x10f00:
            d = e[6]^prev; add=[DEV[b] for b in range(37) if d>>b&1 and e[6]>>b&1]; rem=[DEV[b] for b in range(37) if d>>b&1 and not e[6]>>b&1]
            print(f'line {e[0]} {e[6]:#x} +[{",".join(add)}] -[{",".join(rem)}]'); prev = e[6]
    print('\n== DVFS entry 0 writes (0x10f80)', [(e[0], e[6]&0x1f) for e in ptd if e[5]==0x10f80][:200])
    sw = [e[0] for e in ptd if e[5]==0x2690 and e[3]=='R']
    cl = [e[0] for e in ptd if e[5]==0x113a8]
    print(f'\n== MC-CTRL-TO-DRV spin: {len(sw)} iterations (18 reads each), first line {sw[0]}, last {sw[-1]}')
    print(f'== CLPC-TO-SMC ticks: {len(cl)} (3 writes each), first {cl[0]}, last {cl[-1]}')
    f = lambda v: struct.unpack('<ff', struct.pack('<Q', v))
    print('   float pairs first/last:', [f(e[6]) for e in ptd if e[5]==0x113a8][:2], [f(e[6]) for e in ptd if e[5]==0x113a8][-2:])
if __name__ == '__main__': main()
