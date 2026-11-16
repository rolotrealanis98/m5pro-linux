#!/usr/bin/env python3
"""vrrcadence-analyze.py OUTDIR: swap-complete cadence and latency per phase, static-phase event rates and power."""
import re, sys, os, statistics as st, collections

D = sys.argv[1]
SKIP = 1.5
SUB = 1000 / 240
bad = 0

def phases(path):
    ph = None; meta = {}; ev = collections.OrderedDict()
    for line in open(path, errors="replace"):
        m = re.search(r"tracing_mark_write: vrrcadence: phase (\S+) vrr=(\d) fps=(-?\d+)", line)
        if m:
            ph = m.group(1); meta[ph] = (int(m.group(2)), int(m.group(3))); ev[ph] = []; continue
        if ph:
            m = re.search(r"\s(\d+\.\d+): (\w+):\s?(.*)", line)
            if m:
                ev[ph].append((float(m.group(1)), m.group(2), m.group(3)))
    return meta, ev

# ---- pass 1: cadence
meta, ev = phases(os.path.join(D, "trace-cadence.txt"))
print("%-14s %5s %6s %5s %5s %5s %5s | %6s %6s %6s | %6s %6s %5s" % (
    "phase", "n", "mean", "p5", "p50", "p95", "max", "lat", "latmx", "lat<1", "lattice", "inSF", "stall"))
rows = {}
for ph, es in ev.items():
    vrr, fps = meta[ph]
    sub = {}; comp = []
    for t, name, rest in es:
        m = re.search(r"swap_id=(\d+)", rest)
        if not m: continue
        if name == "iomfb_swap_submit": sub[int(m.group(1))] = t
        elif name == "iomfb_swap_complete": comp.append((t, int(m.group(1))))
    if len(comp) < 6:
        print("%-14s too few swap completions (%d)" % (ph, len(comp))); bad += 1; continue
    t0 = comp[0][0]
    comp = [c for c in comp if c[0] - t0 >= SKIP]
    iv = sorted((b[0] - a[0]) * 1000 for a, b in zip(comp, comp[1:]))
    lat = [(t - sub[i]) * 1000 for t, i in comp if i in sub]
    period = 1000 / fps
    p = lambda q: iv[min(len(iv) - 1, int(len(iv) * q))]
    mean = sum(iv) / len(iv)
    # on the 240 Hz subframe lattice: interval within 0.35 ms of a multiple of 4.167 ms
    lattice = sum(abs(x / SUB - round(x / SUB)) * SUB < 0.35 for x in iv) / len(iv)
    inside = sum(abs(x - period) <= SUB + 0.4 for x in iv) / len(iv)
    stalls = sum(x > 2 * period + 1 for x in iv)
    rows[ph] = (vrr, fps, mean, inside, lattice, stalls, period, st.mean(lat) if lat else -1)
    print("%-14s %5d %6.2f %5.1f %5.1f %5.1f %5.1f | %6.2f %6.2f %5.0f%% | %5.0f%% %5.0f%% %5d" % (
        ph, len(iv), mean, p(.05), p(.5), p(.95), iv[-1], st.mean(lat) if lat else -1, max(lat) if lat else -1,
        100 * sum(l < 1 for l in lat) / max(1, len(lat)), lattice * 100, inside * 100, stalls))

print()
for ph, (vrr, fps, mean, inside, lattice, stalls, period, lat) in rows.items():
    if not vrr: continue
    ok = abs(mean - period) <= 0.02 * period and stalls == 0 and lattice >= 0.9
    print("PASS" if ok else "FAIL", ph, "mean %.2f vs %.2f ms, %.0f%% of intervals on the 4.17 ms lattice, %d stalls" % (mean, period, lattice * 100, stalls))
    bad += not ok
    o = [r for r in rows.values() if r[0] == 0 and r[1] == fps]
    if o:
        print("     off: mean %.2f, lattice %.0f%%, latency %.2f ms | on: latency %.2f ms (swap submit to complete)" % (o[0][2], o[0][4] * 100, o[0][7], lat))

# swap_info words (first run only): do displayed / blob words move with the request time?
info = [(t, r) for es in ev.values() for t, n, r in es if n == "iomfb_swap_complete_info"]
print("\nswap_complete_info samples: %d" % len(info))
for t, r in info[100:103]:
    print("  %.6f %s" % (t, r[:300]))

# ---- pass 2: static
sp = os.path.join(D, "trace-static.txt")
print()
if os.path.exists(sp):
    meta, ev = phases(sp)
    print("static phases (all dcp events, per second):")
    for ph, es in ev.items():
        if not es: print("  %-12s no events" % ph); continue
        span = max(1.0, es[-1][0] - es[0][0])
        c = collections.Counter(n for _, n, _ in es)
        print("  %-12s %5.1f events/s  %s" % (ph, len(es) / span, dict(c.most_common(6))))
cs = os.path.join(D, "client-static.txt")
if os.path.exists(cs):
    pw = {}
    for l in open(cs):
        m = re.search(r"static-result (\S+) power mean (-?\d+) mW min (-?\d+) max (-?\d+) \((\d+) samples, status (.*)\)", l)
        if m: pw.setdefault(m.group(1), []).append((int(m.group(2)), m.group(6)))
    print("\nstatic power (battery, mW):", dict(pw))
    off = [x[0] for x in pw.get("vrr0-static", []) if x[0] > 0]; on = [x[0] for x in pw.get("vrr1-static", []) if x[0] > 0]
    stat = {x[1] for v in pw.values() for x in v}
    if off and on:
        d = sum(off) / len(off) - sum(on) / len(on)
        print("VRR on vs off at a static image: %+.0f mW (positive = on uses less); battery status %s" % (d, stat))
        print("EFFECT" if d > 100 and "Discharging" in stat else "NO MEASURABLE EFFECT (or charging: power not comparable)")
    else:
        print("no power samples (power_supply not readable or zero)")

dm = open(os.path.join(D, "dmesg.txt"), errors="replace").read()
errs = re.findall(r"^.*(?:timed out|crashed|swap failed|not completed|retraining).*$", dm, re.M)
print()
if errs:
    print("FAIL dmesg has display errors:"); bad += 1
    for e in errs[:10]: print("   ", e[:200])
else:
    print("PASS no swap timeouts / DCP errors in dmesg")
print("OVERALL", "FAIL" if bad else "PASS")
sys.exit(1 if bad else 0)
