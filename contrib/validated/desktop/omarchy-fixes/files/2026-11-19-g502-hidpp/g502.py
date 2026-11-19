#!/usr/bin/env python3
"""Talk HID++ 2.0 to a Logitech G502 X (LIGHTSPEED / PLUS) through the receiver's hidraw node.

No Solaar and no kernel HID++ driver needed (this kernel has CONFIG_HID_LOGITECH off): the
receiver's vendor interface is opened directly, which needs read/write access to its
/dev/hidraw node (a udev uaccess rule, see udev/42-logitech-hidraw.rules).

  g502.py --read             status JSON
  g502.py --set-dpi N        set sensor DPI, print status
  g502.py --set-rate MS      set report interval (1/2/4/8 ms), print status
  g502.py --onboard on|off   onboard profiles (on) or host control (off), print status

Status JSON: {ok, error, present, name, battery, battery_level, charging, external_power,
dpi, dpi_min, dpi_max, dpi_step, dpi_values, rate_ms, rates_ms, onboard}
"""

import fcntl
import glob
import json
import os
import select
import sys
import time

LOGI_VID = 0x046D
RECEIVERS = {0xC547, 0xC539, 0xC53A, 0xC53D, 0xC545, 0xC541, 0xC54D}
DEADLINE = time.monotonic() + 4.0
SWID = 0x0A

F_ROOT, F_NAME, F_UNIFIED_BATTERY, F_BATTERY_VOLTAGE = 0x0000, 0x0005, 0x1004, 0x1001
F_DPI, F_REPORT_RATE, F_ONBOARD = 0x2201, 0x8060, 0x8100


class HidppError(Exception):
    pass


def hidraw_nodes():
    """The receiver's HID++ interface: vendor usage page 0xFF00 with long report id 0x11."""
    out = []
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(path, "device", "uevent")) as f:
                ue = f.read()
            with open(os.path.join(path, "device", "report_descriptor"), "rb") as f:
                desc = f.read()
        except OSError:
            continue
        hid = [l.split("=", 1)[1] for l in ue.splitlines() if l.startswith("HID_ID=")]
        if not hid:
            continue
        _, vid, pid = hid[0].split(":")
        if int(vid, 16) != LOGI_VID or int(pid, 16) not in RECEIVERS:
            continue
        if b"\x06\x00\xff" in desc and b"\x85\x11" in desc:
            out.append("/dev/" + os.path.basename(path))
    return out


class Dev:
    def __init__(self, fd, idx):
        self.fd, self.idx, self.features = fd, idx, {}

    def _xfer(self, feat_idx, func, params=b"", timeout=0.6):
        req = bytes([0x11, self.idx, feat_idx, (func << 4) | SWID]) + bytes(params)
        req = req.ljust(20, b"\0")
        os.write(self.fd, req)
        end = min(time.monotonic() + timeout, DEADLINE)
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise HidppError("timeout")
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                raise HidppError("timeout")
            rep = os.read(self.fd, 64)
            if len(rep) < 7 or rep[0] not in (0x10, 0x11) or rep[1] != self.idx:
                continue
            if rep[2] == 0x8F and rep[3] == feat_idx:          # HID++ 1.0 error (device offline, ...)
                raise HidppError("hidpp1 error %d" % rep[5])
            if rep[2] == 0xFF and rep[3] == feat_idx and rep[4] == ((func << 4) | SWID):
                raise HidppError("hidpp2 error %d" % rep[5])
            if rep[2] == feat_idx and rep[3] == ((func << 4) | SWID):
                return rep[4:]

    def ping(self):
        r = self._xfer(0x00, 1, b"\0\0\x5A", timeout=0.4)
        return r[0] >= 2

    def feature(self, fid):
        if fid not in self.features:
            r = self._xfer(0x00, 0, bytes([fid >> 8, fid & 0xFF]))
            self.features[fid] = r[0] or None
        return self.features[fid]

    def call(self, fid, func, params=b""):
        idx = self.feature(fid)
        if idx is None:
            raise HidppError("feature %04x missing" % fid)
        return self._xfer(idx, func, params)

    def name(self):
        n = self.call(F_NAME, 0)[0]
        s = b""
        while len(s) < n:
            s += self.call(F_NAME, 1, bytes([len(s)]))[: n - len(s)]
        return s.decode("ascii", "replace").strip("\0 ")


