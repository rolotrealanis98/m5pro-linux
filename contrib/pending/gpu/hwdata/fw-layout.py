#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""fw-layout.py: print the identity layout of the T6050 GPU firmware images that the
Aurora asahi driver's fwid.rs needs (text_size, data_size, entropy record offsets,
boot-filled ranges), from the rkosftab table and Mach-O load commands only.

Usage:
  python3 -I fw-layout.py armfw_g17x.im4p armfw1_g17x.im4p [--variant a010] [--digest]

The two files are the GFX (primary) and GFX1 (secondary) im4p from the restore bundle
(Firmware/agx/). Each holds three variant images: a010 = G17S (M5 Pro), a000 = G17C (M5 Max),
a020 = G17D (M5 Ultra) (checked by the "FW Build variant:" string inside each image).

Default: reads the rkosftab entry table, the Mach-O load commands and searches the TEXT
segment for the 8-byte GKTS/ECAP record headers. Nothing else is read or printed.

--digest additionally computes the fwid.rs digest (SHA-256 of primary TEXT || secondary TEXT
with the entropy bytes and boot-filled ranges zeroed). It reads the whole TEXT. It writes
nothing to disk. The live image in fw-text must give the same digest (the driver prints its
measured identity when it refuses a build, which is the other way to get it).
"""
import hashlib, struct, sys

TAGS = (b"GKTS", b"ECAP")
# The image header's two load fields iBoot fills (same TEXT offsets in every 26A428 build
# Aurora pinned; ASSUMED unchanged for 27.3).
HEADER_FIELDS = ((0x224, 4), (0x23c, 8))

def variants(blob):
    tab = blob.find(b"rkosftab")
    if tab < 0:
        raise SystemExit("no rkosftab table")
    payload = tab - 0x20                      # entry offsets are relative to the payload start
    n = struct.unpack_from("<I", blob, tab + 8)[0]
    out = {}
    for i in range(n):
        tag, off, size, _ = struct.unpack_from("<4sIII", blob, tab + 16 + 16 * i)
        out[tag.decode()] = (payload + off, size)
    return out

def macho(blob, base):
    magic, _cpu, _sub, _ft, ncmds = struct.unpack_from("<IiiII", blob, base)
    if magic != 0xfeedfacf:
        raise SystemExit(f"no Mach-O at {base:#x}")
    segs, sects, p = {}, {}, base + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", blob, p)
        if cmd == 0x19:
            name = blob[p + 8:p + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", blob, p + 24)
            segs[name] = (vmaddr, vmsize, fileoff, filesize)
            for s in range(struct.unpack_from("<I", blob, p + 64)[0]):
                q = p + 72 + 80 * s
                sname = blob[q:q + 16].rstrip(b"\0").decode()
                addr, ssize = struct.unpack_from("<QQ", blob, q + 32)
                sects[(name, sname)] = (addr - vmaddr, ssize)
        p += size
    return segs, sects

def role(path, variant):
    blob = open(path, "rb").read()
    base, _ = variants(blob)[variant]
    segs, sects = macho(blob, base)
    _, tsize, toff, _ = segs["__TEXT"]
    text_at = base + toff
    found = []
    for tag in TAGS:
        hits = []
        start = 0
        while True:
            i = blob.find(tag + struct.pack("<I", 8), text_at + start, text_at + tsize)
            if i < 0:
                break
            hits.append(i - text_at)
            start = i - text_at + 1
        found.append(hits)
    data = segs["__DATA"][1] + segs["__DATA_SHARED_RO"][1]
    return dict(blob=blob, text_at=text_at, text_size=tsize, data_size=data, sects=sects,
                gkts=found[0], ecap=found[1])

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    variant = "a010"
    if "--variant" in sys.argv:
        variant = sys.argv[sys.argv.index("--variant") + 1]
        args.remove(variant)
    if len(args) != 2:
        raise SystemExit(__doc__)
    roles = [role(args[0], variant), role(args[1], variant)]
    entropy, filled, base = [], [], 0
    for r in roles:
        if len(r["gkts"]) != 1 or len(r["ecap"]) != 1:
            raise SystemExit(f"expected one GKTS/ECAP pair per role, got {r['gkts']} {r['ecap']}")
        entropy.append([base + r["gkts"][0], base + r["ecap"][0]])
        tun = r["sects"][("__TEXT", "_rtk_tunables")]
        pb = r["sects"][("__TEXT", "_rtk_patchbay")]
        filled += [(base + o, l) for o, l in HEADER_FIELDS]
        filled += [(base + tun[0], tun[1]), (base + pb[0], pb[1])]
        base += r["text_size"]
    print(f"variant {variant}")
    print(f"text_size: {base:#x}  (primary {roles[0]['text_size']:#x} + secondary {roles[1]['text_size']:#x})")
    print(f"data_size: {roles[0]['data_size'] + roles[1]['data_size']:#x}")
    print("entropy: &[" + ", ".join(f"[{a:#x}, {b:#x}]" for a, b in entropy) + "]")
    print("boot_filled: &[" + ", ".join(f"({o:#x}, {l:#x})" for o, l in filled) + "]")
    if "--digest" in sys.argv:
        text = bytearray()
        for r in roles:
            text += r["blob"][r["text_at"]:r["text_at"] + r["text_size"]]
        for a, b in entropy:
            for off in (a, b):
                text[off + 8:off + 16] = bytes(8)
        for off, ln in filled:
            text[off:off + ln] = bytes(ln)
        d = hashlib.sha256(bytes(text)).digest()
        print("text_sha256: [" + ", ".join(f"{x:#04x}" for x in d) + "]")

if __name__ == "__main__":
    main()
