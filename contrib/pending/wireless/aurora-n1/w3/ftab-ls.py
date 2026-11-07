#!/usr/bin/env python3
# List an rkosftab: header words and entries (tag, offset, size). No digests, no payload bytes.
import struct, sys
d = open(sys.argv[1], "rb").read()
print("size", len(d), "magic", d[0x20:0x28])
hdr = struct.unpack_from("<8I", d, 0)
print("hdr words 0x00-0x1f:", [hex(x) for x in hdr])
print("0x28-0x2f:", [hex(x) for x in struct.unpack_from("<2I", d, 0x28)])
n = struct.unpack_from("<I", d, 0x28)[0]
off = 0x30
for i in range(n):
    tag, o, s, pad = struct.unpack_from("<4sIII", d, off + 16*i)
    head = d[o:o+8]
    kind = "IMG4/DER" if head[:1] == b"\x30" else head[:4]
    print(f"{i:3d} {tag.decode('latin1')!r:8} off 0x{o:08x} size 0x{s:08x} pad 0x{pad:x} head {kind}")
