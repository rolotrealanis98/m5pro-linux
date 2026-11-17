#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Decode what centauri saved when the N1 Wi-Fi firmware halted (aci_debug, M1c kernel).

  n1-crashlog.py DIR [FTAB]

DIR holds the files `aci-probe.py save DIR` copied from debugfs: halt_info, halt_crashlog
(records of le32 N1 address, le32 length, bytes: the crash-log tables, then the Wi-Fi
segments the Wi-Fi table lists), halt_scratch (the 5 MB alpha scratch area).

FTAB is the N1 firmware file (default /usr/lib/firmware/apple/centauri/j716s-ftab.bin). Its
`_wfa` entry is the firmware's assert/log database: per CPU section (LMAC2G, LMAC5G, PHY2G,
PHY5G, RX, SCAN, TX, UMAC), code address -> file, function, line, format string. Every
16-bit-aligned le32 in a segment that is a known address is printed as
"ASSERT file.c-line function: format" with the section it belongs to; the most frequent and the
first hits come first. Apple firmware: the database is read in place, never copied.
"""
import collections
import os
import plistlib
import re
import struct
import sys

FTAB = "/usr/lib/firmware/apple/centauri/j716s-ftab.bin"


def ftab_entry(path, tag):
    d = open(path, "rb").read()
    if d[0x20:0x28] != b"rkosftab":
        sys.exit(f"{path}: not an ftab")
    for k in range(struct.unpack_from("<I", d, 0x28)[0]):
        t, off, size, _ = struct.unpack_from("<4sIII", d, 0x30 + 16 * k)
        if t == tag:
            return d[off:off + size]
    sys.exit(f"{path}: no {tag!r} entry")


def records(blob):
    pos = 0
    while pos + 8 <= len(blob):
        addr, length = struct.unpack_from("<II", blob, pos)
        yield addr, blob[pos + 8:pos + 8 + length]
        pos += 8 + length


def strings(data, minimum=6, limit=30):
    out = []
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % minimum, data):
        out.append((m.start(), m.group().decode()))
        if len(out) >= limit:
            break
    return out


def main(argv):
    if not argv:
        sys.exit(__doc__)
    folder = argv[0]
    ftab = argv[1] if len(argv) > 1 else FTAB
    db = plistlib.loads(ftab_entry(ftab, b"_wfa"))
    known = collections.defaultdict(list)  # address -> [(section, entry)]
    for section, entries in db.items():
        for key, entry in entries.items():
            if isinstance(entry, dict):
                known[int(key, 16)].append((section, entry))

    info = os.path.join(folder, "halt_info")
    if os.path.exists(info):
        print(open(info, errors="replace").read().rstrip())
    path = os.path.join(folder, "halt_crashlog")
    blob = open(path, "rb").read() if os.path.exists(path) else b""
    print(f"\nhalt_crashlog: {len(blob)} bytes")
    hits = collections.Counter()
    first = {}
    for n, (addr, data) in enumerate(records(blob)):
        tags = sorted({m.group().decode() for m in re.finditer(rb"(?:CLHE|EHLC|Cstr|rtsC|Cver|revC|WF[a-z]{2}|W[a-z]{3})", data)})
        print(f"\nrecord {n}: N1 {addr:#x}, {len(data)} bytes; section tags: {' '.join(tags[:20]) or '-'}")
        for off, text in strings(data, limit=12):
            print(f"  +{off:#07x} {text[:120]}")
        for off in range(0, len(data) - 3, 2):
            value = struct.unpack_from("<I", data, off)[0]
            if value in known:
                hits[value] += 1
                first.setdefault(value, (n, off))
    print(f"\nassert/log database hits: {len(hits)} distinct addresses")
    order = sorted(hits, key=lambda v: (first[v][0], first[v][1]))
    for value in order[:60]:
        for section, entry in known[value]:
            title = entry.get("title_str", "")
            print(f"  rec {first[value][0]} +{first[value][1]:#07x} x{hits[value]} {section:6s} {value:#x} "
                  f"{entry.get('file')}-{entry.get('line')} {entry.get('function')}: {title[:110]}")

    path = os.path.join(folder, "halt_scratch")
    if os.path.exists(path):
        scratch = open(path, "rb").read()
        used = len(scratch.rstrip(b"\0"))
        print(f"\nhalt_scratch: {len(scratch)} bytes, last non-zero byte at {used:#x}")
        for off, text in strings(scratch[:used], minimum=8, limit=20):
            print(f"  +{off:#08x} {text[:120]}")


if __name__ == "__main__":
    main(sys.argv[1:])
