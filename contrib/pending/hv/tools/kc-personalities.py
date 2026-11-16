#!/usr/bin/env python3
"""kc-personalities.py KC.macho BUNDLEID... - print the IOKitPersonalities and OSBundleRequired of the
named kexts from the kernelcache's __PRELINK_INFO (metadata only, no code)."""
import plistlib, re, struct, sys
b = open(sys.argv[1], "rb").read()
_, _, _, _, ncmds, _, _, _ = struct.unpack_from("<8I", b, 0)
off = 32
info = None
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", b, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        seg = b[off + 8:off + 24].rstrip(b"\0").decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", b, off + 24)
        if seg == "__PRELINK_INFO":
            info = b[fileoff:fileoff + filesize]
    off += size
raw = info[:info.index(b"\0")] if b"\0" in info else info
# XNU's prelink plist uses ID/IDREF attributes plistlib does not know; strip them
txt = re.sub(rb'\s(ID|IDREF)="[0-9]+"', b"", raw)
txt = re.sub(rb'<(integer|string|data|dict|array)\s+IDREF="[0-9]+"\s*/>', b"<string>IDREF</string>", txt)
pl = plistlib.loads(txt)
for k in pl["_PrelinkInfoDictionary"]:
    bid = k.get("CFBundleIdentifier")
    if bid in sys.argv[2:]:
        print(f"== {bid} OSBundleRequired={k.get('OSBundleRequired')}")
        for name, p in (k.get("IOKitPersonalities") or {}).items():
            keep = {kk: vv for kk, vv in p.items() if kk.startswith("IO") or kk in ("CFBundleIdentifier",)}
            print(f"   {name}: {keep}")
