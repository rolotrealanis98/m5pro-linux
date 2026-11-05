import sys, os, re, struct
from m1n1.adt import load_adt
adt=load_adt(open(os.path.expanduser('~/Work/studio-artifacts/adt-runtime-j716s.bin'),'rb').read())
pm=adt['/arm-io/pmgr']
byid={adt.pmgr_dev_get_id(d):d.name for d in pm.devices}
# phandle map
ph={}
def walk(n,p):
    for c in n:
        q=p+'/'+c.name
        try: ph[c.AAPL_phandle if hasattr(c,'AAPL_phandle') else c._properties['AAPL,phandle']]=q
        except Exception: pass
        walk(c,q)
walk(adt,'')
def phv(n,k):
    try: return n._properties[k] if not hasattr(n,k) else getattr(n,k)
    except Exception: return None
EXTRA=sys.argv[1].split(',') if sys.argv[1] else []
for p in sys.argv[2:]:
    try:
        n=adt
        for part in p.strip('/').split('/'): n=n[part]
    except Exception as e:
        print('ERR',p); continue
    P=n._properties
    out=[p]
    if 'compatible' in P: out.append('compat='+','.join(n.compatible))
    if 'reg' in P:
        try: out.append('reg='+' '.join(f'{r.addr:#x}+{r.size:#x}' for r in n.reg))
        except Exception: out.append(f'reg={n.reg!r}')
    if 'interrupts' in P: out.append('irq='+','.join(str(i) for i in n.interrupts))
    for k in ('power-gates','clock-gates'):
        if k in P:
            v=getattr(n,k.replace('-','_')) if hasattr(n,k.replace('-','_')) else None
            try: out.append(k+'='+','.join(byid.get(i,str(i)) for i in n._properties[k] and getattr(n, k)))
            except Exception:
                raw=P[k]; ids=struct.unpack(f'<{len(raw)//4}I',raw) if isinstance(raw,(bytes,bytearray)) else raw
                out.append(k+'='+','.join(byid.get(i,str(i)) for i in ids))
    if 'iommu-parent' in P:
        raw=P['iommu-parent']; ids=struct.unpack(f'<{len(raw)//4}I',raw) if isinstance(raw,(bytes,bytearray)) else [raw]
        out.append('iommu='+','.join(ph.get(i,str(i)).split('/')[-1] for i in ids[:6])+('...' if len(ids)>6 else ''))
    for k in EXTRA:
        if k in P:
            try: v=getattr(n,k.replace('-','_'))
            except Exception: v=P[k]
            s=repr(v); out.append(f'{k}={s[:160]}')
    flags=[k for k in P if 'exclave' in k or k in ('pre-loaded','running','dont-power-on')]
    if flags: out.append('flags='+','.join(flags))
    print('  '.join(out))
