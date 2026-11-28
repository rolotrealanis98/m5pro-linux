#!/usr/bin/env python3
"""Summarize bb-measure.py JSON files: bb-summary.py DIR  -> markdown table of medians per label.
File names are LABEL-N.json (full runs) and LABEL-wl.json (Wayland trace run)."""
import json, re, sys, glob, os, statistics as st

def load(p):
    t = open(p).read()
    return json.loads(t[t.index('{'):])

def med(v):
    v = [x for x in v if x is not None]
    return round(st.median(v), 2) if v else None

def get(d, *path):
    for k in path:
        if not isinstance(d, dict) or k not in d: return None
        d = d[k]
    return d

def frames_in(d, phase):
    ph = get(d, 'phase_ms', phase)
    fr = get(d, 'bbdiag_ms', 'frames')
    if not ph or not fr: return None
    sel = [f for f in fr if ph[0] <= f['t_ms'] - 0 <= ph[1] + 5000]
    return sel or None

def idle_frames_per_s(d):
    sel = frames_in(d, 'idle')
    return round(sum(f['n'] for f in sel) / (5 * len(sel)), 2) if sel else None

def p95(d, phase, key):
    sel = frames_in(d, phase)
    if not sel: return None
    vals = []
    for f in sel:
        try: vals.append(float(f[key].split('/')[1]))
        except Exception: pass
    return med(vals)

def main(root):
    groups = {}
    for p in sorted(glob.glob(os.path.join(root, '*.json'))):
        m = re.match(r'(.+)-(\d+|wl)\.json$', os.path.basename(p))
        if not m: continue
        try: groups.setdefault(m.group(1), {}).setdefault('wl' if m.group(2) == 'wl' else 'full', []).append(load(p))
        except Exception as e: print(f'skip {p}: {e}', file=sys.stderr)
    rows = [
        ('window mapped (s)', lambda r: get(r, 't_window_mapped_s')),
        ('first frame (ms)', lambda r: get(r, 'bbdiag_ms', 'first-frame')),
        ('splash closed = first usable frame (ms)', lambda r: get(r, 'bbdiag_ms', 'splash-closed')),
        ('ui ready (ms)', lambda r: get(r, 'bbdiag_ms', 'ui-ready')),
        ('CPU settled (s)', lambda r: get(r, 't_cpu_settled_s')),
        ('startup CPU seconds', lambda r: get(r, 'cpu_seconds_startup')),
        ('RSS after start (MB)', lambda r: get(r, 'rss_mb_after_start')),
        ('idle CPU %', lambda r: get(r, 'idle60', 'cpu_pct')),
        ('idle wakeups/s', lambda r: get(r, 'idle60', 'wakeups_per_s')),
        ('idle frames/s (app)', idle_frames_per_s),
        ('idle RSS max (MB)', lambda r: (get(r, 'idle60', 'rss_mb_min_max') or [None, None])[1]),
        ('list scroll CPU %', lambda r: get(r, 'scroll10s', 'cpu_pct')),
        ('list scroll RSS (MB)', lambda r: get(r, 'scroll10s', 'rss_mb')),
        ('list scroll build p95 (ms)', lambda r: p95(r, 'list_scroll', 'build')),
        ('list scroll raster p95 (ms)', lambda r: p95(r, 'list_scroll', 'raster')),
        ('conversation scroll CPU %', lambda r: get(r, 'conv_scroll10s', 'cpu_pct')),
        ('conversation scroll RSS (MB)', lambda r: get(r, 'conv_scroll10s', 'rss_mb')),
    ]
    wl_rows = [
        ('list scroll fps (commits)', lambda r: get(r, 'scroll_commits', 'fps')),
        ('list commit interval p50 (ms)', lambda r: (get(r, 'scroll_commits', 'interval_ms_p50_p95_p99_max') or [None])[0]),
        ('list commit interval p95 (ms)', lambda r: (get(r, 'scroll_commits', 'interval_ms_p50_p95_p99_max') or [None, None])[1]),
        ('conversation fps (commits)', lambda r: get(r, 'conv_scroll_commits', 'fps')),
        ('conversation commit p95 (ms)', lambda r: (get(r, 'conv_scroll_commits', 'interval_ms_p50_p95_p99_max') or [None, None])[1]),
    ]
    labels = sorted(groups)
    out = ['| metric | ' + ' | '.join(labels) + ' |', '|---|' + '---|' * len(labels)]
    for name, fn in rows:
        out.append(f'| {name} | ' + ' | '.join(str(med([fn(r) for r in groups[l].get("full", [])])) for l in labels) + ' |')
    for name, fn in wl_rows:
        out.append(f'| {name} | ' + ' | '.join(str(med([fn(r) for r in groups[l].get("wl", [])])) for l in labels) + ' |')
    out.append('| runs (full / traced) | ' + ' | '.join(f'{len(groups[l].get("full", []))} / {len(groups[l].get("wl", []))}' for l in labels) + ' |')
    print('\n'.join(out))

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
