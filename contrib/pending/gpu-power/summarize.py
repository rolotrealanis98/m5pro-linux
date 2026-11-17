#!/usr/bin/env python3
"""Summarize an ab.sh output folder: per load and knob value, mean over rounds of
Total System Power, heatpipe power, GPU-powered and full-effort duty, DCS/fabric mean, busy share
(fdinfo, permille) and the load's own figure (FPS or latency).
    python3 -I summarize.py OUTDIR [SKIP_S]
"""
import glob, os, re, statistics as st, sys
from collections import defaultdict

d = sys.argv[1]
skip = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

def load_metric(path):
    try:
        t = open(path).read()
    except OSError:
        return None
    m = re.search(r'FPS: (\d+)', t)
    if m:
        return ('fps', float(m.group(1)))
    m = re.search(r'total frames \d+ fps ([\d.]+) lat_avg_us (\d+) lat_p50_us \d+ lat_p95_us (\d+)', t)
    if m:
        return ('lat_us', float(m.group(2)), float(m.group(3)))
    m = re.search(r'total frames \d+ fps ([\d.]+) late (\d+)', t)
    if m:
        return ('late', float(m.group(2)))
    return None

rows = defaultdict(list)
for f in sorted(glob.glob(os.path.join(d, '*.tsv'))):
    name = os.path.basename(f)[:-4]
    m = re.match(r'(.+)-([^-]+)-r(\d+)$', name)
    if not m:
        continue
    load, val, r = m.groups()
    data = []
    for line in open(f):
        if line.startswith('#'):
            continue
        p = line.split()
        if len(p) < 10 or float(p[0]) < skip:
            continue
        data.append(p)
    if not data:
        continue
    num = lambda i: [float(x[i]) for x in data if x[i].lstrip('-').isdigit()]
    rows[(load, val)].append({
        'pstr': st.mean(num(1)) / 1000, 'heat': st.mean(num(2)) / 1000,
        'on': sum(x[3] == 'true' for x in data) / len(data),
        'full': sum(x[4] == 'true' for x in data) / len(data),
        'dcs': st.mean(num(5) or [0]), 'soc': st.mean(num(6) or [0]),
        'share': st.mean(num(8) or [0]),
        'metric': load_metric(f[:-4] + '.out'),
    })

print(f"{'load':16} {'val':5} {'n':>2} {'PSTR W':>14} {'heat W':>7} {'gpu on':>6} {'full':>5} {'dcs':>4} {'soc':>4} {'share':>6}  metric")
for (load, val), rs in sorted(rows.items()):
    ps = [r['pstr'] for r in rs]
    ms = [r['metric'] for r in rs if r['metric']]
    if ms and ms[0][0] == 'lat_us':
        metric = 'lat avg %s us, p95 %s us' % ('/'.join('%.0f' % m[1] for m in ms), '/'.join('%.0f' % m[2] for m in ms))
    elif ms:
        metric = '%s %s' % (ms[0][0], '/'.join('%.0f' % m[1] for m in ms))
    else:
        metric = ''
    print(f"{load:16} {val:5} {len(rs):>2} {st.mean(ps):6.2f} ({'/'.join('%.1f' % p for p in ps)}) "
          f"{st.mean(r['heat'] for r in rs):7.2f} {st.mean(r['on'] for r in rs):6.2f} {st.mean(r['full'] for r in rs):5.2f} "
          f"{st.mean(r['dcs'] for r in rs):4.1f} {st.mean(r['soc'] for r in rs):4.1f} {st.mean(r['share'] for r in rs):6.0f}  {metric}")
