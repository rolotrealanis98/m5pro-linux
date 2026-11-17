#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a synthetic J716s-shaped NVRAM partition (12 x 64 KiB v3 banks) for offline tests. Every value is made up.

  synth-nvram.py OUT [SCENARIO]

  normal    bank 9 active (gen 200), older generations elsewhere, one erased bank; default = volume group 2
  pending   normal + a live alt-boot-volume
  tie       banks 9 and 10 share the highest generation (asahi-nvram takes 9, XNU 10)
  full      the active bank has no room for another boot-volume entry (asahi-nvram would rotate)
  zeros     a run of 0x00 after the last entry (re-serialising would need 0 -> 1)
  badcrc    the active bank has one entry with a wrong CRC (asahi-nvram rejects the bank, XNU skips the entry)
  twobv     two live boot-volume entries in the active bank
"""
import struct
import sys
import zlib

PART, HDR = 0x10000, 24
COMMON = bytes([0x7c, 0x43, 0x61, 0x10, 0xab, 0x2a, 0x4b, 0xbb, 0xa8, 0x80, 0xfe, 0x41, 0x99, 0x5c, 0x9f, 0x82])
SYSTEM = bytes([0x40, 0xa0, 0xdd, 0xd2, 0x77, 0xf8, 0x43, 0x92, 0xb4, 0xa3, 0x1e, 0x73, 0x04, 0x20, 0x65, 0x16])
TYPE = "EF57347C-0000-AA11-AA11-00306543ECAC"
VG = {1: ("11111111-1111-4111-8111-111111111111", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
      2: ("22222222-2222-4222-8222-222222222222", "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")}


def vol(i):
    return ("%s:%s:%s" % (TYPE, VG[i][0], VG[i][1])).encode()


def entry(key, val, guid=SYSTEM, state=0x7F, crc=None):
    h = struct.pack("<HBBIII", 0x55AA, state, 0, 0, len(key) + 1, len(val)) + guid
    return h + struct.pack("<I", zlib.crc32(val) if crc is None else crc) + key + b"\0" + val


def bank(gen, entries):
    b = b"3VVN" + struct.pack("<II", PART, gen) + bytes([0xFE, 0x5A, 1, 0]) + struct.pack("<II", 0x4000, 0xC000)
    b += b"".join(entries)
    assert len(b) <= PART
    return b + b"\xff" * (PART - len(b))


def base(default=2):
    e = [entry(b"auto-boot", b"true"), entry(b"boot-args", b"", COMMON)]
    e += [entry(b"synthetic-%02d" % i, bytes([0x41 + i]) * (20 + 7 * i), COMMON if i % 2 else SYSTEM) for i in range(30)]
    e += [entry(b"boot-volume", vol(1), state=0x7C), entry(b"boot-volume", vol(default))]
    e += [entry(b"SystemAudioVolume", b"\x80", COMMON, state=0x7C), entry(b"SystemAudioVolume", b"\x60", COMMON)]
    return e


def main():
    out, sc = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "normal")
    e = base()
    gens = {i: 189 + i for i in range(12)}
    gens[9], gens[10], gens[11] = 200, 0, 187
    if sc == "pending":
        e.append(entry(b"alt-boot-volume", vol(1)))
    if sc == "tie":
        gens[10] = 200
    if sc == "full":
        used = HDR + sum(map(len, e))
        pad = PART - used - 36 - 12 - 60
        e.append(entry(b"filler", b"F" * pad, COMMON, state=0x7C))
    if sc == "badcrc":
        e.insert(5, entry(b"broken", b"xyz", COMMON, crc=1))
    if sc == "twobv":
        e.append(entry(b"boot-volume", vol(1)))
    banks = []
    for i in range(12):
        if i == 10 and sc != "tie":
            banks.append(b"\xff" * PART)
        elif i == 9:
            b = bank(gens[i], e)
            if sc == "zeros":
                used = HDR + sum(map(len, e))
                b = b[:used] + b"\0" * 40 + b[used + 40:]
            banks.append(b)
        else:
            banks.append(bank(gens[i], base(default=1)[: 10 + i]))
    open(out, "wb").write(b"".join(banks))


if __name__ == "__main__":
    main()
