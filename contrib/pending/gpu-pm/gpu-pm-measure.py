#!/usr/bin/env python3
"""GPU power-management measurement for the J716s. Root, non-interactive, read-only apart from the load it starts.

    python3 -I gpu-pm-measure.py LABEL OUTDIR [--idle S] [--loads NAME:S,NAME:S,...] [--bench]

LABEL    free text for the run (e.g. daily, observed); goes into every file name and the summary.
OUTDIR   created; one TSV per phase, summary.txt and summary.json inside.
--idle S       quiet-idle phase of S seconds (default 90; 0 skips). Nothing is started: leave the Mac alone.
--loads ...    GPU load phases through /home/rolo/gpu-ab/power2/load.sh (paced-flush, paced-finish, paced-heavy,
               glmark-terrain, vkmark-cube; default paced-finish:40,paced-heavy:40,glmark-terrain:60). "none" skips.
--bench        gpubench ALU/bandwidth/light (the same three tests as gpugov-runbook.sh bench), ~2 min.

What it reads (every file is read-only; reading never powers the GPU up):
  hwmon macsmc_hwmon  power1_input (Total System Power), power4_input (heatpipe), in uW
  /sys/kernel/debug/aurora-g17/power   core_power, cores_powered, gpu_power_mw (firmware's own GPU power),
                                       power_budget_mw, limiter_mask/limit, busy_permille, effort,
                                       policy_residency (kernels with gpu-pm commit d3df838aeb3d: raw table)
  /sys/class/drm/card0/device/agx_stats  busy_ns, pstate (reads unsupported on 27.3 firmware)
  /sys/kernel/debug/*performance-controller*/status   CLPC DCS / SoC floor states
  /sys/class/power_supply/*            AC online, battery status and capacity (recorded once per phase)
Per phase it writes the 1 Hz rows and reports: Total System Power avg/median/min/max, heatpipe avg, the share of
samples with the GPU cores powered (idle power-gate duty), mean firmware GPU power while powered, the highest
limiter mask seen (0x4 = emergency clamp), CLPC DCS/SoC maxima, busy_ns growth, and the residency-table words
that changed. Idle GPU power is the Total System Power of the idle phase with its duty cycle next to it: the
machine has no GPU-only rail sensor, so compare PSTR between runs, never read it as GPU watts.
"""
import glob, json, os, statistics, subprocess, sys, time

args = sys.argv[1:]
if len(args) < 2:
    sys.exit(__doc__)
LABEL, OUT = args[0], args[1]
idle_s, loads, bench = 90, 'paced-finish:40,paced-heavy:40,glmark-terrain:60', False
i = 2
while i < len(args):
    if args[i] == '--idle':
        idle_s = int(args[i + 1]); i += 2
    elif args[i] == '--loads':
        loads = args[i + 1]; i += 2
    elif args[i] == '--bench':
        bench = True; i += 1
    else:
        sys.exit('unknown argument ' + args[i])
os.makedirs(OUT, exist_ok=True)
P2 = '/home/rolo/gpu-ab/power2'


def rd(p):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return ''


def hwmon():
    for n in glob.glob('/sys/class/hwmon/hwmon*/name'):
        if rd(n).strip() == 'macsmc_hwmon':
            return os.path.dirname(n)
    return None


H = hwmon()
POWER = '/sys/kernel/debug/aurora-g17/power'
AGX = '/sys/class/drm/card0/device/agx_stats'
CLPC = (glob.glob('/sys/kernel/debug/*performance-controller*/status') or [''])[0]


def kv(text):
    d = {}
    for tok in text.replace('\n', ' ').split():
        if '=' in tok:
            k, v = tok.split('=', 1)
            d[k] = v
    return d


def num(s, base=10):
    try:
        return int(s, base)
    except (TypeError, ValueError):
        return None


def residency(text):
    out = {}
    for line in text.splitlines():
        if line.startswith('policy_residency'):
            for tok in line.split()[1:]:
                if ':' in tok:
                    k, v = tok.split(':', 1)
                    out[k] = v
    return out


def clpc():
    d = {'dcs': None, 'soc': None}
    for line in rd(CLPC).splitlines():
        f = line.split()
        if line.startswith('dcs:') and len(f) > 4:
            d['dcs'] = num(f[4])
        elif line.startswith('soc:') and len(f) > 4:
            d['soc'] = num(f[4])
    return d


def agx():
    d = {}
    for line in rd(AGX).splitlines():
        f = line.split()
        if len(f) >= 2:
            d[f[0]] = ' '.join(f[1:])
    return d


