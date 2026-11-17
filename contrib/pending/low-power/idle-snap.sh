#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# idle-snap.sh - read-only idle power snapshot on the J716s (MacBook Pro 16", M5 Pro).
#
#   bash idle-snap.sh [seconds] [label]     default 60 s
#
# Changes nothing. Samples the SMC power sensors once a second and takes before/after deltas of
# interrupts, cpufreq time-in-state, cpuidle, per-thread CPU time and context switches, plus a short
# perf count of wakeups by target task. Output: /var/tmp/power1/<label>-<YYYYmmdd-HHMMSS>/ (summary.txt).
set -u
export LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
DUR=${1:-60}
LABEL=${2:-idle}
OUT=/var/tmp/power1/$LABEL-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
SUM=$OUT/summary.txt
sum() { echo "$*" | tee -a "$SUM"; }

HW=""
for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name")" = macsmc_hwmon ] && HW=$h; done
lbl() { for l in "$HW"/power*_label; do [ "$(cat "$l")" = "$1" ] && echo "${l%_label}_input"; done; }
P_SYS=$(lbl "Total System Power"); P_AC=$(lbl "AC Input Power"); P_38=$(lbl "3.8 V Rail Power"); P_HP=$(lbl "Heatpipe Power")
BAT=/sys/class/power_supply/macsmc-battery

