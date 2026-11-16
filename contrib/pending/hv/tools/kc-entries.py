#!/usr/bin/env python3
"""kc-entries.py KC.macho [SUBSTR...] - list LC_FILESET_ENTRY names of an MH_FILESET kernelcache
(the Boot Kernel Collection iBoot loads), optionally filtered."""
import struct, sys
b = open(sys.argv[1], "rb").read()
magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<8I", b, 0)
assert magic == 0xfeedfacf, hex(magic)
print(f"filetype {ftype:#x} ({'MH_FILESET' if ftype == 0xc else '?'}), {ncmds} load commands")
off, names = 32, []
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", b, off)
    if cmd == 0x80000035:   # LC_FILESET_ENTRY
        vmaddr, fileoff, stroff = struct.unpack_from("<QQI", b, off + 8)
        names.append((b[off + stroff:b.index(b"\0", off + stroff)].decode(), vmaddr))
    off += size
print(f"{len(names)} fileset entries")
pats = sys.argv[2:]
for n, va in names:
    if not pats or any(p.lower() in n.lower() for p in pats):
        print(f"  {va:#x} {n}")
