#!/usr/bin/env python3
"""Read-only look at what iBoot left for the T6050 GPU, from the Linux root.

NOT RUN YET. Needs the owner's go-ahead and root on the J716s. It reads DRAM
only: the GFX/GFX1 firmware TEXT that iBoot pre-loaded (outside Linux RAM) and
the SAPT GPU-permission table. It never touches GPU MMIO (0x23_xxxx_xxxx): the
GFX power domain is off at handover, and an MMIO read there with the domain
off can stop the bus.

  sudo ./gfx-fw-read.py dump OUTDIR     # on the J716s
  ./gfx-fw-read.py id OUTDIR/gfx-text.bin OUTDIR/gfx1-text.bin   # anywhere
  ./gfx-fw-read.py sapt OUTDIR/sapt.bin                          # anywhere

Addresses come from the 2026-11-04 runtime ADT (segment-ranges of
/arm-io/gfx-asc and /arm-io/gfx1-asc, /arm-io/sapt table-address). They can
move with another stub or memory size: re-derive them from the ADT first.

Identity follows aurora-silicon/linux drivers/gpu/drm/asahi/fwid.rs: SHA-256
of TEXT with the 8 entropy bytes after the "GKTS" and "ECAP" records (tag,
le32 length 8, 8 bytes) zeroed, so it can be compared with the builds that
driver accepts (T6040 25G83, text_size 0x60000).
"""

import hashlib
import mmap
import os
import struct
import sys

PAGE = 0x4000
REGIONS = {
    "gfx-text.bin": (0x10000FF0000, 0x50000),   # GFX  __TEXT
    "gfx1-text.bin": (0x10001040000, 0x54000),  # GFX1 __TEXT
    "sapt.bin": (0x10BD12E4000, 3145728 // 4),  # 2 bits per 16K page
}
LINUX_RAM = (0x10003B6C000, 0x10BC8A00000)  # dmesg 2026-11-04; must not overlap


def read_phys(phys, size):
    """Copy [phys, phys+size) with aligned 8-byte loads through /dev/mem.

    /dev/mem maps non-RAM as Device memory on arm64; Apple cores fault on
    unaligned Device accesses, so read whole aligned words, one at a time."""
    if phys % PAGE or size % 8:
        raise ValueError("unaligned region")
    if not (phys + size <= LINUX_RAM[0] or phys >= LINUX_RAM[1]):
        raise ValueError("region overlaps Linux RAM; refusing")
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    try:
        m = mmap.mmap(fd, (size + PAGE - 1) // PAGE * PAGE, mmap.MAP_SHARED,
                      mmap.PROT_READ, offset=phys)
        try:
            words = memoryview(m).cast("Q")
            out = bytearray(size)
            for i in range(size // 8):
                struct.pack_into("<Q", out, i * 8, words[i])
            words.release()
            return bytes(out)
        finally:
            m.close()
    finally:
        os.close(fd)


def fwid(text):
    img = bytearray(text)
    offs = []
    for tag in (b"GKTS", b"ECAP"):
        at = img.find(tag + struct.pack("<I", 8))
        if at < 0:
            return None, offs
        offs.append(at)
        img[at + 8:at + 16] = bytes(8)
    return hashlib.sha256(img).hexdigest(), offs


def main(argv):
    if len(argv) >= 2 and argv[0] == "dump":
        out = argv[1]
        os.makedirs(out, exist_ok=True)
        for name, (phys, size) in REGIONS.items():
            data = read_phys(phys, size)
            with open(os.path.join(out, name), "wb") as f:
                f.write(data)
            print(f"{name}: {size:#x} bytes from {phys:#x}")
        return 0
    if len(argv) >= 2 and argv[0] == "id":
        for path in argv[1:]:
            text = open(path, "rb").read()
            digest, offs = fwid(text)
            macho = text[:4] == b"\xcf\xfa\xed\xfe"
            print(f"{os.path.basename(path)}: size {len(text):#x} mach-o={macho} "
                  f"entropy@{[hex(o) for o in offs]} id={digest or 'no GKTS/ECAP records'}")
        return 0
    if len(argv) == 2 and argv[0] == "sapt":
        data = open(argv[1], "rb").read()
        denied = sum(bin(b).count("1") for b in data)
        zero = data.count(0)
        print(f"SAPT: {len(data)} bytes, {zero} all-permit bytes, {denied} deny bits set "
              f"({'fully permissive' if denied == 0 else 'GPU access restricted'})")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
