#!/usr/bin/env python3
"""Decode a DCP property dictionary as drm/apple saves it in debugfs.

    dcp-dict.py /sys/kernel/debug/dri/0/eDP-1/TimingElements [--timings]

The blob is the firmware's serialized object (u32 header 0xd3, then 32-bit
tags: bits 0-23 size or count, 24-28 type, 31 last) as parser.c reads it.
--timings prints one line per TimingElements entry: ID, size, refresh rate,
adaptive-sync range, IsPreferred/IsPromoted, Score and any refresh-rate keys
the driver does not use (DiscreteMediaRefreshRates and the like).
"""
import struct
import sys

DICT, ARRAY, INT, STRING, BLOB, BOOL = 1, 2, 4, 9, 10, 11


class Reader:
    def __init__(self, data):
        self.d, self.p = data, 0

    def tag(self):
        self.p = (self.p + 3) & ~3
        (t,) = struct.unpack_from("<I", self.d, self.p)
        self.p += 4
        return t & 0xFFFFFF, (t >> 24) & 0x1F

    def value(self):
        size, kind = self.tag()
        if kind == DICT:
            out = {}
            for _ in range(size):
                k = self.value()
                out[k] = self.value()
            return out
        if kind == ARRAY:
            return [self.value() for _ in range(size)]
        if kind == INT:
            (v,) = struct.unpack_from("<q", self.d, self.p)
            self.p += 8
            return v
        if kind in (STRING, BLOB):
            raw = self.d[self.p:self.p + size]
            self.p += size
            return raw.decode(errors="replace") if kind == STRING else raw.hex()
        if kind == BOOL:
            return bool(size)
        raise ValueError("unknown tag type %d at %#x" % (kind, self.p - 4))


def hz(v):
    return "%.3f" % (v / 65536.0) if isinstance(v, int) else str(v)


def timings(obj):
    for t in obj if isinstance(obj, list) else []:
        h, v = t.get("HorizontalAttributes", {}), t.get("VerticalAttributes", {})
        extra = {k: t[k] for k in t if ("Refresh" in k or "Rate" in k) and k not in
                 ("MinimumVariableRefreshRate", "MaximumVariableRefreshRate")}
        print("ID %s %sx%s total %sx%s %s Hz VRR %s-%s preferred=%s promoted=%s virtual=%s score=%s %s" % (
            t.get("ID"), h.get("Active"), v.get("Active"), h.get("Total"), v.get("Total"),
            hz(v.get("PreciseSyncRate")), hz(t.get("MinimumVariableRefreshRate", "-")),
            hz(t.get("MaximumVariableRefreshRate", "-")), t.get("IsPreferred"),
            t.get("IsPromoted"), t.get("IsVirtual"), t.get("Score"),
            extra if extra else ""))


def main():
    data = open(sys.argv[1], "rb").read()
    if struct.unpack_from("<I", data, 0)[0] != 0xD3:
        sys.exit("not a DCP serialized object (header %#x)" % struct.unpack_from("<I", data, 0)[0])
    r = Reader(data)
    r.p = 4
    obj = r.value()
    if "--timings" in sys.argv:
        timings(obj)
    else:
        import json
        print(json.dumps(obj, indent=1))


if __name__ == "__main__":
    main()