def supply():
    s = {}
    for d in glob.glob('/sys/class/power_supply/*'):
        n = os.path.basename(d)
        s[n] = {k: rd(f'{d}/{k}').strip() for k in ('online', 'status', 'capacity') if rd(f'{d}/{k}')}
    return s


def sample():
    g = rd(POWER)
    p = kv(g)
    c = clpc()
    a = agx()
    return {
        'pstr_mw': (num(rd(H + '/power1_input')) or 0) // 1000 if H else None,
        'heat_mw': (num(rd(H + '/power4_input')) or 0) // 1000 if H else None,
        'powered': p.get('cores_powered'),
        'core_power': p.get('core_power'),
        'gpu_mw': num(p.get('gpu_power_mw')),
        'budget_mw': num(p.get('power_budget_mw')),
        'limiter': num(p.get('limiter_mask', ''), 16) if p.get('limiter_mask', '').startswith('0x') else None,
        'busy_pm': num(p.get('busy_permille')),
        'effort': p.get('effort_published'),
        'dcs': c['dcs'], 'soc': c['soc'],
        'busy_ns': num(a.get('busy_ns', '').split()[0]) if a.get('busy_ns') else None,
        'pstate': a.get('pstate'),
        'res': residency(g),
    }


def phase(name, seconds, starter=None):
    """Sample at 1 Hz for `seconds` (the load, if any, runs on its own for the same time)."""
    proc = starter() if starter else None
    rows, t0 = [], time.monotonic()
    first = sample()
    last = t0
    while time.monotonic() - t0 < seconds:
        last += 1.0
        time.sleep(max(0.0, last - time.monotonic()))
        rows.append((time.monotonic() - t0, sample()))
    if proc:
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
    with open(f'{OUT}/{LABEL}-{name}.tsv', 'w') as f:
        f.write('t_s\tpstr_mw\theat_mw\tpowered\tcore_power\tgpu_mw\tbudget_mw\tlimiter\tbusy_pm\teffort\tdcs\tsoc\tbusy_ns\tpstate\n')
        for t, r in rows:
            f.write(f"{t:.1f}\t{r['pstr_mw']}\t{r['heat_mw']}\t{r['powered']}\t{r['core_power']}\t{r['gpu_mw']}\t"
                    f"{r['budget_mw']}\t{r['limiter']}\t{r['busy_pm']}\t{r['effort']}\t{r['dcs']}\t{r['soc']}\t"
                    f"{r['busy_ns']}\t{r['pstate']}\n")
    ps = [r['pstr_mw'] for _, r in rows if r['pstr_mw'] is not None]
    on = [r for _, r in rows if r['powered'] == 'true']
    gm = [r['gpu_mw'] for r in on if r['gpu_mw'] is not None]
    lim = [r['limiter'] for _, r in rows if r['limiter'] is not None]
    bn = [r['busy_ns'] for _, r in rows if r['busy_ns'] is not None]
    res_changed = {k: (first['res'].get(k, '0'), rows[-1][1]['res'][k]) for k in rows[-1][1]['res']
                   if rows and first['res'].get(k) != rows[-1][1]['res'][k]} if rows else {}
    s = {
        'phase': name, 'seconds': seconds, 'samples': len(rows),
        'pstr_w_avg': round(sum(ps) / len(ps) / 1000, 2) if ps else None,
        'pstr_w_median': round(statistics.median(ps) / 1000, 2) if ps else None,
        'pstr_w_min': round(min(ps) / 1000, 2) if ps else None,
        'pstr_w_max': round(max(ps) / 1000, 2) if ps else None,
        'heat_w_avg': round(sum(r['heat_mw'] for _, r in rows if r['heat_mw'] is not None) / max(1, len(rows)) / 1000, 2),
        'gpu_powered_share': round(len(on) / len(rows), 3) if rows else None,
        'gpu_fw_w_mean_when_powered': round(sum(gm) / len(gm) / 1000, 2) if gm else None,
        'power_budget_w': round(max((r['budget_mw'] or 0) for _, r in rows) / 1000, 1) if rows else None,
        'limiter_mask_max': hex(max(lim)) if lim else None,
        'clamp_samples_0x4': sum(1 for x in lim if x & 4),
        'dcs_max': max([r['dcs'] for _, r in rows if r['dcs'] is not None] or [None], key=lambda x: -1 if x is None else x),
        'soc_max': max([r['soc'] for _, r in rows if r['soc'] is not None] or [None], key=lambda x: -1 if x is None else x),
        'busy_ns_growth': (bn[-1] - bn[0]) if len(bn) > 1 else None,
        'pstate_values': sorted({r['pstate'] for _, r in rows if r['pstate']}),
        'residency_changed': res_changed,
        'supply': supply(),
    }
    return s


