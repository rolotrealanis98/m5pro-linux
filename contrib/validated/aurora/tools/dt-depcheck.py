#!/usr/bin/env python3
# dt-depcheck.py DTS KERNEL_TREE: offline check of a decompiled device tree against a kernel tree.
# Lists enabled Apple nodes whose compatible matches no driver source, and enabled nodes whose
# reset/phy/power-domain/iommu/mailbox/gpio provider is disabled or driverless. Run before any boot.
import re, subprocess, sys
dts=open(sys.argv[1]).read(); tree=sys.argv[2]
src=subprocess.run(["grep","-rhoE",'"apple,[a-z0-9\\-]+"',f"{tree}/drivers",f"{tree}/sound"],capture_output=True,text=True).stdout
known=set(x.strip('"') for x in src.split())
nodes={}; stack=[]
for line in dts.splitlines():
    m=re.match(r"\s*([\w@,\-\.]+) \{", line)
    if m:
        stack.append(m.group(1)); nodes["/".join(stack)]={"compat":[],"status":"okay","phandle":None,"refs":{}}; continue
    if re.match(r"\s*\};", line):
        if stack: stack.pop()
        continue
    n=nodes.get("/".join(stack))
    if n is None: continue
    c=re.search(r'compatible = (.*);', line)
    if c: n["compat"]=re.findall(r'"([^"]+)"', c.group(1))
    st=re.search(r'status = "(\w+)"', line)
    if st: n["status"]=st.group(1)
    ph=re.search(r'phandle = <(0x[0-9a-f]+)>', line)
    if ph: n["phandle"]=int(ph.group(1),16)
    for prop in ("resets","phys","power-domains","iommus","mboxes","apple,sart","interrupt-parent"):
        r=re.search(r'\b'+re.escape(prop)+r' = <([^>]+)>', line)
        if r: n["refs"][prop]=[int(x,16) for x in r.group(1).split() if x.startswith("0x")]
    g=re.search(r'([\w,\-]+-gpios) = <([^>]+)>', line)
    if g: n["refs"][g.group(1)]=[int(g.group(2).split()[0],16)]
byph={n["phandle"]:p for p,n in nodes.items() if n["phandle"] is not None}
def enabled(p):
    parts=p.split("/"); return all(nodes.get("/".join(parts[:i+1]),{"status":"okay"})["status"]!="disabled" for i in range(len(parts)))
def matched(n): return (not n["compat"]) or any(c in known for c in n["compat"])
bad=0
print("== enabled Apple nodes with no matching driver ==")
for p,n in nodes.items():
    if n["compat"] and any(c.startswith("apple,") for c in n["compat"]) and enabled(p) and not matched(n):
        print("  ", p.split("/")[-1], n["compat"]); bad+=1
print("== enabled nodes whose provider is disabled or driverless ==")
for p,n in nodes.items():
    if not enabled(p): continue
    for prop,phs in n["refs"].items():
        for ph in (phs[0:1] if prop.endswith("gpios") else phs):
            tgt=byph.get(ph)
            if tgt is None: continue
            tn=nodes[tgt]
            if tn["compat"] and (not enabled(tgt) or not matched(tn)):
                print(f"   {p.split('/')[-1]} .{prop} -> {tgt.split('/')[-1]} {tn['compat']} enabled={enabled(tgt)} matched={matched(tn)}"); bad+=1
print(f"== {bad} findings (cpu nodes and unreferenced leaf nodes are informational) ==")
