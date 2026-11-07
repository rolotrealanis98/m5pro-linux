#!/usr/bin/env python3
"""resolve.py SRC UNRES.json -> prints provider .ko paths (relative to the out dir) for unresolved symbols."""
import sys,json,os,re,subprocess,collections
src=sys.argv[1]; unres=json.load(open(sys.argv[2]))
syms=sorted(unres)
rx=r'EXPORT_SYMBOL(_GPL|_NS|_NS_GPL)?\(\s*('+'|'.join(re.escape(s) for s in syms)+r')\s*[,)]'
r=subprocess.run(['rg','-n','--no-heading','-g','*.c',rx,'drivers','sound','net','fs','crypto','lib','kernel'],cwd=src,capture_output=True,text=True).stdout
prov=collections.defaultdict(set)
for line in r.splitlines():
    f,_,rest=line.split(':',2)
    m=re.search(rx,rest)
    prov[m.group(2)].add(f)
def parse_make(d):
    objs={}   # module name -> set of .o ; plus plain obj-m
    for mk in ('Makefile','Kbuild'):
        p=os.path.join(src,d,mk)
        if not os.path.exists(p): continue
        txt=open(p,errors='replace').read().replace('\\\n',' ')
        for l in txt.splitlines():
            m=re.match(r'\s*([A-Za-z0-9_\-\.\$\(\)]+?)(-y|-objs|-\$\(CONFIG_\w+\))\s*[:+]?=\s*(.*)',l)
            if m and not m.group(1).startswith('obj'):
                objs.setdefault(m.group(1),set()).update(x for x in m.group(3).split() if x.endswith('.o'))
            m=re.match(r'\s*obj-(\$\(CONFIG_\w+\)|m|y)\s*[:+]?=\s*(.*)',l)
            if m:
                for x in m.group(2).split():
                    if x.endswith('.o'): objs.setdefault('__obj__'+x[:-2],set()).add(x)
    return objs
res=collections.defaultdict(set)
for s,files in prov.items():
    for f in files:
        d=os.path.dirname(f); b=os.path.basename(f)[:-2]+'.o'
        objs=parse_make(d); found=None
        for name,os_ in objs.items():
            if not name.startswith('__obj__') and b in os_: found=name
        if not found and ('__obj__'+b[:-2]) in objs: found=b[:-2]
        if not found:
            # obj-m listed module with same name as a composite
            found='?'+b[:-2]
        res[s].add(d+'/'+found+'.ko')
mods=collections.defaultdict(list)
for s,ks in res.items():
    for k in ks: mods[k].append(s)
for k,v in sorted(mods.items()): print(k, len(v), v[0])
miss=[s for s in syms if s not in prov]
print('NOPROVIDER',len(miss),miss[:40],file=sys.stderr)
