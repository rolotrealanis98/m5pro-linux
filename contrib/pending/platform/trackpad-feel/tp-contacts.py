#!/usr/bin/env python3
"""Print the J716s trackpad's raw contact records from hidraw, to check palm/thumb classes and sizes.

Run as root while touching the pad:  sudo python3 -I tp-contacts.py [/dev/hidrawN]
Ctrl-C prints a per-class summary. Reads the same bytes hid-magicmouse parses
(magicmouse_raw_event_mtp): a 38-byte header (report ID first, finger count at byte 22,
button at byte 23) followed by 30-byte finger records (struct tp_finger).

Columns: id = contact ID (low byte of word 0), cls = controller class (low byte of word 1;
on T6041: 1 thumb, 2-3 finger, 6+ palm), and the sizes exactly as evdev reports them
(touch/tool major and minor << 1, the units of the libinput size quirks), pressure (about grams).
"""
import glob
import os
import struct
import sys

HDR = 38
REC = 30


def find_node():
    for d in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(d, "device/uevent")) as f:
                if "HID_NAME=Apple MTP multi-touch" in f.read():
                    return "/dev/" + os.path.basename(d)
        except OSError:
            pass
    sys.exit("no 'Apple MTP multi-touch' hidraw node found")


def main():
    node = sys.argv[1] if len(sys.argv) > 1 else find_node()
    stats = {}
    print(f"reading {node}; touch the pad, Ctrl-C for the summary")
    print(" id cls  touchMaj touchMin  toolMaj toolMin  press      x      y  btn")
    fd = os.open(node, os.O_RDONLY)
    try:
        while True:
            data = os.read(fd, 4096)
            if len(data) < HDR or (len(data) - HDR) % REC:
                continue
            n = data[22]
            if n * REC > len(data) - HDR:
                continue
            for i in range(n):
                r = data[HDR + i * REC: HDR + (i + 1) * REC]
                (w0, w1, x, y, _rx, _ry, tool_maj, tool_min, _orient, touch_maj, touch_min,
                 _u0, _u1, press, _multi) = struct.unpack("<HHhhhhhhhhhhhhH", r)
                if touch_maj == 0:
                    continue  # hovering; the driver drops these too
                cid, cls = w0 & 0xFF, w1 & 0xFF
                tm, tn, wm, wn = touch_maj << 1, touch_min << 1, tool_maj << 1, tool_min << 1
                print(f"{cid:3d} {cls:3d} {tm:9d} {tn:8d} {wm:8d} {wn:7d} {press:6d} {x:6d} {-y:6d}  {data[23] & 1}")
                s = stats.setdefault(cls, [0, 1 << 30, 0, 1 << 30, 0])
                s[0] += 1
                s[1] = min(s[1], tm)
                s[2] = max(s[2], tm)
                s[3] = min(s[3], tn)
                s[4] = max(s[4], tn)
    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)
    print("\nclass  samples  touchMajor min..max  touchMinor min..max")
    for cls in sorted(stats):
        c, a, b, d, e = stats[cls]
        print(f"{cls:5d} {c:8d} {a:9d} .. {b:<9d} {d:6d} .. {e}")


if __name__ == "__main__":
    main()
