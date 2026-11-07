#!/usr/bin/env python3
# initramfs-selftest-n1.cpio.gz = the selftest initramfs + lib/firmware/apple/centauri/j716s-ftab.bin,
# for kernels with APPLE_CENTAURI=y (the control function asks for its firmware before switch_root).
#   python3 -I ~/Work/agents/n1-wifi/mk-initramfs-n1.py
# Output stays in ~/Work/agents/n1-wifi/payloads/ (private: carries the per-unit FTAB).
# One gzip member (m1n1's payload scan and the kernel both take it); the firmware is a second newc
# archive after the first one's TRAILER!!!, inside the same gzip stream, which the kernel's
# initramfs unpacker accepts.
import gzip, hashlib, pathlib
H = pathlib.Path.home()
SRC = H/"Work/omarchy-m5/build/initramfs-selftest.cpio.gz"
FW = H/"Work/studio-artifacts/j716s-fw/Firmware/t2026macG1/Release/ftab.bin"
OUT = H/"Work/agents/n1-wifi/payloads/initramfs-selftest-n1.cpio.gz"
sha = lambda b: hashlib.sha256(b).hexdigest()
src, fw = SRC.read_bytes(), FW.read_bytes()
assert sha(src) == "ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a", "initramfs changed"
assert sha(fw) == "8bf9ff3f8f5ad6866cd40b21f6ce59c44163a460a4e9e2875c4601484d0ba9c8", "ftab changed"
assert fw[0x20:0x28] == b"rkosftab"
base = gzip.decompress(src)
assert b"TRAILER!!!" in base[-512:], "not a newc archive"

ino = [0x7f000000]
def entry(name, mode, data=b""):
    ino[0] += 1
    n = name.encode() + b"\0"
    hdr = b"070701" + b"".join(b"%08x" % v for v in (
        ino[0], mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0))
    out = hdr + n
    out += b"\0" * (-len(out) % 4)
    out += data + b"\0" * (-len(data) % 4)
    return out

arc = b""
for d in ("lib", "lib/firmware", "lib/firmware/apple", "lib/firmware/apple/centauri"):
    arc += entry(d, 0o040755)
arc += entry("lib/firmware/apple/centauri/j716s-ftab.bin", 0o100644, fw)
arc += entry("TRAILER!!!", 0)
arc += b"\0" * (-len(arc) % 512)
out = gzip.compress(base + arc, compresslevel=9, mtime=0)
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(out)
assert gzip.decompress(out)[-len(arc):] == arc
print(f"{sha(out)}  {OUT.name}  ({len(out)} bytes)")