def open_device():
    nodes = hidraw_nodes()
    if not nodes:
        return None, None, "no-receiver"
    denied = False
    for node in nodes:
        try:
            fd = os.open(node, os.O_RDWR | os.O_NONBLOCK)
        except PermissionError:
            denied = True
            continue
        except OSError:
            continue
        for idx in range(1, 7):
            d = Dev(fd, idx)
            try:
                if d.ping():
                    return fd, d, None
            except HidppError:
                continue
        os.close(fd)
    return None, None, ("no-access" if denied else "not-connected")


def dpi_info(d, st):
    r = d.call(F_DPI, 2, b"\0")
    cur = (r[1] << 8) | r[2]
    if cur == 0:
        cur = (r[3] << 8) | r[4]
    st["dpi"] = cur or None
    vals, raw, off = [], [], 0
    while len(raw) < 64:
        chunk = d.call(F_DPI, 1, bytes([0, off]))[1:]
        words = [(chunk[i] << 8) | chunk[i + 1] for i in range(0, len(chunk) - 1, 2)]
        stop = False
        for w in words:
            if w == 0:
                stop = True
                break
            raw.append(w)
        if stop or not words:
            break
        off += len(words)
        if off > 30:
            break
    step = None
    i = 0
    while i < len(raw):
        w = raw[i]
        if w >> 13 == 0b111 and vals and i + 1 < len(raw):
            step = w & 0x1FFF
            lo, hi = vals[-1], raw[i + 1]
            vals.extend(range(lo + step, hi + 1, step))
            i += 2
            continue
        vals.append(w)
        i += 1
    if vals:
        st["dpi_min"], st["dpi_max"] = min(vals), max(vals)
        st["dpi_step"] = step or 0
        if not step:
            st["dpi_values"] = sorted(set(vals))


def battery_info(d, st):
    try:
        r = d.call(F_UNIFIED_BATTERY, 1)
        st["battery"] = r[0] if 0 < r[0] <= 100 else None
        st["battery_level"] = {8: "full", 4: "good", 2: "low", 1: "critical"}.get(r[1], "")
        st["charging"] = r[2] in (1, 2)
        st["battery_full"] = r[2] == 3
        st["external_power"] = r[3] != 0
    except HidppError:
        pass


def rate_info(d, st):
    try:
        mask = d.call(F_REPORT_RATE, 0)[0]
        st["rates_ms"] = [b + 1 for b in range(8) if mask & (1 << b)]
        st["rate_ms"] = d.call(F_REPORT_RATE, 1)[0]
    except HidppError:
        pass


def onboard_info(d, st):
    try:
        st["onboard"] = d.call(F_ONBOARD, 2)[0] == 1
    except HidppError:
        pass


def status(d):
    st = {"ok": True, "error": None, "present": True}
    try:
        st["name"] = d.name()
    except HidppError:
        st["name"] = "Logitech mouse"
    battery_info(d, st)
    try:
        dpi_info(d, st)
    except HidppError:
        pass
    rate_info(d, st)
    onboard_info(d, st)
    return st


def main():
    args = sys.argv[1:] or ["--read"]
    lock = open(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "rolo-pointer-g502.lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    fd, d, err = open_device()
    if err:
        print(json.dumps({"ok": False, "error": err, "present": False}))
        return
    try:
        msg = None
        try:
            if args[0] == "--set-dpi":
                v = int(args[1])
                if not 50 <= v <= 32000:
                    raise ValueError
                d.call(F_DPI, 3, bytes([0, v >> 8, v & 0xFF]))
            elif args[0] == "--set-rate":
                v = int(args[1])
                if v not in (1, 2, 4, 8):
                    raise ValueError
                d.call(F_REPORT_RATE, 2, bytes([v]))
            elif args[0] == "--onboard":
                d.call(F_ONBOARD, 1, bytes([1 if args[1] == "on" else 2]))
        except (HidppError, ValueError, IndexError) as e:
            msg = "set failed: %s" % e
        st = status(d)
        if msg and args[0] == "--set-rate" and st.get("onboard"):
            msg = "The onboard profile sets the polling rate. Turn Onboard profiles off to change it here."
        if msg:
            st["error"] = msg
        print(json.dumps(st))
    except HidppError as e:
        print(json.dumps({"ok": False, "error": str(e), "present": False}))
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
