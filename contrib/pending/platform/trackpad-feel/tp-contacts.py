#!/usr/bin/env python3
"""Summarise the J716s trackpad's raw contacts from hidraw: state, class, size, position.

Run as root while touching the pad (any kernel; it reads hidraw, it does not grab the device):

    sudo python3 -I tp-contacts.py [--seconds N] [--label NAME] [-v] [/dev/hidrawN]

One line per contact when it lifts, and a summary at the end (Ctrl-C or --seconds). With
--label, the same lines also go to ./tp-<label>.txt.

It reads the bytes hid-magicmouse parses (magicmouse_raw_event_mtp): a 38-byte header (finger
count at byte 22, button at byte 23), then 30-byte records (struct tp_finger):
  byte 0 contact id, byte 1 state (1 first seen, 2 hovering, 3 touch down, 4 touching,
  5 lifting, 6 after lift, 7 gone), byte 2 class (0 unclassified, 1 thumb, 2-5 finger,
  6-7 palm, 10/12 seen at the edges), then the le16 fields.

Columns:
  pre     classes seen before the contact first touched down (state 3)
  first   class at the first touching frame
  touch   classes while touching (state 3-5), most common first
  tMaj/tMin  largest touch major/minor, scaled << 1 as evdev reports them (libinput's
          AttrTouchSizeRange / AttrPalmSizeThreshold units)
  tool    largest raw tool major (the unit of hid_magicmouse.mtp_palm_tool_min)
  x,y     where it was last touching, in mm: x from the pad's centre, y up from the front edge
  path    distance travelled while touching, mm
  press   largest pressure (about grams)
  verdict what the j716s-trackpad kernel reports: hover (never touched, dropped by
          mtp_hover_filter), palm-early, palm-size (classed and tool > mtp_palm_tool_min),
          finger. Uses the live mtp_palm_* parameters when the kernel has them.
"""
import argparse
import collections
import glob
import os
import select
import struct
import sys
import time

HDR, REC, RES = 38, 30, 98.0  # header bytes, record bytes, units per mm (evdev resolution)
Y_FRONT = -163  # raw y of the front edge (evdev y max is 163, and evdev y = -raw y)
PARAMS = "/sys/module/hid_magicmouse/parameters/"


def find_node():
    for d in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(d, "device/uevent")) as f:
                if "HID_NAME=Apple MTP multi-touch" in f.read():
                    return "/dev/" + os.path.basename(d)
        except OSError:
            pass
    sys.exit("no 'Apple MTP multi-touch' hidraw node found")


def param(name, default):
    try:
        with open(PARAMS + name) as f:
            v = int(f.read().strip())
            return default if v < 0 else v
    except (OSError, ValueError):
        return default


