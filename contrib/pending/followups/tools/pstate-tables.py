#!/usr/bin/env python3
"""Compare a device tree's CPU OPP tables with the ADT's cluster voltage-state tables.

usage: pstate-tables.py <adt.bin> <t6050-base.dtsi>
(needs m1n1's proxyclient on PYTHONPATH, e.g. ~/Work/m1n1/proxyclient and its venv for 'construct')

For each OPP table, prints how many OPPs have opp-hz == ADT entry (opp-level - OFFSET) for OFFSET 1 and 2.
Reads only /arm-io/pmgr acc-clusters and voltage-states<k>-sram.
"""
import re
import sys

from m1n1 import adt

dt = adt.load_adt(open(sys.argv[1], 'rb').read())
pmgr = dt['/arm-io/pmgr']._properties
raw = pmgr['acc-clusters']
acc = {}
for i in range(0, len(raw), 8):
    v = int.from_bytes(raw[i:i + 4], 'little')
    acc[v >> 8] = v & 0xff


def entries(k):
    v = list(pmgr[f'voltage-states{k}-sram'])
    return [(f, mv) for f, mv in zip(v[0::2], v[1::2])]


text = open(sys.argv[2]).read()
for name, cluster in (('mcluster_opp', 0), ('pcluster_opp', 2)):
    m = re.search(name + r':\s*opp-table[^{]*\{(.*?)\n\t\};', text, re.S)
    if not m:
        print(name, 'not found')
        continue
    opps = {int(l): int(h) // 1000
            for h, l in re.findall(r'opp-hz = /bits/ 64 <(\d+)>;\s*opp-level = <(\d+)>', m.group(1))}
    ent = entries(acc[cluster])
    for off in (1, 2):
        ok = [l for l, f in opps.items() if 0 <= l - off < len(ent) and ent[l - off][0] == f]
        print(f'{name}: ADT entry = level - {off}: {len(ok)} of {len(opps)} OPPs match')