snap() { # $1 = tag
    cat /proc/interrupts > "$OUT/irq.$1"
    grep -H . /sys/devices/system/cpu/cpufreq/policy*/stats/time_in_state > "$OUT/tis.$1" 2>/dev/null
    grep -H . /sys/devices/system/cpu/cpufreq/policy*/stats/total_trans > "$OUT/trans.$1" 2>/dev/null
    grep -H . /sys/devices/system/cpu/cpu*/cpuidle/state*/{usage,time} > "$OUT/idle.$1" 2>/dev/null
    grep -H . /sys/devices/system/cpu/cpufreq/policy*/park_stats > "$OUT/park.$1" 2>/dev/null
    head -1 /proc/stat > "$OUT/stat.$1"
    # pid tid comm utime stime vcsw nvcsw
    for t in /proc/[0-9]*/task/[0-9]*; do
        s=$(cat "$t/stat" 2>/dev/null) || continue
        c=${s#*(}; c=${c%)*}; r=${s##*) }
        set -- $r
        v=$(awk '/^voluntary_ctxt_switches/{v=$2} /^nonvoluntary_ctxt_switches/{n=$2} END{print v+0, n+0}' "$t/status" 2>/dev/null)
        p=${t#/proc/}; p=${p%%/*}
        echo "$p ${t##*/} ${c// /_} ${12} ${13} $v"
    done > "$OUT/thr.$1"
}

sum "kernel $(uname -r)  label $LABEL  dur ${DUR}s  $(date -Is)"
sum "ac online $(cat /sys/class/power_supply/macsmc-ac/online)  battery $(cat $BAT/status) $(cat $BAT/capacity)%"
sum "backlight $(cat /sys/class/backlight/*/brightness) dpms $(cat /sys/class/drm/*/dpms 2>/dev/null | tr '\n' ' ')"
sum "profile $(powerprofilesctl get 2>/dev/null)  governors $(cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor | tr '\n' ' ') max $(cat /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq | tr '\n' ' ')"
sum "uclamp_min_rt_default $(sysctl -n kernel.sched_util_clamp_min_rt_default 2>/dev/null)"
sum "screensaver: $(pgrep -fa org.omarchy.screensaver | head -1)"
CLPC=$(ls -d /sys/kernel/debug/*performance-controller* 2>/dev/null | head -1)
[ -n "$CLPC" ] && timeout 3 cat "$CLPC/status" > "$OUT/clpc.before" 2>/dev/null

snap a
: > "$OUT/power.csv"
for i in $(seq 1 "$DUR"); do
    echo "$i $(cat "$P_SYS") $(cat "$P_AC") $(cat "$P_38") $(cat "$P_HP") $(cat $BAT/power_now)" >> "$OUT/power.csv"
    sleep 1
done
snap b
[ -n "$CLPC" ] && timeout 3 cat "$CLPC/status" > "$OUT/clpc.after" 2>/dev/null

# Wakeups by target task over 10 s (perf, counts only what the scheduler wakes)
if command -v perf >/dev/null; then
    timeout 30 perf record -q -a -e sched:sched_wakeup -e timer:hrtimer_expire_entry -e irq:irq_handler_entry \
        -o "$OUT/perf.data" -- sleep 10 >/dev/null 2>&1
    timeout 60 perf script -i "$OUT/perf.data" -F event,trace 2>/dev/null > "$OUT/perf.txt"
    {
        echo "--- wakeups/s by target comm (10 s)"
        grep sched_wakeup "$OUT/perf.txt" | sed -n 's/.*comm=\([^ ]*\) pid=.*/\1/p' | sort | uniq -c | sort -rn | head -25 | awk '{printf "%8.1f %s\n", $1/10, $2}'
        echo "--- hrtimer expiries/s by function (10 s)"
        grep hrtimer_expire_entry "$OUT/perf.txt" | sed -n 's/.*function=\([^ ]*\).*/\1/p' | sort | uniq -c | sort -rn | head -12 | awk '{printf "%8.1f %s\n", $1/10, $2}'
        echo "--- irqs/s by handler (10 s)"
        grep irq_handler_entry "$OUT/perf.txt" | sed -n 's/.*name=\([^ ]*\).*/\1/p' | sort | uniq -c | sort -rn | head -15 | awk '{printf "%8.1f %s\n", $1/10, $2}'
    } >> "$SUM"
    rm -f "$OUT/perf.data"
fi

python3 -I - "$OUT" "$DUR" >> "$SUM" <<'PY'
import sys, os, collections
out, dur = sys.argv[1], float(sys.argv[2])
rd = lambda n: open(os.path.join(out, n)).read().splitlines()
pw = [l.split() for l in rd("power.csv")]
def stats(col, scale):
    v = [int(r[col]) / scale for r in pw if len(r) > col]
    v.sort()
    return "mean %.3f  median %.3f  min %.3f  max %.3f" % (sum(v) / len(v), v[len(v) // 2], v[0], v[-1])
print("--- power (W, 1 s samples)")
print("system (PSTR)   ", stats(1, 1e6))
print("AC input        ", stats(2, 1e6))
print("3.8 V rail      ", stats(3, 1e6))
print("heatpipe        ", stats(4, 1e6))
print("battery power   ", stats(5, 1e6))
# cpu busy
a = list(map(int, rd("stat.a")[0].split()[1:])); b = list(map(int, rd("stat.b")[0].split()[1:]))
d = [y - x for x, y in zip(a, b)]; tot = sum(d)
print("--- cpu: busy %.2f%% of all CPUs (user %.2f sys %.2f irq %.2f softirq %.2f)" % (
    100 * (tot - d[3] - d[4]) / tot, 100 * d[0] / tot, 100 * d[2] / tot, 100 * d[5] / tot, 100 * d[6] / tot))
# irqs
def irqs(n):
    r = {}
    lines = rd(n); ncpu = len(lines[0].split())
    for l in lines[1:]:
        f = l.split()
        if not f: continue
        k = f[0].rstrip(":")
        cnt = 0; i = 1
        while i < len(f) and i <= ncpu and f[i].isdigit():
            cnt += int(f[i]); i += 1
        r[k] = (cnt, " ".join(f[i:])[:60])
    return r
ia, ib = irqs("irq.a"), irqs("irq.b")
dl = sorted(((ib[k][0] - ia.get(k, (0,))[0], k, ib[k][1]) for k in ib), reverse=True)
print("--- interrupts/s (top 20), total %.0f/s" % (sum(x[0] for x in dl) / dur))
for c, k, n in dl[:20]:
    print("%9.1f %-6s %s" % (c / dur, k, n))
# cpufreq residency
def tis(n):
    r = collections.defaultdict(dict)
    for l in rd(n):
        p, v = l.split(":", 1)
        pol = p.split("/")[6]
        f, t = v.split()
        r[pol][int(f)] = int(t)
    return r
ta, tb = tis("tis.a"), tis("tis.b")
print("--- cpufreq residency (share of the window, MHz:%)")
for pol in sorted(tb):
    d = {f: tb[pol][f] - ta[pol].get(f, 0) for f in tb[pol]}
    s = sum(d.values()) or 1
    top = sorted(d.items(), key=lambda x: -x[1])[:5]
    print("%-9s %s" % (pol, "  ".join("%d:%.0f%%" % (f // 1000, 100 * t / s) for f, t in top if t)))
tra = {l.split(":")[0].split("/")[6]: int(l.split(":")[1]) for l in rd("trans.a")}
trb = {l.split(":")[0].split("/")[6]: int(l.split(":")[1]) for l in rd("trans.b")}
print("transitions/s  " + "  ".join("%s %.0f" % (k, (trb[k] - tra[k]) / dur) for k in sorted(trb)))
# cpuidle
def idl(n):
    r = {}
    for l in rd(n):
        p, v = l.rsplit(":", 1)
        r[p] = int(v)
    return r
xa, xb = idl("idle.a"), idl("idle.b")
st = collections.defaultdict(lambda: [0, 0])
for k in xb:
    parts = k.split("/")
    s = parts[-2]; what = parts[-1]
    st[s][0 if what == "usage" else 1] += xb[k] - xa.get(k, 0)
print("--- cpuidle (all CPUs): " + "  ".join("%s entries/s %.0f residency %.1f%%" % (s, u / dur, 100 * t / 1e6 / dur / os.cpu_count()) for s, (u, t) in sorted(st.items())))
# threads
def thr(n):
    r = {}
    for l in rd(n):
        f = l.split()
        if len(f) < 7: continue
        r[(f[0], f[1])] = (f[2], int(f[3]) + int(f[4]), int(f[5]) + int(f[6]))
    return r
ha, hb = thr("thr.a"), thr("thr.b")
hz = os.sysconf("SC_CLK_TCK")
rows = []
for k, (c, cpu, cs) in hb.items():
    a0 = ha.get(k)
    if not a0: continue
    rows.append((cpu - a0[1], cs - a0[2], c, k[0], k[1]))
print("--- threads by CPU time (%% of one CPU) and context switches/s")
for cpu, cs, c, p, t in sorted(rows, reverse=True)[:20]:
    print("%6.2f%% %8.1f/s  %-24s pid %s tid %s" % (100 * cpu / hz / dur, cs / dur, c, p, t))
print("--- threads by context switches/s")
for cs, cpu, c, p, t in sorted(((r[1], r[0], r[2], r[3], r[4]) for r in rows), reverse=True)[:20]:
    print("%8.1f/s %6.2f%%  %-24s pid %s tid %s" % (cs / dur, 100 * cpu / hz / dur, c, p, t))
PY
[ -e "$OUT/park.b" ] && { echo "--- park_stats (after)"; cat "$OUT/park.b"; } >> "$SUM"
[ -e "$OUT/clpc.after" ] && { echo "--- CLPC (after)"; cat "$OUT/clpc.after"; } >> "$SUM"
touch "$OUT/DONE"
echo "$OUT"
