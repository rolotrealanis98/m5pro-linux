#!/usr/bin/env python3
# Read files off the Studio's Omarchy root (btrfs "asahi-root" on disk0s5, subvolumes @ and @home)
# from macOS, without mounting: pure-Python btrfs via dissect.btrfs. Needs sudo for the raw device
# and a Python <= 3.14 venv: python3.12 -m venv ~/Work/btrfs-venv && pip install dissect.btrfs backports.zstd
#   sudo ~/Work/btrfs-venv/bin/python -I host/macos/omarchy-volume.py ls /@home/rolo/Work
#   sudo ~/Work/btrfs-venv/bin/python -I host/macos/omarchy-volume.py get /@home/rolo/.ssh/mbp ~/.ssh/mbp
# Used 2026-11-04 to recover ~/.ssh/mbp and the October kernel/DTB/initramfs/m1n1 builds into
# ~/Work/studio-artifacts without rebooting the Studio into Omarchy.
import sys, os
from dissect.btrfs import Btrfs
fs = Btrfs(open("/dev/disk0s5", "rb"))
cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "ls":
    for path in args:
        try:
            e = fs.get(path); print(f"\n{path}/")
            for name in sorted(e.listdir()):
                if name in (".", ".."): continue
                try: c = e.get(name); print(f"   {'d' if c.is_dir() else ('l' if c.is_symlink() else '-')} {c.size:>12} {name}" + (f" -> {c.readlink()}" if c.is_symlink() else ""))
                except Exception as ex: print(f"   ? {name} ({type(ex).__name__})")
        except Exception as ex: print(f"\n{path}: {type(ex).__name__}: {ex}")
elif cmd == "get":
    src, dst = args
    e = fs.get(src)
    with e.open() as f, open(dst, "wb") as o:
        n = 0
        while chunk := f.read(1 << 20): o.write(chunk); n += len(chunk)
    print(f"{src} -> {dst} ({n} bytes)")
