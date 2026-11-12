#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""uinput-selfcheck.py - prove /dev/uinput and /dev/uhid work, with nothing but the stdlib.

  uinput: create a one-button device, find its evdev node, send a press and a release and
          read both back from /dev/input/eventN. The button is BTN_TRIGGER_HAPPY40, which no
          desktop binds, so this is safe in a live session.
  uhid:   create a HID device with a vendor-defined report descriptor (no input device comes
          of it), wait for it under /sys/bus/hid/devices, destroy it.

Run as the desktop user for uinput (that also checks the udev rule) and as root for uhid:
  uinput-selfcheck.py            both; uhid is SKIPped when /dev/uhid is not writable
Exit 0 = every test that ran passed, 1 = a failure.
"""
import fcntl, glob, os, select, struct, sys, time

EV_SYN, EV_KEY, BTN = 0, 1, 0x2e7
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_DEV_SETUP = 0x405c5503
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_GET_SYSNAME = lambda n: (2 << 30) | (n << 16) | (0x55 << 8) | 44
EVENT = "llHHi"

def uinput():
    fd = os.open("/dev/uinput", os.O_RDWR | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(fd, UI_SET_KEYBIT, BTN)
        fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x06, 0x4d35, 0x0004, 1, b"m5pro uinput selfcheck", 0))
        fcntl.ioctl(fd, UI_DEV_CREATE)
        try:
            buf = bytearray(64)
            fcntl.ioctl(fd, UI_GET_SYSNAME(len(buf)), buf)
            sysname = bytes(buf).split(b"\0")[0].decode()
            node = None
            for _ in range(40):
                ev = glob.glob(f"/sys/devices/virtual/input/{sysname}/event*")
                if ev and os.access("/dev/input/" + os.path.basename(ev[0]), os.R_OK):
                    node = "/dev/input/" + os.path.basename(ev[0]); break
                time.sleep(0.05)
            if not node: return f"no readable evdev node for {sysname}"
            rd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
            try:
                for v in (1, 0):
                    os.write(fd, struct.pack(EVENT, 0, 0, EV_KEY, BTN, v) + struct.pack(EVENT, 0, 0, EV_SYN, 0, 0))
                got, end = [], time.time() + 2
                while len(got) < 2 and time.time() < end:
                    if not select.select([rd], [], [], 0.2)[0]: continue
                    data = os.read(rd, struct.calcsize(EVENT) * 16)
                    for o in range(0, len(data), struct.calcsize(EVENT)):
                        _, _, t, c, v = struct.unpack_from(EVENT, data, o)
                        if t == EV_KEY and c == BTN: got.append(v)
                return None if got == [1, 0] else f"{node}: read back {got}, expected [1, 0]"
            finally:
                os.close(rd)
        finally:
            fcntl.ioctl(fd, UI_DEV_DESTROY)
    finally:
        os.close(fd)

def uhid():
    rd = bytes.fromhex("0600ff0901a1010902150026ff00750895018102c0")
    ev = struct.pack("<I128s64s64sHHIIII", 11, b"m5pro uhid selfcheck", b"", b"", len(rd), 0x06, 0x4d35, 0x0004, 1, 0)
    ev += rd.ljust(4096, b"\0")
    fd = os.open("/dev/uhid", os.O_RDWR | os.O_NONBLOCK)
    try:
        os.write(fd, ev)
        for _ in range(40):
            if glob.glob("/sys/bus/hid/devices/0006:00004D35:00000004.*"):
                os.write(fd, struct.pack("<I", 1).ljust(len(ev), b"\0"))
                return None
            time.sleep(0.05)
        return "no device under /sys/bus/hid/devices after UHID_CREATE2"
    finally:
        os.close(fd)

rc = 0
for name, dev, fn in (("uinput", "/dev/uinput", uinput), ("uhid", "/dev/uhid", uhid)):
    if not os.path.exists(dev):
        print(f"FAIL {name}: {dev} does not exist"); rc = 1; continue
    st = os.stat(dev); perm = f"{oct(st.st_mode & 0o777)} uid {st.st_uid} gid {st.st_gid}"
    if not os.access(dev, os.W_OK):
        if name == "uhid": print(f"SKIP uhid: {dev} not writable by uid {os.getuid()} ({perm}); run as root")
        else: print(f"FAIL uinput: {dev} not writable by uid {os.getuid()} ({perm})"); rc = 1
        continue
    try: err = fn()
    except OSError as e: err = f"{type(e).__name__}: {e}"
    if err: print(f"FAIL {name}: {err}"); rc = 1
    else: print(f"PASS {name}: {dev} ({perm})")
sys.exit(rc)
