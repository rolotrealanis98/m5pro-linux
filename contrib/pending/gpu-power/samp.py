#!/usr/bin/env python3
"""GPU power sampler for the J716s (root, read-only).

    python3 -I samp.py SECONDS [PERIOD_S] > file.tsv

One row per period: time, Total System Power and heatpipe power (mW, macsmc hwmon), whether the
GPU cores were powered and the effort was full (aurora-g17 debugfs), the CLPC DCS/fabric states
and vote reason, the GPU busy share over the period in permille from two feeds:
  share_fd  sum of drm-engine-* of every aurora client (fdinfo), the feed aurora #1369 uses;
  share_fw  agx_stats busy_ns (firmware utilisation records).
With --power-policy it also prints the gpu_power_policy debugfs line (kernels that have it).
"""
import glob, os, sys, time

N = float(sys.argv[1]) if len(sys.argv) > 1 else 30
P = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
POLICY = '/sys/kernel/debug/aurora-g17/power_policy'

def rd(p):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return ''

H = next(os.path.dirname(n) for n in glob.glob('/sys/class/hwmon/hwmon*/name') if rd(n).strip() == 'macsmc_hwmon')
C = (glob.glob('/sys/kernel/debug/*performance-controller*/status') or [''])[0]
A = '/sys/class/drm/card0/device/agx_stats'
CL = '/sys/kernel/debug/dri/2300000000.gpu/clients'

def kv(text):
    out = {}
    for tok in text.split():
        if '=' in tok:
            k, v = tok.split('=', 1)
            out[k] = v
    return out

def engine_ns():
    pids = set()
    for line in rd(CL).splitlines()[1:]:
        f = line.split()
        if len(f) > 1 and f[1].isdigit():
            pids.add(f[1])
    seen = {}
    for p in pids:
        for fd in glob.glob(f'/proc/{p}/fdinfo/*'):
            t = rd(fd)
            if 'drm-driver:\taurora' not in t:
                continue
            cid, s = None, 0
            for line in t.splitlines():
                if line.startswith('drm-client-id:'):
                    cid = line.split()[1]
                elif line.startswith('drm-engine-'):
                    s += int(line.split()[1])
            if cid is not None:
                seen[cid] = s
    return sum(seen.values())

def clpc():
    d = {'dcs': '?', 'soc': '?', 'reason': '?'}
    for line in rd(C).splitlines():
        f = line.split()
        if line.startswith('dcs:'):
            d['dcs'] = f[4]
        elif line.startswith('soc:'):
            d['soc'] = f[4]
        elif line.startswith('last_vote:'):
            d['reason'] = f[3]
    return d

def agx_busy():
    for line in rd(A).splitlines():
        if line.startswith('busy_ns'):
            try:
                return int(line.split()[1])
            except ValueError:
                return None
    return None

print('# t_s pstr_mw heat_mw cores_powered effort_full dcs soc reason share_fd share_fw' +
      (' policy' if os.path.exists(POLICY) else ''))
t0 = time.monotonic()
e0, b0, last = engine_ns(), agx_busy(), t0
while True:
    nxt = last + P
    time.sleep(max(0.0, nxt - time.monotonic()))
    now = time.monotonic()
    pw = int(rd(H + '/power1_input') or 0) // 1000
    hp = int(rd(H + '/power4_input') or 0) // 1000
    g = kv(rd('/sys/kernel/debug/aurora-g17/power'))
    c = clpc()
    e, b = engine_ns(), agx_busy()
    dt = (now - last) * 1e9
    sf = int((e - e0) * 1000 / dt) if dt > 0 else 0
    sw = int((b - b0) * 1000 / dt) if dt > 0 and b is not None and b0 is not None else -1
    e0, b0, last = e, b, now
    row = f"{now - t0:.2f} {pw} {hp} {g.get('cores_powered', '?')} {g.get('effort_full', '?')} " \
          f"{c['dcs']} {c['soc']} {c['reason']} {sf} {sw}"
    if os.path.exists(POLICY):
        row += ' ' + rd(POLICY).strip().replace(' ', ',')
    print(row, flush=True)
    if now - t0 >= N:
        break