def verdict(c):
    if not c["touched"]:
        return "hover"
    if c["palm"]:
        return c["palm"]
    return "finger"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("node", nargs="?")
    ap.add_argument("--seconds", type=float, default=0)
    ap.add_argument("--label")
    ap.add_argument("-v", action="store_true", help="also print every touching frame")
    a = ap.parse_args()
    node = a.node or find_node()
    early = param("mtp_palm_early", 1)  # the J716s default
    tool_min = param("mtp_palm_tool_min", 1400)
    out = open(f"tp-{a.label}.txt", "w") if a.label else None

    def emit(s):
        print(s)
        if out:
            out.write(s + "\n")

    emit(f"# {node} label={a.label} rule: early={early} tool_min={tool_min}")
    emit(f"{'pre':9} {'first':>5} {'touch':16} {'tMaj':>5} {'tMin':>5} {'tool':>5} "
         f"{'x':>6} {'y':>5} {'path':>5} {'press':>5}  verdict")
    live, done = {}, []

    def close(c):
        done.append(c)
        if not c["touched"] and not a.v:
            return  # hover-only contacts go to the summary only
        touch = ",".join(f"{k}:{n}" for k, n in c["cls"].most_common(3))
        pre = ",".join(str(k) for k in sorted(c["pre"])) or "-"
        emit(f"{pre:9} {c.get('first', '-'):>5} {touch:16} {c['tmaj']:5d} {c['tmin']:5d} "
             f"{c['tool']:5d} {c['x']:6.1f} {c['y']:5.1f} {c['path']:5.1f} {c['press']:5d}  "
             f"{verdict(c)}")

    fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
    end = time.time() + a.seconds if a.seconds else None
    try:
        while end is None or time.time() < end:
            if not select.select([fd], [], [], 0.25)[0]:
                continue
            data = os.read(fd, 4096)
            if len(data) < HDR or (len(data) - HDR) % REC:
                continue
            n = data[22]
            if n * REC > len(data) - HDR:
                continue
            seen = set()
            for i in range(n):
                r = data[HDR + i * REC: HDR + (i + 1) * REC]
                cid, state, cls = r[0], r[1], r[2]
                (x, y, _rx, _ry, tool, _toolmin, _orient, tmaj, tmin, _u0, _u1, press,
                 _multi) = struct.unpack("<hhhhhhhhhhhhH", r[4:])
                seen.add(cid)
                c = live.setdefault(cid, dict(pre=set(), cls=collections.Counter(), touched=False,
                                              finger=False, palm=None, tmaj=0, tmin=0, tool=0,
                                              lo=1 << 30,
                                              x=0.0, y=0.0, path=0.0, last=None, press=0))
                touching = 3 <= state <= 5
                classed = cls >= 6
                # Mirror magicmouse_mtp_update_palms() on the J716s.
                if c["palm"] is None:
                    if classed and tool > tool_min:
                        c["palm"] = "palm-size"
                    elif classed and early and not c["finger"]:
                        c["palm"] = "palm-early"
                    elif touching:
                        c["finger"] = True
                if not touching:
                    if not c["touched"]:
                        c["pre"].add(cls)
                    continue
                if not c["touched"]:
                    c["first"] = cls
                c["touched"] = True
                c["cls"][cls] += 1
                c["tmaj"], c["tmin"] = max(c["tmaj"], tmaj << 1), max(c["tmin"], tmin << 1)
                c["lo"] = min(c["lo"], tmaj << 1, tmin << 1)
                c["tool"], c["press"] = max(c["tool"], tool), max(c["press"], press)
                pos = (x / RES, (y - Y_FRONT) / RES)
                if c["last"]:
                    c["path"] += ((pos[0] - c["last"][0]) ** 2 + (pos[1] - c["last"][1]) ** 2) ** 0.5
                c["last"], c["x"], c["y"] = pos, pos[0], pos[1]
                if a.v:
                    print(f"  id {cid:3d} st {state} cls {cls:2d} tMaj {tmaj << 1:5d} tMin {tmin << 1:5d} "
                          f"tool {tool:5d} x {pos[0]:6.1f} y {pos[1]:5.1f} press {press:4d}")
            for cid in [k for k in live if k not in seen]:
                close(live.pop(cid))
    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)
    for c in live.values():
        close(c)

    emit("\n# summary")
    v = collections.Counter(verdict(c) for c in done)
    emit("# contacts: " + ", ".join(f"{k} {n}" for k, n in sorted(v.items())))
    for name in ("finger", "palm-early", "palm-size"):
        cs = [c for c in done if verdict(c) == name]
        if cs:
            emit(f"# {name:10s} tMaj max {max(c['tmaj'] for c in cs):5d}  tMin max "
                 f"{max(c['tmin'] for c in cs):5d}  smallest axis while touching "
                 f"{min(c['lo'] for c in cs):5d}  tool max {max(c['tool'] for c in cs):5d}  "
                 f"path max {max(c['path'] for c in cs):5.1f} mm")
    if out:
        out.close()


if __name__ == "__main__":
    main()
