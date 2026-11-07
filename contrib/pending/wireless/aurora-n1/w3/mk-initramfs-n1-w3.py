#!/usr/bin/env python3
# W3 initramfs = prep/mk-initramfs-n1-b1f61a85.py with the stitched FTAB (mk-ftab-w3.py) in place of
# the restore bundle's ftab.bin: the selftest initramfs (base 1f61a850) + one more newc archive with
# lib/firmware/apple/centauri/j716s-ftab.bin, inside the same single gzip member.
#   python3 -I ~/Work/agents/n1-wifi/w3/mk-initramfs-n1-w3.py
# Why the initramfs: APPLE_CENTAURI=y, so the control function's boot worker calls
# request_firmware_direct() during PCI enumeration, long before switch_root; the firmware loader
# waits for the initramfs unpack and reads /lib/firmware from it.
# Output: w3/private/initramfs-selftest-n1-w3.cpio.gz (0600). Its sha256 goes to w3/private/SHA256SUMS
# only; stdout carries sizes.
import gzip, hashlib, os, pathlib, struct, zlib
H = pathlib.Path.home()
SRC = H/"Work/omarchy-m5/build/initramfs-selftest.cpio.gz"
PRIV = (H/"Work/agents/n1-wifi/w3/private").resolve()
FW = PRIV/"j716s-ftab-w3.bin"
OLD = H/"Work/studio-artifacts/j716s-fw/Firmware/t2026macG1/Release/ftab.bin"
OUT = PRIV/"initramfs-selftest-n1-w3.cpio.gz"
sha = lambda b: hashlib.sha256(b).hexdigest()

src, fw, old = SRC.read_bytes(), FW.read_bytes(), OLD.read_bytes()
assert sha(src) == "1f61a850fb49764126d7a79e9f8adce5508cd6109b302e1441989bb89cd7903b", "selftest initramfs changed"
# The FTAB must be mk-ftab-w3.py's output: the bundle file with only 0x10/0x14 set and the ticket appended.
assert fw[0x20:0x28] == b"rkosftab"
toff, tlen = struct.unpack_from("<II", fw, 0x10)
assert toff == len(old) and toff + tlen == len(fw), "not old ftab + ticket"
assert fw[:0x10] == old[:0x10] and fw[0x18:toff] == old[0x18:], "FTAB body differs from the bundle's"
assert fw[toff:toff + 1] == b"\x30" and b"IM4M" in fw[toff:toff + 16], "ticket is not an IM4M"
assert len(fw) <= 64 << 20
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

# Verify: one gzip member, and the last j716s-ftab.bin in the archive stream is exactly the W3 file.
raw = gzip.decompress(out)
assert raw[-len(arc):] == arc and raw[:len(base)] == base
z = zlib.decompressobj(16 + zlib.MAX_WBITS)
assert z.decompress(out) == raw and z.eof and not z.unused_data, "not exactly one gzip member"
i, last = 0, None
while i < len(raw):
    if raw[i:i + 6] != b"070701":
        i += 1
        continue
    f = [int(raw[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
    size, nlen = f[6], f[11]
    name = raw[i + 110:i + 110 + nlen - 1]
    o = i + 110 + nlen
    o += -o % 4
    if name == b"lib/firmware/apple/centauri/j716s-ftab.bin":
        last = raw[o:o + size]
    i = o + size
    i += -i % 4
assert last == fw, "the archive's j716s-ftab.bin is not the W3 FTAB"

tmp = OUT.with_suffix(".tmp")
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "wb") as fh:
    fh.write(out)
os.replace(tmp, OUT)
with open(PRIV/"SHA256SUMS", "a") as fh:
    fh.write(f"{sha(out)}  {OUT.name}\n")
print(f"wrote w3/private/{OUT.name}: {len(out)} bytes; j716s-ftab.bin {len(fw)} bytes "
      f"(ticket {tlen} bytes at 0x{toff:x}); sha256 in w3/private/SHA256SUMS")
