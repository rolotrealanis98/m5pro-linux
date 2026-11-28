#!/usr/bin/env python3
"""Start BlueBubbles (or, with --exec CMD ARGS, any command) as rolo with the Hyprland session environment (run as root over ssh). Used to relaunch after a bench run."""
import glob, subprocess, sys
def penv(pid):
    try: return dict(l.split('=', 1) for l in open(f'/proc/{pid}/environ').read().split('\0') if '=' in l)
    except Exception: return {}
env = {}
for d in sorted(glob.glob('/proc/[0-9]*'), key=lambda x: int(x.split('/')[-1])):
    e = penv(d.split('/')[-1])
    if e.get('GDK_SCALE') and e.get('WAYLAND_DISPLAY') and e.get('LD_LIBRARY_PATH'): env = e; break
if not env: sys.exit('no session environment found')
env.update(XDG_RUNTIME_DIR='/run/user/1001')
subprocess.Popen(['runuser', '-u', 'rolo', '--', 'env'] + [f'{k}={v}' for k, v in env.items()] + ['setsid', '-f'] + (sys.argv[2:] if sys.argv[1:2] == ['--exec'] else ['/home/rolo/.local/bin/bluebubbles'] + sys.argv[1:]), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
