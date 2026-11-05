import sys
from m1n1.adt import load_adt
adt = load_adt(open(sys.argv[1],'rb').read())
pm = adt['/arm-io/pmgr']
byid = {adt.pmgr_dev_get_id(d): d for d in pm.devices}
def name(i):
    d = byid.get(i); return d.name if d else f'?{i}'
for a in sys.argv[2:]:
    i=int(a); d=byid.get(i)
    if not d: print(i,'unknown'); continue
    par=[name(p) for p in adt.pmgr_dev_get_parents(d) if p]
    try: blk=adt.pmgr_dev_get_block(d); off=adt.pmgr_dev_get_offset(d)
    except Exception as e: blk=off=None
    f=d.flags
    print(f'{i:4d} {d.name:22s} parents={par} block={hex(blk[0]) if blk else None} off={hex(off) if off is not None else None} no_ps={f.no_ps} critical={f.critical} on={f.on}')
