#!/usr/bin/env python3
"""Measure a BlueBubbles install on the Mac (run as root; it launches the app as rolo).
   bb-measure.py INSTALL_DIR LABEL [--noidle] [--wldebug] [--ref] [--conversation=FX,FY] [--set=K=V] [--unset=K]
   -> JSON on stdout, screenshots in /tmp/bbshots-LABEL
Scrolls only the chat list with a virtual wheel (no clicks: no chat is opened, nothing is marked read).
--conversation=FX,FY additionally clicks the chat at that fraction of the window (pick one with no unread messages,
so opening it changes nothing), then scrolls the conversation pane; it never types, reacts or sends.
--ref also opens a plain GTK3 window for a size comparison; --wldebug adds Wayland frame commit statistics.
Refuses to start if a bluebubbles process is already running (the app data dir is shared)."""
import os, sys, time, json, subprocess, signal, glob, re, statistics as st
inst, label = sys.argv[1], sys.argv[2]
wld = '--wldebug' in sys.argv
RT = '/run/user/1001'
hl = subprocess.check_output(['pgrep', '-u', 'rolo', '-x', 'Hyprland']).split()[0].decode()
def penv(pid):
    try: return dict(l.split('=', 1) for l in open(f'/proc/{pid}/environ').read().split('\0') if '=' in l)
    except Exception: return {}
# Hyprland's own environ lacks hl.env() values; take the session env from a child that has GDK_SCALE (as the launcher sees it)
env = penv(hl)
for d in sorted(glob.glob('/proc/[0-9]*'), key=lambda x: int(x.split('/')[-1])):
    e2 = penv(d.split('/')[-1]); 
    if e2.get('GDK_SCALE') and e2.get('WAYLAND_DISPLAY') and e2.get('LD_LIBRARY_PATH'): env = e2; break
env.update(XDG_RUNTIME_DIR=RT, WAYLAND_DISPLAY='wayland-1')
sig = env.get('HYPRLAND_INSTANCE_SIGNATURE') or os.listdir(RT + '/hypr')[0]
env['HYPRLAND_INSTANCE_SIGNATURE'] = sig
if subprocess.run(['pgrep', '-x', 'bluebubbles']).returncode == 0:
    sys.exit('bluebubbles already running; close it first')
def asrolo(cmd, **kw):
    return subprocess.run(['runuser', '-u', 'rolo', '--', 'env'] + [f'{k}={v}' for k, v in env.items()] + cmd, capture_output=True, text=True, **kw).stdout
def clients(): return json.loads(asrolo(['hyprctl', '-j', 'clients']))
shots = f'/tmp/bbshots-{label}'; os.makedirs(shots, exist_ok=True); os.chmod(shots, 0o700); subprocess.run(['chown', 'rolo:rolo', shots])
errf = f'/tmp/bbwl-{label}.log'
genv = dict(env)
for a in sys.argv:
    if a.startswith('--set='): k, v = a[6:].split('=', 1); genv[k] = v
    if a.startswith('--unset='): genv.pop(a[8:], None)
