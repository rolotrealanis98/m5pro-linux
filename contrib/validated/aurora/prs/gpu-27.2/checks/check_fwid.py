#!/usr/bin/env python3
"""Recompute every T6050 fwid Build pinned in hw/t6050.rs from the firmware files, with fwid.rs's
algorithm (digest_at with boot-filled ranges): each GKTS/ECAP record must be at its offset (tag,
length 8, 8 entropy bytes inside TEXT); its 8 entropy bytes and every boot-filled range are zeroed;
SHA-256 of the result. TEXT = primary __TEXT || secondary __TEXT of the variant's Mach-O.
Reads the private firmware files locally; prints only digests and offsets.
usage: check_fwid.py t6050.rs"""
import hashlib, os, re, struct, sys

# FW_ROOT: macos-27.0-26A428/ and macos-27.2-26B123/ (armfw{,1}_g17x.im4p from the public Mac17,8
# IPSWs) and j716s-fw/Firmware/agx/ (the 27.3 beta 1 images).
A = os.environ.get("FW_ROOT", os.path.expanduser("~/Work/studio-artifacts")) + "/"
FILES = {"26A428": A + "macos-27.0-26A428/", "26B123": A + "macos-27.2-26B123/",
         "26C5035r": A + "j716s-fw/Firmware/agx/"}
VARIANTS = {"G17S": "a010", "G17C": "a000", "": "a020"}  # the Ultra's image name has no tag

def text_of(blob, variant):
    tab = blob.find(b"rkosftab")
    n = struct.unpack_from("<I", blob, tab + 8)[0]
    for i in range(n):
        tag, off, size, _ = struct.unpack_from("<4sIII", blob, tab + 16 + 16 * i)
        if tag.decode() == variant:
            base = tab - 0x20 + off
    assert struct.unpack_from("<I", blob, base)[0] == 0xfeedfacf
    ncmds = struct.unpack_from("<I", blob, base + 16)[0]
    p, segs = base + 32, {}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", blob, p)
        if cmd == 0x19:
            name = blob[p + 8:p + 24].rstrip(b"\0").decode()
            segs[name] = struct.unpack_from("<QQQQ", blob, p + 24)
        p += size
    _, tsize, toff, _ = segs["__TEXT"]
    data = segs["__DATA"][1] + segs["__DATA_SHARED_RO"][1]
    return blob[base + toff:base + toff + tsize], data

def num(s):
    return int(s, 0)

src = open(sys.argv[1]).read()
builds = re.findall(r"FirmwareBuild \{(?:\s*//[^\n]*)*\s*name: \"([^\"]+)\",\s*text_size: (\w+),\s*data_size: (\w+),"
                    r"\s*entropy: &\[(.*?)\],\s*(?://[^\n]*\n\s*)*boot_filled: &\[(.*?)\],"
                    r"\s*text_sha256: \[(.*?)\]", src, re.S)
assert builds, "no builds parsed"
ok = True
for name, tsz, dsz, ent, filled, sha in builds:
    build = name.split()[0]
    tag = next(t for t in ("G17S", "G17C") if t in name) if ("G17S" in name or "G17C" in name) else ""
    var = VARIANTS[tag]
    t0, d0 = text_of(open(FILES[build] + "armfw_g17x.im4p", "rb").read(), var)
    t1, d1 = text_of(open(FILES[build] + "armfw1_g17x.im4p", "rb").read(), var)
    text = bytearray(t0 + t1)
    entropy = [tuple(num(x) for x in pair.split(",")) for pair in re.findall(r"\[([^\]]+)\]", ent)]
    fills = [tuple(num(x) for x in p.split(",")) for p in re.findall(r"\(([^)]+)\)", re.sub(r"//[^\n]*", "", filled))]
    pinned = bytes(num(x) for x in sha.replace("\n", " ").split(",") if x.strip())
    sizes = (len(text) == num(tsz), d0 + d1 == num(dsz))
    recs = all(text[o:o + 8] == tagb + struct.pack("<I", 8) and o + 16 <= len(text)
               for pair in entropy for o, tagb in zip(pair, (b"GKTS", b"ECAP")))
    for pair in entropy:
        for o in pair:
            text[o + 8:o + 16] = bytes(8)
    for o, l in fills:
        assert o + l <= len(text)
        text[o:o + l] = bytes(l)
    digest = hashlib.sha256(bytes(text)).digest()
    good = sizes == (True, True) and recs and digest == pinned
    ok &= good
    print(f"{'MATCH' if good else 'FAIL '} {name}: {build}/{var} TEXT {len(text):#x} DATA {d0 + d1:#x} "
          f"records {'ok' if recs else 'MISSING'} sha256 {digest.hex()}")
sys.exit(0 if ok else 1)
