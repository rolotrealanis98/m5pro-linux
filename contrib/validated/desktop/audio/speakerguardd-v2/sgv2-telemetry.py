#!/usr/bin/python3 -I
# m5pro-linux: read-only decoder of speakerguardd v2's engine page, for the pin 04169c44 (layout 3).
# Rewritten 2026-11-17 (speakers-5) from betizzel/omarchy-m5 installer/recipes/speakerguardd-v2-upstream/
# sgv2-telemetry.py @ 1b9d5ef99def (MIT, Copyright (c) betizzel and omarchy-m5 contributors), whose output
# was misread in speakers-4: it printed powers with 4 decimals (a quiet tone's microwatts read 0.0000 W), called
# the spp3 pilot-bin powers "V/I mean squares", and printed the unit-wide meters that only lsm2 publishes (NaN
# = absent on spp3, see crates/sgv2-core/src/telemetry.rs). Field meanings below are from the engine source
# (crates/sgv2-core/src/spp3.rs telemetry(), crates/sgv2-lv2/src/page.rs). Reads only; writes nothing on the
# machine except the optional --log file.
"""sgv2-telemetry [ENGINE] [--watch SECONDS] [--interval S] [--log FILE] [--params BLOB]

ENGINE defaults to /run/speakerguardd/<seat uid>/engine. Without --watch: the header and the latest record.
With --watch: every record for SECONDS, then a summary and verdict lines (RESULT <check> PASS|FAIL|INFO).

spp3 (the J716s's unit) in plain words:
  P_mod     modeled power per channel from the program (feed-forward). The coil model and the thermal gain
            run on this alone; it must be finite and above 0 while a tone plays.
  P_meas    always 0 on spp3: macOS's SPP3 publishes no measured-power meter and neither does the engine.
  V2, I2    NOT broadband V/I. The last 0.34 s window's power in the 43.9 Hz pilot bin (Goertzel), scaled to
            V^2 / A^2. The pilot is injected only while a channel's drive is >= PilotEnableThres (30 mW on
            AID41). Below that the bin holds only the sense noise floor (~1e-9 V^2 / ~1e-10 A^2): non-zero
            means sense samples arrive; exactly 0 while playing means no sense samples reach the engine.
  fresh     1 while a pilot window was accepted (V2, I2 over the floors and R within RebRange) within the
            last window: the closed-loop coil temperature cl is a current measurement.
  global    unit-wide meters, published by lsm2 only: "absent" on spp3, not a fault.
"""
import math
import os
import re
import struct
import subprocess
import sys
import time

TELE = 920
SLOT = 8 + TELE
RING_OFF = 4096
N = 256
CH = 108
MAXCH = 8
HEALTH = [(1 << 0, "FAILSAFE"), (1 << 1, "NO_PARAMS"), (1 << 2, "CHANNEL_MISMATCH"), (1 << 3, "OPEN_LOOP"),
          (1 << 4, "MODEL_FAULT"), (1 << 5, "MODEL_RANGE"), (1 << 6, "SENSE_IMPLAUSIBLE")]
BAD = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6)
OPEN_LOOP = 1 << 3
SENSE_BOUND = {0: "plugin did not say", 1: "no binding offered", 2: "bound to an LSID companion",
               3: "offered; spp3 has no LSID companion, nothing to bind (normal: spp3 reads its sense ports directly)",
               4: "refused by the LSID companion"}
AMPS = {0: "supervisor did not say", 1: "held (no grant, or PCM not started)", 2: "playing"}


def health_str(h):
    s = [n for b, n in HEALTH if h & b]
    return f"{h:#x}" + (f" ({' '.join(s)})" if s else " (ok)")


def header(b):
    magic, layout, crc, lat, chans, sense, pid = struct.unpack_from('<QIIIIII', b, 0)
    seq, frames, mono = struct.unpack_from('<QQQ', b, 32)
    health, sdel, mg = struct.unpack_from('<IiI', b, 56)
    # after the two hand-off slots (616 bytes each, from offset 72): see crates/sgv2-lv2/src/page.rs
    amps, = struct.unpack_from('<I', b, 1308)
    wake_frames, wakes = struct.unpack_from('<II', b, 1320)
    bind_crc, = struct.unpack_from('<I', b, 1336)
    bind_ns, = struct.unpack_from('<Q', b, 1344)
    bound, = struct.unpack_from('<I', b, 1352)
    return dict(magic=magic.to_bytes(8, 'little'), layout=layout, crc=crc, channels=chans, sense=sense, pid=pid,
                seq=seq, frames=frames, mono=mono, health=health, sdel=sdel,
                min_gain=struct.unpack('<f', struct.pack('<I', mg))[0], amps=amps, wakes=wakes,
                wake_frames=wake_frames, bind_crc=bind_crc, bind_ns=bind_ns, bound=bound)