def load(name, seconds):
    def start():
        if not os.path.exists(P2 + '/load.sh'):
            return None
        return subprocess.Popen(['bash', P2 + '/load.sh', name, f'{OUT}/{LABEL}-{name}.load', str(seconds)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return start


def run_bench():
    env = {}
    for line in rd('/etc/mesa-aurora/session.env').splitlines():
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            env[k] = v
    res = {}
    for t in ('compute.heavy', 'copy.bw', 'compute.light'):
        try:
            out = subprocess.run(
                ['runuser', '-u', 'rolo', '--', 'env'] + [f'{k}={v}' for k, v in env.items()] +
                ['/opt/gpubench/bin/gpubench-vk', '--test', t, '--depths', '1,4', '--runs', '3', '--run-ms', '300',
                 '--warmup-ms', '200'], capture_output=True, text=True, timeout=120).stdout
        except (subprocess.TimeoutExpired, OSError) as e:
            res[t] = f'error {e}'
            continue
        for l in out.splitlines():
            try:
                d = json.loads(l)
                m = d['metrics']
                res[f"{d['test']} d{d['depth']}"] = {'gpu_us': m.get('gpu_us', {}).get('median'),
                                                       'us_per_submit': m['us_per_submit']['median']}
            except (ValueError, KeyError):
                pass
    return res


summary = {
    'label': LABEL, 'date': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'kernel': os.uname().release,
    'cmdline_aurora': [t for t in rd('/proc/cmdline').split() if t.startswith(('aurora.', 'clpc.', 'appledrm.'))],
    'dmesg_config': [l for l in subprocess.run(['dmesg'], capture_output=True, text=True).stdout.splitlines()
                     if 'J716s' in l and ('controller configuration' in l or 'macOS 27.2' in l)][-3:],
    'debugfs_power_line': rd(POWER).strip().splitlines()[-3:] if rd(POWER) else 'unreadable',
    'phases': [],
}
if not H or not rd(POWER):
    summary['warning'] = 'hwmon or aurora-g17 debugfs not readable: run as root on the J716s'
print(json.dumps({k: summary[k] for k in ('label', 'kernel', 'cmdline_aurora', 'dmesg_config')}), flush=True)
if idle_s:
    summary['phases'].append(phase('idle', idle_s))
    print(json.dumps(summary['phases'][-1]), flush=True)
if loads != 'none':
    for item in loads.split(','):
        n, _, sec = item.partition(':')
        sec = int(sec or 40)
        summary['phases'].append(phase(n, sec, load(n, sec)))
        print(json.dumps(summary['phases'][-1]), flush=True)
        time.sleep(5)
if bench:
    summary['bench'] = run_bench()
    print(json.dumps(summary['bench']), flush=True)
summary['faults'] = [l for l in subprocess.run(['dmesg'], capture_output=True, text=True).stdout.splitlines()
                     if any(w in l.lower() for w in ('fault', 'timed out', 'timeout', 'recover', 'in-fence'))
                     and any(w in l.lower() for w in ('aurora', 'g17', 'asahi', 'gpu'))
                     and 'command line' not in l.lower() and 'm5_pause_timeout' not in l][-10:]
with open(f'{OUT}/{LABEL}-summary.json', 'w') as f:
    json.dump(summary, f, indent=1)
with open(f'{OUT}/{LABEL}-summary.txt', 'w') as f:
    f.write(f"{LABEL} kernel {summary['kernel']} {' '.join(summary['cmdline_aurora'])}\n")
    for p in summary['phases']:
        f.write(f"{p['phase']:16s} PSTR avg {p['pstr_w_avg']} med {p['pstr_w_median']} min {p['pstr_w_min']} max {p['pstr_w_max']} W"
                f" | heat {p['heat_w_avg']} W | gpu powered {p['gpu_powered_share']} | fw gpu {p['gpu_fw_w_mean_when_powered']} W"
                f" | budget {p['power_budget_w']} W | limiter max {p['limiter_mask_max']} clamp {p['clamp_samples_0x4']}"
                f" | dcs {p['dcs_max']} soc {p['soc_max']}\n")
    if 'bench' in summary:
        f.write('bench ' + json.dumps(summary['bench']) + '\n')
    f.write('faults ' + json.dumps(summary['faults']) + '\n')
print(open(f'{OUT}/{LABEL}-summary.txt').read())
