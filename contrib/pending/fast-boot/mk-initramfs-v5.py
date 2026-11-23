#!/usr/bin/env python3
"""Build initramfs-ftab-wdt2-fsck-v5 from v4q: only the `init` entry changes again.

v4q = v3 plus a quiet mode: when the kernel command line has `quiet`, the init's progress text (banner, fsck result,
root wait) goes to the kernel log (/dev/kmsg, level 6) instead of the screen. Failure paths still print to the console
(the "did not mount ... DIAG" block), so a hang is as visible as before. Without `quiet` it behaves exactly like v3.

  python3 -I -B mk-initramfs-v4q.py [IN.cpio.gz] [OUT.cpio.gz]

Every other cpio entry is copied byte for byte (header, name, data, padding); the script checks that. Writes one file,
deletes nothing.
"""
import gzip, hashlib, pathlib, sys, zlib

IN = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/Volumes/m5pro/bench/fast-boot/initramfs-ftab-wdt2-fsck-v4q.cpio.gz")
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/Volumes/m5pro/bench/fast-boot/initramfs-ftab-wdt2-fsck-v5.cpio.gz")

def parse(d):
    """-> list of (kind, payload): ('ent', (hdr_fields, name_bytes, data)) or ('raw', bytes)"""
    i, out = 0, []
    while i < len(d):
        if d[i:i+6] != b"070701":
            j = i
            while j < len(d) and d[j] == 0: j += 1
            if j == i: raise SystemExit(f"bad cpio magic at {i}")
            out.append(("raw", d[i:j])); i = j; continue
        f = [int(d[i+6+8*k:i+14+8*k], 16) for k in range(13)]
        size, nl = f[6], f[11]
        name = d[i+110:i+110+nl]
        a = (i + 110 + nl + 3) & ~3
        data = d[a:a+size]
        b = (a + size + 3) & ~3
        out.append(("ent", (f, name, data, d[i+110+nl:a], d[a+size:b])))   # keep both paddings
        i = b
    return out

def emit(items):
    o = bytearray()
    for k, p in items:
        if k == "raw": o += p; continue
        f, name, data, pad1, pad2 = p
        o += b"070701" + b"".join(b"%08X" % v for v in f) + name + pad1 + data + pad2
    return bytes(o)

raw = gzip.open(IN).read()
items = parse(raw)
assert emit(items) == raw, "round trip failed"

def sub(s, old, new, count=1):
    assert s.count(old) == count, f"expected {count} x {old!r}, found {s.count(old)}"
    return s.replace(old, new)

new_items, patched = [], False
for k, p in items:
    if k == "ent" and p[1] == b"init\0":
        f, name, data, pad1, pad2 = p
        s = data.decode()
        # 1. quiet means silent: with `quiet`, stdout/stderr of the whole init go to /dev/null (fd 3 keeps /dev/console for the
        #    failure paths, which switch back). v4q only sent its own progress lines to the kernel log; this also covers
        #    anything a command prints (usb-gadget-net, dropbear, mount, busybox applets).
        s = sub(s, 'Q=; $BB grep -qw quiet /proc/cmdline && Q=1\n',
                'Q=; $BB grep -qw quiet /proc/cmdline && Q=1\n'
                '[ -n "$Q" ] && { exec 3>/dev/console; exec >/dev/null 2>&1; }\n')
        # failure paths: the console again, so the DIAG block and the shell prompt are visible as in v3
        s = sub(s, '        echo "debug: mount of $ROOT failed"\n',
                '        [ -n "$Q" ] && exec >&3 2>&3\n        echo "debug: mount of $ROOT failed"\n')
        s = sub(s, '    echo "m5.root=$M5ROOTSPEC did not mount after 30 s; staying in initramfs (sshd up)"\n',
                '    [ -n "$Q" ] && exec >&3 2>&3\n    echo "m5.root=$M5ROOTSPEC did not mount after 30 s; staying in initramfs (sshd up)"\n')
        # 2. the self-revert unit installed into the root: Type=exec, not oneshot. A oneshot that sleeps 90 s keeps its start
        #    job (and multi-user.target, Startup finished, and anything that waits for the boot to settle) pending for 90 s,
        #    which made test boots look 25-30 s slower than the daily. Type=exec is started once exec'd; the script is unchanged.
        s = sub(s, 'Type=oneshot\nExecStart=/usr/local/sbin/m5-selftest\n', 'Type=exec\nExecStart=/usr/local/sbin/m5-selftest\n')
        data = s.encode()
        f = list(f); f[6] = len(data)
        pad2 = b"\0" * (((len(data) + 3) & ~3) - len(data))
        p = (f, name, data, pad1, pad2); patched = True
    new_items.append((k, p))
assert patched, "no init entry"
new = emit(new_items)
# check: everything except init is byte-identical
a = [p for k, p in items if k == "ent" and p[1] != b"init\0"]
b = [p for k, p in new_items if k == "ent" and p[1] != b"init\0"]
assert a == b and len(a) == 550, "other entries changed"
OUT.parent.mkdir(parents=True, exist_ok=True)
gz = gzip.compress(new, 9, mtime=0)
assert zlib.decompressobj(31).decompress(gz) == new
OUT.write_bytes(gz)
print(f"{OUT} {len(gz)} bytes sha256 {hashlib.sha256(gz).hexdigest()}  (raw {len(raw)} -> {len(new)}; init changed, 550 entries identical)")
