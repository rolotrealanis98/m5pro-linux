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
  v3-nvram.py plan-default DUMP    what `asahi-bless --set-boot X` (no --next) would program: the
                                   bank, erase (must be none), pages, the window in which no
                                   boot-volume is live, headroom; exit 0 only if every safety rule holds
  v3-nvram.py simulate-default BEFORE OUT
                                   write OUT = BEFORE after that update with a synthetic volume value
                                   (flash AND semantics), to exercise verify-default on real data
  v3-nvram.py verify-default BEFORE AFTER
                                   exit 0 only if AFTER is exactly BEFORE plus asahi-nvram's
                                   boot-volume update: same bank and generation, other banks
                                   byte-identical, bit-clear only, the model's bytes, one live entry

It models apple-nvram's v3.rs (parse, insert, serialize, bank rotation) from the
asahi-nvram repository (3df52c9), and reads banks the way XNU's IONVRAMV3Handler does
(tolerant parse, highest generation by header only) to check that both agree. It never
writes the flash and never prints a variable value.
"""
import re
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
        vals.append(dict(state=h[2], attrs=struct.unpack_from("<I", h, 4)[0], guid=bytes(h[16:32]), key=key, val=val, off=off))
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
    out[15] = 0                           # StoreHeader::serialize writes the reserved byte as 0
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
    if used(new) > p["end"]:
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


# ---- default boot volume (system:boot-volume) -------------------------------------------------

BV = b"boot-volume"
UUID = rb"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
VOLUME = re.compile(rb"^" + UUID + rb":" + UUID + rb":" + UUID + rb"$")
SYNTH = b":00000000-0000-4000-8000-000000000001:00000000-0000-4000-8000-000000000002"


def xnu_active(d):
    """IONVRAMV3Handler::findCurrentBank: header signature + version only, generation >=, so the last bank wins a tie."""
    best, idx, gens = -1, None, []
    for i in range(len(d) // PART):
        b = d[i * PART:(i + 1) * PART]
        if b[:4] == b"3VVN" and b[14] == 1:
            g = struct.unpack_from("<I", b, 8)[0]
            gens.append(g)
            if g >= best:
                best, idx = g, i
    return idx, best, gens.count(best)


def xnu_vars(b):
    """IONVRAMV3Handler::unserializeVariables: skip a bad header by 36 bytes, skip CRC mismatches, only 0x7F is live,
    a later duplicate replaces an earlier one."""
    off, out = HDR, {}
    while off + VH < PART:
        h = b[off:off + VH]
        if all(x in (0, 0xFF) for x in h):
            break
        ns, ds = struct.unpack_from("<II", h, 8)
        ln = VH + ns + ds
        if struct.unpack_from("<H", h, 0)[0] != 0x55AA or ln > PART - off:
            off += VH
            continue
        val = bytes(b[off + VH + ns:off + ln])
        if h[2] == ADDED and zlib.crc32(val) == struct.unpack_from("<I", h, 32)[0]:
            out[(typ(dict(guid=bytes(h[16:32]))), bytes(b[off + VH:off + VH + ns - 1]))] = val
        off += ln
    return out


def live_bv(p):
    return [v for v in p["vals"] if v["key"] == BV and v["guid"] == SYSTEM and v["state"] == ADDED]


def live_size(p, guid):
    return sum(VH + len(v["key"]) + 1 + len(v["val"]) for v in p["vals"] if v["state"] == ADDED and v["guid"] == guid)


def default_update(d, value):
    """Model asahi-bless set_boot_volume(next=false) on dump d. Returns (checks, info, new_partition_or_None)."""
    checks, info = [], []
    banks, a = parse(d)
    p = banks[a]
    xa, xg, ties = xnu_active(d)
    checks.append(("asahi-nvram and XNU pick the same active bank (%d gen %d)" % (a, p["gen"]), xa == a))
    checks.append(("the highest generation is unique (no tie for iBoot to break differently)", ties == 1))
    bank = d[a * PART:(a + 1) * PART]
    checks.append(("the active bank re-serialises byte-identically (the rewrite changes nothing else)", ser(p) == bank))
    checks.append(("XNU's tolerant reading and asahi-nvram see the same live variables", xnu_vars(bank) == active_vars(p)))
    lv = live_bv(p)
    checks.append(("exactly one live boot-volume entry", len(lv) == 1))
    if len(lv) != 1:
        return checks, info, None
    old = lv[0]["val"]
    checks.append(("the current boot-volume is a <type>:<partition>:<volume group> UUID triple", bool(VOLUME.match(old))))
    info.append("current boot-volume: %d bytes, %s UUIDs (asahi-bless writes upper case)" %
                (len(old), "upper-case" if old == old.upper() else "lower/mixed-case"))
    if value is None:
        value = old.split(b":")[0].upper() + SYNTH
    new = parse_bank(ser(p))
    insert(new, BV, value)
    sysz, comz = struct.unpack_from("<II", p["hdr"], 16)
    checks.append(("system variables fit the header's system section (%d of %d bytes)" % (live_size(new, SYSTEM), sysz),
                   live_size(new, SYSTEM) <= sysz))
    checks.append(("common variables fit the header's common section", live_size(p, COMMON) <= comz))
    fits = used(new) <= p["end"]
    checks.append(("the update fits in the active bank: no bank rotation, so no erase (%d of %d bytes after)" %
                   (used(new), p["end"]), fits))
    if not fits:
        info.append("asahi-nvram would erase bank %d and write a compacted copy with generation %d there, header first: "
                    "refused; iBoot and macOS rotate banks themselves when theirs fill up (they write at every boot), so boot "
                    "once more and probe again" % ((a + 1) % len(banks), p["gen"] + 1))
        return checks, info, None
    return checks, info, (banks, a, p, new, value)


def cmd_plan_default(path):
    d = load(path)
    checks, info, res = default_update(d, None)
    if res:
        banks, a, p, new, value = res
        off, out, bank = a * PART, ser(new), d[a * PART:(a + 1) * PART]
        pg = pages(bank, out)
        esz = VH + len(BV) + 1 + len(value)
        state, app = live_bv(p)[0]["off"] + 2, used(p)
        changed = [i for i in range(PART) if bank[i] != out[i]]
        checks.append(("bit-clear only: every byte change turns ones into zeros (the driver's rule)", clears_only(bank, out)))
        checks.append(("the change is the old entry's state byte (0x7f -> 0x7c) plus one entry appended at +%#x" % app,
                       out[state] == 0x7C and all(i == state or app <= i < app + esz for i in changed)))
        torn = range(pg[0], pg[-1] + PAGE, PAGE)
        info.append("write: one 64 KiB program of bank %d at partition +%#x (flash %#x), no erase; the other %d banks are not "
                    "addressed" % (a, off, 0x700000 + off, len(banks) - 1))
        info.append("pages whose bytes change: %d at partition offsets %s" % (len(pg), " ".join("%#x" % (off + i) for i in pg)))
        info.append("torn-write window: pages %#x..%#x (%d pages, roughly %d-%d ms at 0.5-2.5 ms per page program): "
                    "the old entry is already dead and the new one not complete" %
                    (off + torn[0], off + torn[-1], len(torn), len(torn) // 2, len(torn) * 5 // 2))
        info.append("headroom: %d bytes free after this update, about %d more boot-volume changes before a rotation" %
                    (p["end"] - used(new), (p["end"] - used(new)) // esz))
    for c, ok in checks:
        print("%s  %s" % ("PASS" if ok else "FAIL", c))
    for i in info:
        print("      %s" % i)
    ok = res is not None and all(ok for _, ok in checks)
    print("PLAN OK: in place, bit-clear only, no erase" if ok else "PLAN REFUSED")
    return 0 if ok else 3


def cmd_simulate_default(pb, po):
    d = load(pb)
    checks, info, res = default_update(d, None)
    if not res or not all(ok for _, ok in checks):
        sys.exit("plan-default refuses this dump; nothing simulated")
    banks, a, p, new, value = res
    old = d[a * PART:(a + 1) * PART]
    prog = bytes(o & n for o, n in zip(old, ser(new)))   # NOR program: bits can only be cleared
    out = d[:a * PART] + prog + d[(a + 1) * PART:]
    with open(po, "wb") as f:
        f.write(out)
    print("wrote %s: bank %d with a synthetic boot-volume" % (po, a))


def cmd_verify_default(pa, pb):
    da, db = load(pa), load(pb)
    checks = []
    if len(da) != len(db):
        sys.exit("dump sizes differ")
    ba, aa = parse(da)
    bb, ab = parse(db)
    xb = xnu_active(db)
    checks.append(("same active bank before and after (%d -> %d): no rotation" % (aa, ab), aa == ab))
    checks.append(("same generation (%d -> %d)" % (ba[aa]["gen"], bb[ab]["gen"]), ba[aa]["gen"] == bb[ab]["gen"]))
    checks.append(("after: asahi-nvram and XNU pick the same bank, generation unique", xb[0] == ab and xb[2] == 1))
    other = [i for i in range(len(da) // PART) if i != aa and da[i * PART:(i + 1) * PART] != db[i * PART:(i + 1) * PART]]
    checks.append(("every other bank byte-identical (%d banks)" % (len(da) // PART - 1), not other))
    o, n = da[aa * PART:(aa + 1) * PART], db[aa * PART:(aa + 1) * PART]
    checks.append(("active bank: bit-clear only", clears_only(o, n)))
    va, vb = active_vars(ba[aa]), active_vars(bb[ab])
    diff = sorted(k for k in set(va) | set(vb) if va.get(k) != vb.get(k))
    checks.append(("the only live variable that changed is system:boot-volume",
                   diff == [("system", BV)] and ("system", BV) in va and ("system", BV) in vb))
    checks.append(("XNU's tolerant reading of the new bank agrees with asahi-nvram", xnu_vars(n) == vb))
    lv = live_bv(bb[ab])
    checks.append(("exactly one live boot-volume entry after", len(lv) == 1))
    if len(lv) == 1 and ("system", BV) in va:
        new_val, old_val = lv[0]["val"], va[("system", BV)]
        checks.append(("new value is a UUID triple, same length and partition-type prefix as the old one",
                       bool(VOLUME.match(new_val)) and len(new_val) == len(old_val) and
                       new_val.split(b":")[0].upper() == old_val.split(b":")[0].upper()))
        chk, _, res = default_update(da, new_val)
        checks.append(("the new bank is byte for byte asahi-nvram's model of this update", bool(res) and ser(res[3]) == n))
    for c, ok in checks:
        print("%s  %s" % ("PASS" if ok else "FAIL", c))
    print("pages changed: %d" % len(pages(o, n)))
    ok = all(ok for _, ok in checks)
    print("VERIFY OK" if ok else "VERIFY FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "plan-default":
        sys.exit(cmd_plan_default(a[1]))
    if len(a) == 3 and a[0] == "simulate-default":
        sys.exit(cmd_simulate_default(a[1], a[2]))
    if len(a) == 3 and a[0] == "verify-default":
        sys.exit(cmd_verify_default(a[1], a[2]))
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
