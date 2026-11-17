#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Extract the J716s camera's sensor tuning file (setfile) from macOS's camera daemon.

    python3 -I extract-isp-setfile.py /usr/sbin/appleh16camerad OUTDIR

Writes OUTDIR/apple/isp_2224_01XX.dat (IMX958, magic 0x22240106, 0x6ff4 bytes rounded up to 64)
and prints its size and sha256. The setfile is Apple's: never commit it, never upload it. Install
it on the Linux root as /usr/lib/firmware/apple/isp_2224_01XX.dat (root:root 0644).

Same scan as asahi-installer's asahi_firmware/isp.py and omarchy-mac-installer's omarchy_isp.py:
a big-endian 8-word header on a 4 KiB boundary whose first word is the setfile magic. The magic
and size are the apple-isp driver's isp_setfiles[] entry (drivers/media/platform/apple/isp/isp-cam.c).
"""
import hashlib
import pathlib
import struct
import sys

MAGIC, NAME, SIZE = 0x22240106, "isp_2224_01XX.dat", 0x6FF4
ALIGN = 0x1000


def header_ok(h):
    return (h[0] == MAGIC and h[2] == h[3] == h[6] == 0 and h[4] and h[4] & 0xFF000000 == h[4]
            and h[5] and h[5] & 0xFFFF0000 == h[5] and h[7] == 0x03C00000)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = pathlib.Path(sys.argv[1]).read_bytes()
    size = (SIZE + 63) & ~63
    hits = {data[o:o + size] for o in range(0, len(data) - 31, ALIGN)
            if header_ok(struct.unpack_from(">8I", data, o)) and o + size <= len(data)}
    if len(hits) != 1:
        sys.exit(f"expected one IMX958 2224_01 setfile, found {len(hits)} distinct copies")
    blob = hits.pop()
    out = pathlib.Path(sys.argv[2]) / "apple" / NAME
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(blob)
    print(f"{out} {len(blob):#x} bytes sha256 {hashlib.sha256(blob).hexdigest()}")


if __name__ == "__main__":
    main()
