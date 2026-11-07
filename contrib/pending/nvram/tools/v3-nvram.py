#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only checks on a dump of the Apple NVRAM v3 partition ("3VVN" banks of 64 KiB).

  v3-nvram.py show DUMP            active bank, variable names and sizes (never values)
  v3-nvram.py plan DUMP VOLUME     what asahi-nvram/asahi-bless would program to set the system
                                   variable alt-boot-volume to VOLUME (a boot-volume style string):
                                   in place (bit-clear only, 256-byte pages touched) or not
  v3-nvram.py compare BEFORE AFTER the change between two dumps: same bank, variables added,
                                   removed or changed (by name), bit-clear only, pages touched
  v3-nvram.py names DUMP           active bank variable names, one per line (for comparing with
                                   the names `nvram -p` shows in macOS)

It models apple-nvram's v3.rs (parse, insert, serialize, bank rotation) from the
asahi-nvram repository; it does not replace the tool and never writes anything.
"""
import struct
import sys
import zlib

PART = 0x10000
HDR = 24
VH = 36
ADDED, DELETED, TRANS = 0x7F, 0xFD, 0xFE
COMMON = bytes([0x7c, 0x43, 0x61, 0x10, 0xab, 0x2a, 0x4b, 0xbb, 0xa8, 0x80, 0xfe, 0x41, 0x99, 0x5c, 0x9f, 0x82])
SYSTEM = bytes([0x40, 0xa0, 0xdd, 0xd2, 0x77, 0xf8, 0x43, 0x92, 0xb4, 0xa3, 0x1e, 0x73, 0x04, 0x20, 0x65, 0x16])
PAGE = 256


def parse_bank(b):
    """Return a bank dict, 'empty', or None when the bank is neither valid nor erased."""
    if b[:4] != b"3VVN" or b[14] != 1:
        return "empty" if set(b) == {0xFF} else None
    size, gen = struct.unpack_from("<II", b, 4)
    vals, off, end = [], HDR, size
    while off + VH < size:
        h = b[off:off + VH]
        if all(x in (0, 0xFF) for x in h):
            off += VH
            while off < size and b[off] == 0xFF:
                off += 1
            end = off
            break
        if struct.unpack_from("<H", h, 0)[0] != 0x55AA:
            end = off
            break
        ns, ds = struct.unpack_from("<II", h, 8)
        crc = struct.unpack_from("<I", h, 32)[0]
        kb, vb = off + VH, off + VH + ns
        if vb + ds > size:
            end = off
            break
        key, val = bytes(b[kb:vb - 1]), bytes(b[vb:vb + ds])
        if zlib.crc32(val) != crc:
            return None
        vals.append(dict(state=h[2], attrs=struct.unpack_from("<I", h, 4)[0], guid=bytes(h[16:32]), key=key, val=val))
        off = vb + ds
        end = off
    return dict(size=size, gen=gen, hdr=bytes(b[:HDR]), vals=vals, end=end)


def parse(dump):
    n = len(dump) // PART
    banks = [parse_bank(dump[i * PART:(i + 1) * PART]) for i in range(n)]
    valid = [i for i, p in enumerate(banks) if isinstance(p, dict)]
    if not valid:
        sys.exit("no valid 3VVN bank in the dump")
    active, best = 0, 0
    for i in valid:                       # same rule as apple-nvram: first bank with the highest generation
        if banks[i]["gen"] > best:
            active, best = i, banks[i]["gen"]
    return banks, active


def ser(p):
    out = bytearray(p["hdr"])
    for v in p["vals"]:
        out += struct.pack("<HBBIII", 0x55AA, v["state"], 0, v["attrs"], len(v["key"]) + 1, len(v["val"]))
        out += v["guid"] + struct.pack("<I", zlib.crc32(v["val"])) + v["key"] + b"\0" + v["val"]
    return bytes(out + b"\xff" * (p["size"] - len(out)))


def used(p):
    return HDR + sum(VH + len(v["key"]) + 1 + len(v["val"]) for v in p["vals"])


def insert(p, key, val, guid=SYSTEM):
    for v in p["vals"]:
        if v["key"] == key and v["guid"] == guid and v["state"] == ADDED:
            v["state"] = v["state"] & DELETED & TRANS
    p["vals"].append(dict(state=ADDED, attrs=0, guid=guid, key=key, val=val))


def typ(v):
    return "system" if v["guid"] == SYSTEM else "common" if v["guid"] == COMMON else "other"


def active_vars(p):
    return {(typ(v), v["key"]): v["val"] for v in p["vals"] if v["state"] == ADDED}


def clears_only(old, new):
    return all((o & n) == n for o, n in zip(old, new))


def pages(old, new):
    return [i for i in range(0, len(old), PAGE) if old[i:i + PAGE] != new[i:i + PAGE]]


def load(path):
    d = open(path, "rb").read()
    if len(d) % PART:
        sys.exit("%s: size %d is not a multiple of 64 KiB" % (path, len(d)))
    return d


def cmd_show(path):
    d = load(path)
    banks, a = parse(d)
    print("banks %d: %s" % (len(banks), " ".join("%d:%s" % (i, ("gen%d" % p["gen"]) if isinstance(p, dict) else p or "BAD") for i, p in enumerate(banks))))
    p = banks[a]
    print("active bank %d gen %d, %d entries, %d of %d bytes used, flash offset +%#x" % (a, p["gen"], len(p["vals"]), used(p), p["size"], a * PART))
    for v in p["vals"]:
        print("  %02x %-6s %-40s %d" % (v["state"], typ(v), v["key"].decode("utf-8", "replace"), len(v["val"])))


def cmd_names(path):
    banks, a = parse(load(path))
    for k in sorted({v["key"].decode("utf-8", "replace") for v in banks[a]["vals"] if v["state"] == ADDED}):
        print(k)


def cmd_plan(path, volume):
    d = load(path)
    banks, a = parse(d)
    p = banks[a]
    new = parse_bank(ser(p))
    insert(new, b"alt-boot-volume", volume.encode())
    if used(new) > new["end"]:
        n = (a + 1) % len(banks)
        print("alt-boot-volume update does not fit in bank %d: asahi-nvram would copy the live variables to bank %d" % (a, n))
        print("  (erase of bank %d first, then a 64 KiB program); stop and review before arming" % n)
        return
    off, out, how = a * PART, ser(new), "in place in bank %d" % a
    old = d[off:off + PART]
    pg = pages(old, out)
    print("alt-boot-volume update %s" % how)
    print("  bit-clear only (no erase needed): %s" % clears_only(old, out))
    print("  256-byte pages programmed: %d at flash offsets %s" % (len(pg), " ".join("%#x" % (off + i) for i in pg)))


def cmd_compare(pa, pb):
    da, db = load(pa), load(pb)
    if len(da) != len(db):
        sys.exit("dump sizes differ")
    ba, aa = parse(da)
    bb, ab = parse(db)
    print("active bank %d gen %d -> bank %d gen %d" % (aa, ba[aa]["gen"], ab, bb[ab]["gen"]))
    va, vb = active_vars(ba[aa]), active_vars(bb[ab])
    for k in sorted(set(va) | set(vb)):
        if k not in va:
            print("  added   %s:%s" % (k[0], k[1].decode()))
        elif k not in vb:
            print("  removed %s:%s" % (k[0], k[1].decode()))
        elif va[k] != vb[k]:
            print("  changed %s:%s" % (k[0], k[1].decode()))
    changed = [i for i in range(len(da) // PART) if da[i * PART:(i + 1) * PART] != db[i * PART:(i + 1) * PART]]
    print("banks whose bytes changed: %s" % (changed or "none"))
    if aa == ab:
        o, n = da[aa * PART:(aa + 1) * PART], db[aa * PART:(aa + 1) * PART]
        print("same bank: bit-clear only %s, %d pages differ" % (clears_only(o, n), len(pages(o, n))))


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "show":
        cmd_show(a[1])
    elif len(a) == 2 and a[0] == "names":
        cmd_names(a[1])
    elif len(a) == 3 and a[0] == "plan":
        cmd_plan(a[1], a[2])
    elif len(a) == 3 and a[0] == "compare":
        cmd_compare(a[1], a[2])
    else:
        sys.exit(__doc__)