if wld: genv['WAYLAND_DEBUG'] = 'client'
genv['BB_DIAG'] = '1'
t0 = time.time(); genv['BB_T0'] = str(int(t0 * 1000))
p = subprocess.Popen(['runuser', '-u', 'rolo', '--', 'env'] + [f'{k}={v}' for k, v in genv.items()] + ['setsid', 'bash', '-c', f'cd {inst} && exec ./bluebubbles 2>{errf}'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
pid = None; win = None
while time.time() - t0 < 60:
    pg = subprocess.run(['pgrep', '-x', 'bluebubbles'], capture_output=True, text=True).stdout.split()
    if pg: pid = int(pg[0])
    for c in clients():
        if pid and c['pid'] == pid: win = c
    if win: break
    time.sleep(0.05)
res = {'label': label, 'install': inst, 'wldebug': wld}
res['t_window_mapped_s'] = round(time.time() - t0, 2) if win else None
CLK = os.sysconf('SC_CLK_TCK')
def cpu(): 
    f = open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split(); return (int(f[11]) + int(f[12])) / CLK
_prev = {}
def ctx():
    # cumulative, monotonic: threads that exit keep their last count
    for t in glob.glob(f'/proc/{pid}/task/*/status'):
        try:
            s = open(t).read()
            _prev[t] = (int(re.search(r'^voluntary_ctxt_switches:\s+(\d+)', s, re.M).group(1)), int(re.search(r'^nonvoluntary_ctxt_switches:\s+(\d+)', s, re.M).group(1)))
        except Exception: pass
    return sum(a for a, b in _prev.values()), sum(b for a, b in _prev.values())
def rss(): return int(re.search(r'VmRSS:\s+(\d+)', open(f'/proc/{pid}/status').read()).group(1)) // 1024
# settle: cpu < 5% for 3 consecutive 1 s samples
last = cpu(); calm = 0; ts = time.time()
while time.time() - t0 < 120:
    time.sleep(1); c = cpu(); busy = (c - last) / (time.time() - ts) ; last, ts = c, time.time()
    calm = calm + 1 if busy < 0.05 else 0
    if calm >= 3: break
res['t_cpu_settled_s'] = round(time.time() - t0 - 3, 1); res['cpu_seconds_startup'] = round(cpu(), 1); res['rss_mb_after_start'] = rss()
maps = open(f'/proc/{pid}/maps').read()
res['gl_libs'] = sorted({os.path.basename(l.split()[-1]) for l in maps.splitlines() if re.search(r'aurora|asahi|llvmpipe|swrast|libEGL|libGLX|libgallium|libvulkan|libGLES', l)})
res['threads'] = len(os.listdir(f'/proc/{pid}/task'))
win = [c for c in clients() if c['pid'] == pid][0]
res['window'] = {k: win[k] for k in ('class', 'initialClass', 'at', 'size', 'floating', 'xwayland')}
res['launch_env'] = {k: v for k, v in genv.items() if k.startswith(('GDK_', 'QT_SCALE'))}
res['gdk_env'] = {k: v for k, v in (l.split('=', 1) for l in open(f'/proc/{pid}/environ').read().split('\0') if '=' in l) if k.startswith(('GDK_', 'QT_SCALE', 'FLUTTER'))}
orig_ws = json.loads(asrolo(['hyprctl', '-j', 'activeworkspace']))['id']
def raise_win():
    asrolo(['hyprctl', 'dispatch', f'hl.dsp.window.move({{ workspace = 9, window = "pid:{pid}" }})']); asrolo(['hyprctl', 'dispatch', 'hl.dsp.focus({ workspace = 9 })'])  # empty workspace: nothing overlaps the window in captures
    time.sleep(0.4)
def shot(name):
    raise_win()
    c = [c for c in clients() if c['pid'] == pid][0]; x, y = c['at']; w, h = c['size']
    asrolo(['grim', '-g', f'{x},{y} {w}x{h}', f'{shots}/{name}.png'])
    return os.path.getsize(f'{shots}/{name}.png') if os.path.exists(f'{shots}/{name}.png') else None
shot('start')
if '--ref' in sys.argv:
    # A plain GTK3 window in the desktop font next to the app (both land on workspace 9), for a size comparison.
    ref = subprocess.Popen(['runuser', '-u', 'rolo', '--', 'env'] + [f'{k}={v}' for k, v in env.items()] + ['python3', '/home/rolo/.local/share/bluebubbles-bench/gtk-ref.py', '12'], stdout=subprocess.PIPE, text=True)
    time.sleep(3.0)
    asrolo(['grim', f'{shots}/compare.png'])
    res['gtk_ref_geometry'] = [(c['class'], c['size']) for c in clients() if c['class'] != 'bluebubbles'][:3]
    res['gtk_ref_font'] = ref.stdout.readline().strip()
    ref.wait(timeout=30)
# idle 60 s
phases = {}
if '--noidle' not in sys.argv:
    c0, (v0, n0), t1 = cpu(), ctx(), time.time(); rs = []
    for _ in range(60): time.sleep(1); rs.append(rss())
    dt = time.time() - t1; v1, n1 = ctx(); phases['idle'] = [int((t1 - t0) * 1000), int((t1 - t0 + dt) * 1000)]
    res['idle60'] = {'cpu_pct': round((cpu() - c0) / dt * 100, 2), 'wakeups_per_s': round((v1 - v0) / dt, 1), 'nonvol_per_s': round((n1 - n0) / dt, 1), 'rss_mb_min_max': [min(rs), max(rs)]}
# scroll: virtual wheel over the window centre
import evdev
from evdev import UInput, ecodes as e
ui = UInput({e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_WHEEL_HI_RES], e.EV_KEY: [e.BTN_LEFT]}, name='bb-bench-wheel'); time.sleep(1)
x, y = win['at']; w, h = win['size']
def scroll_phase(seconds=10):
    cs, (v0, n0), tS = cpu(), ctx(), time.time()
    for i in range(seconds * 60):   # 60 notches/s, alternating direction every 2 s
        d = -1 if (i // 120) % 2 == 0 else 1
        ui.write(e.EV_REL, e.REL_WHEEL, d); ui.write(e.EV_REL, e.REL_WHEEL_HI_RES, d * 120); ui.syn(); time.sleep(1 / 60)
    tE = time.time(); v1, n1 = ctx()
    return {'cpu_pct': round((cpu() - cs) / (tE - tS) * 100, 1), 'wakeups_per_s': round((v1 - v0) / (tE - tS), 1), 'rss_mb': rss()}, (tS, tE)
def point_at(fx, fy):
    raise_win(); asrolo(['hyprctl', 'dispatch', f'hl.dsp.cursor.move({{ x = {x + int(w * fx)}, y = {y + int(h * fy)} }})'])
    time.sleep(0.4)
    for d in (3, -3, 3, -3): ui.write(e.EV_REL, e.REL_X, d); ui.syn(); time.sleep(0.05)  # a motion event makes the surface take pointer focus
point_at(0.18, 0.5)   # the chat list column of the split view
res['scroll10s'], (wl0, tE) = scroll_phase(); phases['list_scroll'] = [int((wl0 - t0) * 1000), int((tE - t0) * 1000)]
shot('after-scroll')
conv = [a for a in sys.argv if a.startswith('--conversation=')]
if conv:
    fx, fy = (float(v) for v in conv[0].split('=', 1)[1].split(','))
    point_at(fx, fy); ui.write(e.EV_KEY, e.BTN_LEFT, 1); ui.syn(); time.sleep(0.08); ui.write(e.EV_KEY, e.BTN_LEFT, 0); ui.syn()
    time.sleep(3)
    point_at(0.7, 0.5)   # the conversation pane of the split view
    res['conv_scroll10s'], (cwl0, ctE) = scroll_phase(); phases['conv_scroll'] = [int((cwl0 - t0) * 1000), int((ctE - t0) * 1000)]
    shot('conversation')
ui.close()
def smaps():
    roll = {}
    for l in open(f'/proc/{pid}/smaps_rollup'):
        m = re.match(r'(Rss|Pss|Pss_Anon|Pss_File|Pss_Shmem|Private_Dirty):\s+(\d+) kB', l)
        if m: roll[m.group(1)] = int(m.group(2)) // 1024
    cur = None; per = {}
    for l in open(f'/proc/{pid}/smaps'):
        if re.match(r'^[0-9a-f]+-[0-9a-f]+ ', l):
            parts = l.split(None, 5); cur = os.path.basename(parts[5].strip()) if len(parts) > 5 else '[anon]'
        elif l.startswith('Rss:') and cur is not None:
            per[cur] = per.get(cur, 0) + int(l.split()[1]) // 1024
    top = sorted(per.items(), key=lambda kv: -kv[1])[:8]
    return {'rollup_mb': roll, 'top_mappings_mb': top}
res['smaps_after_scroll'] = smaps()
res['wl_window'] = [wl0, tE]
res['phase_ms'] = phases   # relative to process start, the same clock as bbdiag_ms
def commit_stats(t_from, t_to):
    """Frame commit intervals of the busiest surface inside [t_from, t_to] (the trace stamps are UTC time of day)."""
    day0 = t_from - t_from % 86400
    ts_list = {}
    for l in open(errf, errors='replace'):
        m = re.match(r'\[(\d+):(\d+):(\d+\.\d+)\].*-> (wl_surface#\d+)\.commit\(\)', l)
        if m: ts_list.setdefault(m.group(4), []).append(day0 + int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)))
    best = {}
    for surf, t in ts_list.items():
        win_t = [v for v in t if t_from <= v <= t_to]
        if len(win_t) > len(best.get('t', [])): best = {'s': surf, 't': win_t}
    t = best.get('t', [])
    if len(t) <= 5: return None
    iv = [(b2 - a2) * 1000 for a2, b2 in zip(t, t[1:])]
    q = lambda p: round(sorted(iv)[min(len(iv) - 1, int(len(iv) * p))], 1)
    return {'surface': best['s'], 'commits': len(t), 'fps': round(len(t) / (t_to - t_from), 1), 'interval_ms_p50_p95_p99_max': [q(.5), q(.95), q(.99), round(max(iv), 1)], 'over_20ms_pct': round(100 * sum(i > 20 for i in iv) / len(iv), 1)}
