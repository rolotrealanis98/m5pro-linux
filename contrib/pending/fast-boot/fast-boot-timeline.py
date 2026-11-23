#!/usr/bin/env python3
"""Boot timeline of the CURRENT boot on the J716s, from the aura log (mtd0) and the kernel/journal clocks. Read-only.

  python3 fast-boot-timeline.py [BOOT]       run as root on the Mac; BOOT is a journalctl -b offset (default 0)

Seconds are "since power-on" where the counter allows it: the aura log counts from the SoC reset (iBoot + stage 1 included),
and the kernel clock starts when aura vectors into it, so  since_power_on = aura_end + kernel_time.
Prints one line per stage, then the gaps. Works on any payload (verbose or quiet); a missing marker prints "-".
"""
import json, re, subprocess, sys

boot = sys.argv[1] if len(sys.argv) > 1 else "0"
def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout

# --- aura log: the 16 KiB ring in mtd0 starts at the oldest line; the wrap point is where the text jumps back in time
def aura():
    try: raw = open("/dev/mtd0ro", "rb").read().replace(b"\0", b"").replace(b"\xff", b"").decode("latin1")
    except OSError: return None
    i = raw.find("TLR_EL1")
    txt = raw[i:] + raw[:i] if i >= 0 else raw
    rows = [(float(m.group(1)), m.group(2)) for m in re.finditer(r"^\[\s*([\d.]+)\] (.*)$", txt, re.M)]
    return rows
A = aura()
def at(rows, pat, last=False):
    hit = [t for t, m in rows if re.search(pat, m)]
    return (hit[-1] if last else hit[0]) if hit else None

# --- kernel clock + journal (short-monotonic of the journal is receipt time; kernel lines use their own stamp)
k = {}
for line in sh(f"journalctl -b {boot} -k -o json --output-fields=MESSAGE,_SOURCE_MONOTONIC_TIMESTAMP --no-pager").splitlines():
    try: d = json.loads(line)
    except ValueError: continue
    m = d.get("MESSAGE"); t = int(d.get("_SOURCE_MONOTONIC_TIMESTAMP", 0)) / 1e6
    if isinstance(m, str): k.setdefault(m, t)
def kt(pat):
    for m, t in k.items():
        if re.search(pat, m): return t
    return None
j = []
for line in sh(f"journalctl -b {boot} -o short-monotonic --no-pager").splitlines():
    m = re.match(r"\[\s*([\d.]+)\] \S+ (.*)", line)
    if m: j.append((float(m.group(1)), m.group(2)))
def jt(pat, nth=0):
    hit = [t for t, m in j if re.search(pat, m)]
    return hit[nth] if len(hit) > nth else None

a_start = at(A, r"MMU: running with MMU") if A else None
a_end = at(A, r"Vectoring to next stage\.\.\.$", last=True) if A else None
off = a_end or 0.0
ev = [
 ("aura starts (iBoot + stage 1 done)",            a_start, True),
 ("aura vectors into the kernel",                  a_end, True),
 ("kernel: Run /init",                             kt(r"^Run /init"), False),
 ("kernel: root mounted",                          kt(r"EXT4-fs \(.*\): mounted filesystem"), False),
 ("systemd starts",                                kt(r"^systemd .* running in system mode"), False),
 ("basic.target",                                  jt(r"Reached target Basic System"), False),
 ("getty@tty2 started",                            jt(r"Started Getty on tty2"), False),
 ("autologin (login on tty2)",                     jt(r"LOGIN ON tty2"), False),
 ("graphical.target",                              jt(r"Reached target Graphical Interface"), False),
 ("Hyprland session up",                           jt(r"Reached target Hyprland session"), False),
 ("lock screen asked for (PAM fingerprint start)", jt(r"omarchy-lock-fingerprint"), False),
 ("panel blanked (DPMS off, brightness 0)",        kt(r"brightness_changed: brightness value: 0$"), False),
 ("session-restore plan",                          jt(r"m5pro-session-restore.*plan:"), False),
]
print(f"boot {boot}: {sh('uname -r').strip()}   cmdline: {sh('cat /proc/cmdline').strip()[:110]}...")
print(f"{'stage':50} {'clock':>9} {'since power-on':>15} {'gap':>7}")
prev = None
for name, t, is_aura in ev:
    if t is None: print(f"{name:50} {'-':>9} {'-':>15}"); continue
    abs_t = t if is_aura else (t + off if a_end else None)
    gap = f"{abs_t - prev:7.2f}" if abs_t is not None and prev is not None else ""
    print(f"{name:50} {t:9.2f} {abs_t if abs_t is not None else float('nan'):15.2f} {gap:>7}")
    if abs_t is not None: prev = abs_t
if A:
    n = len(A); print(f"\naura log: {n} lines from {A[0][0]:.2f} s to {A[-1][0]:.2f} s ({A[-1][0]-A[0][0]:.2f} s in aura)")
    big = [(t2 - t1, m) for (t1, _), (t2, m) in zip(A, A[1:]) if t2 - t1 > 0.2]
    for g, m in big: print(f"  {g:5.2f} s before: {m[:90]}")
print("\nsystemd-analyze:", sh("systemd-analyze 2>/dev/null").strip())
print("critical path to graphical.target:"); print(sh("systemd-analyze critical-chain graphical.target 2>/dev/null | head -12"))
