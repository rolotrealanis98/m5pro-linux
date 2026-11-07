#!/usr/bin/env python3
"""closure.py OUT TARGETS: list symbols the built .ko files need that neither vmlinux nor another listed .ko exports."""
import subprocess,os,sys,json
out,tf=sys.argv[1],sys.argv[2]
os.environ['PATH']='/opt/homebrew/opt/llvm/bin:'+os.environ['PATH']
tf=[l.strip() for l in open(tf) if l.strip()]
vm={l.split('\t')[1] for l in open(out+'/vmlinux.symvers') if '\t' in l}
defined={}; undef={}
for k in tf:
    p=os.path.join(out,k)
    if not os.path.exists(p): print('nofile',k,file=sys.stderr); continue
    for line in subprocess.run(['llvm-nm',p],capture_output=True,text=True).stdout.splitlines():
        parts=line.split()
        if len(parts)>=2 and parts[-2]=='U': undef.setdefault(parts[-1],set()).add(k)
        elif parts and parts[-1].startswith('__ksymtab_'): defined[parts[-1][10:]]=k
unres={s:sorted(m) for s,m in undef.items() if s not in vm and s not in defined and not s.startswith(('__ksymtab','_GLOBAL','__this_module'))}
json.dump(unres,open(out.rstrip('/')+'.unres.json' if False else '/dev/stdout','w'),indent=0)