if wld:
    cs_ = commit_stats(wl0, tE)
    if cs_: res['scroll_commits'] = cs_
    if conv:
        cs_ = commit_stats(cwl0, ctE)
        if cs_: res['conv_scroll_commits'] = cs_
subprocess.run(['pkill', '-TERM', '-x', 'bluebubbles']); time.sleep(2)
diag = {}
for l in open(errf, errors='replace'):
    m = re.match(r'BBDIAG (\S+) (-?\d+)$', l.strip())
    if m: diag[m.group(1)] = int(m.group(2))
    elif l.startswith('BBDIAG display'): diag['display'] = l.strip()[len('BBDIAG display '):]
    elif l.startswith('BBDIAG scale'): diag['scale'] = l.strip()[len('BBDIAG scale '):]
    elif l.startswith('BBDIAG frames'):
        # per 5 s window: frames produced, build and raster ms as p50/p95/max
        m2 = re.match(r'BBDIAG frames t=(\d+) n=(\d+) build_ms=(\S+) raster_ms=(\S+)', l.strip())
        if m2: diag.setdefault('frames', []).append({'t_ms': int(m2.group(1)), 'n': int(m2.group(2)), 'build': m2.group(3), 'raster': m2.group(4)})
res['bbdiag_ms'] = diag
if wld:
    txt = open(errf, errors='replace').read()
    res['wl_buffer_scale_calls'] = sorted(set(re.findall(r'set_buffer_scale\((\d+)\)', txt)))
    res['wl_buffer_sizes'] = sorted(set(f'{a}x{b}' for a, b in re.findall(r'create_immed\(new id wl_buffer#\d+, (\d+), (\d+)', txt)))
    res['xdg_configure'] = sorted(set(f'{a}x{b}' for a, b in re.findall(r'xdg_toplevel#\d+\.configure\((\d+), (\d+)', txt)))
    res['xdg_min_size'] = sorted(set(re.findall(r'set_min_size\((\d+, \d+)\)', txt)))
    res['fractional_scale_requested'] = 'get_fractional_scale' in txt
asrolo(['hyprctl', 'dispatch', f'hl.dsp.focus({{ workspace = {orig_ws} }})'])
res['shots_dir'] = shots
print(json.dumps(res, indent=1))