def chan(b, o):
    f = struct.unpack_from('<8f', b, o)
    gain, vms, ims, r = struct.unpack_from('<4f', b, o + 92)
    return dict(mod_w=f[0], meas_w=f[1], coil_c=f[2], mag_c=f[3], ol_c=f[4], cl_c=f[5], tlim_adj=f[6],
                closed=b[o + 32], fresh=b[o + 33], gain=gain, v2=vms, i2=ims, r=r)


def record(fd, idx):
    """Record number idx, or None if overwritten or being written (ring seqlock)."""
    o = RING_OFF + 64 + (idx % N) * SLOT
    raw = os.pread(fd, SLOT, o)
    again, = struct.unpack('<Q', os.pread(fd, 8, o))
    seq, = struct.unpack_from('<Q', raw, 0)
    if seq != 2 * (idx + 1) or again != seq:
        return None
    frame, h = struct.unpack_from('<QI', raw, 8)
    chs = [chan(raw, 8 + 12 + c * CH) for c in range(MAXCH)]
    g = struct.unpack_from('<10f', raw, 8 + 12 + MAXCH * CH)
    return dict(idx=idx, frame=frame, health=h, ch=chs, glob=g)


def params(path):
    """The fields this decoder needs from the compiled blob, via the package's own decoder (root only)."""
    try:
        out = subprocess.run(['aurora-speaker-tuning', 'blob', path], capture_output=True, text=True,
                             timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    keys = ('vmon_scale', 'imon_scale', 'v_pwr_thres', 'i_pwr_thres', 'pilot_enable_thres', 'reb_range_min',
            'reb_range_max', 'cal_r', 'temp_sense_window_time_s', 'temperature_limit')
    per = {k: [float(x) for x in re.findall(rf'^\s+{k}: ([-0-9.e]+),', out, re.M)] for k in keys}
    if not per['vmon_scale']:
        return None
    unit = re.search(r'unit: (\d+)', out)
    per['unit'] = int(unit.group(1)).to_bytes(4, 'big').decode(errors='replace') if unit else '?'
    per['ambient'] = float(re.search(r'thermal_ambient_temp: ([-0-9.e]+)', out).group(1))
    return per


def default_engine():
    uid = None
    try:
        for line in open('/etc/speakerguardd/speakerguardd.conf'):
            if line.startswith('SGV2_UID='):
                uid = line.split('=', 1)[1].strip().strip('"')
    except OSError:
        pass
    return f"/run/speakerguardd/{uid or os.getuid()}/engine"


def fmt_w(w):
    if math.isnan(w):
        return "nan"
    return f"{w * 1e3:.3g}mW" if w >= 1e-3 or w == 0 else f"{w * 1e6:.3g}uW"


def lane_state(x, floor, playing=True):
    if math.isnan(x):
        return "none yet"
    if x == 0:
        return "ZERO" if playing else "0, idle: sense unlinked"
    if floor and x >= floor:
        return "pilot"
    return "noise"


def print_header(hd, p):
    print(f"engine page: magic={hd['magic']} layout={hd['layout']} params_crc={hd['crc']:08x} channels={hd['channels']} "
          f"sense={hd['sense']} unit={p['unit'] if p else '?'} quanta={hd['seq']} frames={hd['frames']}")
    print(f"  health {health_str(hd['health'])}  min_gain {hd['min_gain']:.4f}  amps: {AMPS.get(hd['amps'], hd['amps'])}  "
          f"wakes {hd['wakes']}")
    print(f"  sense delay estimator: {'not locked' if hd['sdel'] < 0 else str(hd['sdel']) + ' frames (V tracks the program)'}")
    proven = hd['bind_crc'] != 0 and hd['bind_crc'] == hd['crc']
    print(f"  sense input proven by the supervisor (self-check wiring, linked, unity): {'yes' if proven else 'no'}; "
          f"binding: {SENSE_BOUND.get(hd['bound'], hd['bound'])}")


def print_record(r, n, p, playing=True):
    print(f"record {r['idx']} frame={r['frame']} health {health_str(r['health'])}")
    vf = p['v_pwr_thres'][0] if p else 0
    inf = p['i_pwr_thres'][0] if p else 0
    for c in range(n):
        s = r['ch'][c]
        gdb = 20 * math.log10(s['gain']) if s['gain'] > 0 else float('nan')
        print(f" ch{c}: P_mod={fmt_w(s['mod_w'])} coil={s['coil_c']:.3f}C magnet={s['mag_c']:.3f}C "
              f"tlim_adj={s['tlim_adj']:+.1f}K gain={gdb:+.2f}dB | pilot bin V2={s['v2']:.3g} ({lane_state(s['v2'], vf, playing)}) "
              f"I2={s['i2']:.3g} ({lane_state(s['i2'], inf, playing)}) closed={s['closed']} fresh={s['fresh']} "
              f"cl={s['cl_c']:.2f}C R={s['r']:.3f}ohm")
    g = r['glob']
    if all(math.isnan(x) for x in g[:3]):
        print(" global: absent (unit-wide meters are lsm2-only; spp3 leaves them NaN by design)")
    else:
        print(f" global: P_mod={fmt_w(g[0])} P_meas={fmt_w(g[1])} thermal_gain={g[2]:.2f}dB power_gain={g[7]:.4f}")


FAILS = []


def res(check, verdict, text, log):
    if verdict == 'FAIL':
        FAILS.append(check)
    line = f"RESULT {check} {verdict}: {text}"
    print(line)
    if log:
        log.write(line + "\n")


def watch(path, fd, secs, interval, logpath, p):
    log = open(logpath, 'w') if logpath else None
    b = os.pread(fd, 4096, 0)
    hd = header(b)
    n = min(hd['channels'] or MAXCH, MAXCH)
    nxt, = struct.unpack('<Q', os.pread(fd, 8, RING_OFF))
    end = time.monotonic() + secs
    recs, lost, playing_polls, polls, sdel_seen, bad_h = [], 0, 0, 0, set(), 0
    while time.monotonic() < end:
        hd = header(os.pread(fd, 4096, 0))
        polls += 1
        playing = hd['amps'] == 2
        playing_polls += playing
        if hd['sdel'] >= 0:
            sdel_seen.add(hd['sdel'])
        head, = struct.unpack('<Q', os.pread(fd, 8, RING_OFF))
        if head - nxt > N:
            lost += head - nxt - N
            nxt = head - N
        for i in range(nxt, head):
            r = record(fd, i)
            if r is None:
                lost += 1
                continue
            r['playing'] = playing
            recs.append(r)
            if log:
                cs = r['ch'][:n]
                log.write(f"{time.monotonic():.3f} rec={i} amps={hd['amps']} sdel={hd['sdel']} h={r['health']:#x} " +
                          " ".join(f"c{c}:P={s['mod_w']:.4g},T={s['coil_c']:.4g},V2={s['v2']:.3g},I2={s['i2']:.3g},"
                                   f"f={s['fresh']},R={s['r']:.4g},g={s['gain']:.4g}" for c, s in enumerate(cs)) + "\n")
        nxt = head
        time.sleep(interval)
    print_header(hd, p)
    if recs:
        print_record(recs[-1], n, p, recs[-1]['playing'])
    # verdicts over the records written while the supervisor said "playing"
    play = [r for r in recs if r['playing']]
    res('records', 'INFO', f"{len(recs)} records ({lost} lost), {len(play)} while playing; "
        f"amps playing in {playing_polls}/{polls} polls", log)
    for r in recs:
        if r['health'] & BAD:
            bad_h |= r['health']
    res('health', 'FAIL' if bad_h else 'PASS',
        health_str(bad_h) if bad_h else "no FAILSAFE/MODEL_FAULT/MODEL_RANGE/SENSE_IMPLAUSIBLE in any record", log)
    nans = [c for c in range(n) for r in recs if any(math.isnan(r['ch'][c][k]) for k in ('mod_w', 'coil_c', 'gain'))]
    res('finite', 'FAIL' if nans else 'PASS',
        f"NaN P_mod/coil/gain on channels {sorted(set(nans))}" if nans else "P_mod, coil, gain finite on every channel", log)
    if not play:
        res('playing', 'INFO', "nothing played during the watch: the sense and model checks below need a stream", log)
        return 1 if FAILS else 0
    # skip the first quarter of the playing records: the first pilot window (0.34 s) still holds pre-stream zeros
    steady = play[len(play) // 4:] if len(play) > 8 else play
    ol = sum(1 for r in steady if r['health'] & OPEN_LOOP)
    res('sense-complete', 'FAIL' if ol > len(steady) // 10 else 'PASS',
        f"OPEN_LOOP (sense samples missing or non-finite) in {ol}/{len(steady)} playing records", log)
    zero = [f"ch{c}{k[0].upper()}" for c in range(n) for k in ('v2', 'i2')
            if sum(1 for r in steady if r['ch'][c][k] == 0) > len(steady) // 2]
    vmin = min((r['ch'][c]['v2'] for r in steady for c in range(n)), default=float('nan'))
    imin = min((r['ch'][c]['i2'] for r in steady for c in range(n)), default=float('nan'))
    res('sense-alive', 'FAIL' if zero else 'PASS',
        (f"pilot bin exactly 0 (no sense samples) on {' '.join(zero)}" if zero else
         f"all {2 * n} lanes non-zero while playing (lowest V2 {vmin:.3g}, I2 {imin:.3g})"), log)
    pmax = [max(r['ch'][c]['mod_w'] for r in steady) for c in range(n)]
    dead = [c for c in range(n) if not pmax[c] > 0]
    res('model-fed', 'FAIL' if dead else 'PASS',
        (f"P_mod stayed 0 on channels {dead} while playing" if dead else
         "P_mod > 0 on every channel; peak " + " ".join(f"ch{c} {fmt_w(pmax[c])}" for c in range(n))), log)
    tmax = max(r['ch'][c]['coil_c'] for r in recs for c in range(n))
    amb = p['ambient'] if p else float('nan')
    res('coil', 'INFO', f"hottest modeled coil {tmax:.3f} C (model ambient {amb:g} C, limit "
        f"{p['temperature_limit'][0] if p else float('nan'):g} C)", log)
    thr = p['pilot_enable_thres'][0] if p else 0.03
    driven = [c for c in range(n) if pmax[c] >= thr]
    if not driven:
        res('closed-loop', 'INFO', f"no channel reached the pilot drive ({fmt_w(thr)}): no pilot, no closed-loop "
            f"window expected; the protection runs on the feed-forward model (as on macOS below that drive)", log)
    else:
        bad = []
        for c in driven:
            fr = [r for r in steady if r['ch'][c]['fresh']]
            rr = [r['ch'][c]['r'] for r in fr]
            lo, hi = (p['reb_range_min'][c], p['reb_range_max'][c]) if p else (0, 99)
            if not fr or not all(lo <= x <= hi for x in rr):
                bad.append(f"ch{c} fresh {len(fr)}/{len(steady)} R {min(rr) if rr else float('nan'):.3f}-"
                           f"{max(rr) if rr else float('nan'):.3f}")
        res('closed-loop', 'FAIL' if bad else 'PASS',
            ("driven but no plausible pilot window: " + "; ".join(bad)) if bad else
            f"pilot windows accepted, R in RebRange on driven channels {driven}", log)
    res('sense-delay', 'INFO', f"delay estimator locked at {sorted(sdel_seen)} frames" if sdel_seen else
        "delay estimator did not lock (normal for short, quiet tones)", log)
    res('verdict', 'FAIL' if FAILS else 'PASS', f"failed: {' '.join(FAILS)}" if FAILS else "every check above holds", log)
    if log:
        log.close()
    return 1 if FAILS else 0


def main():
    a = sys.argv[1:]
    opt = {'--watch': None, '--interval': '0.2', '--log': None, '--params': None}
    pos = []
    while a:
        x = a.pop(0)
        if x in opt and a:
            opt[x] = a.pop(0)
        elif x in ('-h', '--help'):
            print(__doc__)
            return 0
        else:
            pos.append(x)
    path = pos[0] if pos else default_engine()
    ppath = opt['--params']
    if not ppath:
        ppath = '/var/lib/speakerguardd/params.bin'
        try:
            for line in open('/etc/speakerguardd/speakerguardd.conf'):
                if line.startswith('SGV2_PARAMS='):
                    ppath = line.split('=', 1)[1].strip().strip('"')
        except OSError:
            pass
    p = params(ppath)
    if p is None:
        print(f"(could not decode {ppath}: run as root for thresholds; lane states use no floors)")
    fd = os.open(path, os.O_RDONLY)
    if opt['--watch']:
        return watch(path, fd, float(opt['--watch']), float(opt['--interval']), opt['--log'], p)
    hd = header(os.pread(fd, 4096, 0))
    print_header(hd, p)
    if p:
        print(f"  pilot drive {fmt_w(p['pilot_enable_thres'][0])}/channel; pilot-bin floors V2 {p['v_pwr_thres'][0]:g} "
              f"I2 {p['i_pwr_thres'][0]:g}; RebRange {p['reb_range_min'][0]:g}-{p['reb_range_max'][0]:g} ohm")
    head, = struct.unpack('<Q', os.pread(fd, 8, RING_OFF))
    if head == 0:
        print("no telemetry yet")
        return 0
    r = None
    for k in range(1, 4):
        r = record(fd, head - k)
        if r:
            break
    if r is None:
        print("latest records busy; run again")
        return 1
    print_record(r, min(hd['channels'] or MAXCH, MAXCH), p, hd['amps'] == 2)
    return 0


if __name__ == '__main__':
    sys.exit(main())
