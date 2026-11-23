#!/usr/bin/env python3
"""Build initramfs-ftab-wdt2-fsck-v4q from v3: only the `init` entry changes.

v4q = v3 plus a quiet mode: when the kernel command line has `quiet`, the init's progress text (banner, fsck result,
root wait) goes to the kernel log (/dev/kmsg, level 6) instead of the screen. Failure paths still print to the console
(the "did not mount ... DIAG" block), so a hang is as visible as before. Without `quiet` it behaves exactly like v3.

  python3 -I -B mk-initramfs-v4q.py [IN.cpio.gz] [OUT.cpio.gz]

Every other cpio entry is copied byte for byte (header, name, data, padding); the script checks that. Writes one file,
deletes nothing.
"""
import gzip, hashlib, pathlib, sys, zlib

IN = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/Volumes/m5pro/bench/fsck/initramfs-ftab-wdt2-fsck-v3.cpio.gz")
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/Volumes/m5pro/bench/fast-boot/initramfs-ftab-wdt2-fsck-v4q.cpio.gz")

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
        # quiet switch + helpers, right after devtmpfs is mounted (before m5log, which prints)
        s = sub(s, '$BB mount -t devpts devpts /dev/pts 2>/dev/null\n',
                '$BB mount -t devpts devpts /dev/pts 2>/dev/null\n'
                '\n# ---- quiet (fast-boot, v4q): with "quiet" on the command line, progress text goes to the kernel log, not the screen.\n'
                '# Failure paths below still print to the console. Without "quiet" everything is as in v3.\n'
                'Q=; $BB grep -qw quiet /proc/cmdline && Q=1\n'
                'msg() { if [ -n "$Q" ]; then echo "<6>m5-init: $*" > /dev/kmsg 2>/dev/null; else echo "$*"; fi; }\n'
                'qrun() { if [ -n "$Q" ]; then "$@" >/dev/null 2>&1; else "$@"; fi; }\n')
        s = sub(s, 'm5log() { echo "m5-wdt: $*"; echo "<5>m5-wdt: $*" > /dev/kmsg 2>/dev/null; }',
                'm5log() { [ -n "$Q" ] || echo "m5-wdt: $*"; echo "<5>m5-wdt: $*" > /dev/kmsg 2>/dev/null; }')
        banner = ('echo\necho "================================================"\n'
                  'echo " omarchy-m5: userspace is alive on T6050 (M5 Pro)  [debug initramfs]"\n'
                  'echo "================================================"\n'
                  'echo "kernel:  $($BB uname -a)"\necho "cpus:    $($BB grep -c ^processor /proc/cpuinfo)"\n'
                  'echo "cmdline: $($BB cat /proc/cmdline)"\necho\n')
        assert banner in s
        s = s.replace(banner, banner.replace("echo\n", 'msg ""\n').replace("echo \"", "msg \""))
        s = sub(s, '[ -x /usr/sbin/usb-gadget-net ] && /usr/sbin/usb-gadget-net\n',
                '[ -x /usr/sbin/usb-gadget-net ] && qrun /usr/sbin/usb-gadget-net\n')
        s = sub(s, '&& echo "debug: dropbear listening on the gadget link"', '&& msg "debug: dropbear listening on the gadget link"')
        s = sub(s, 'echo "debug: waiting for $M5ROOTSPEC ($((i / 10)) s)"', 'msg "debug: waiting for $M5ROOTSPEC ($((i / 10)) s)"')
        s = sub(s, 'ROOT=$R; echo "debug: $M5ROOTSPEC is $ROOT";', 'ROOT=$R; msg "debug: $M5ROOTSPEC is $ROOT";')
        s = sub(s, 'echo "debug: ANS did not boot in time, rebinding $NVME"', 'msg "debug: ANS did not boot in time, rebinding $NVME"')
        s = sub(s, 'echo "debug: $ROOT appeared after $((i / 10)) s"', 'msg "debug: $ROOT appeared after $((i / 10)) s"')
        s = sub(s, 'echo "fsck: e2fsck $FSCKOPT $ROOT"', 'msg "fsck: e2fsck $FSCKOPT $ROOT"')
        s = sub(s, 'echo "fsck: rc=$FSCKRC (0 clean, 1 repaired, 4 needs a manual run)"; $BB tail -3 /run/m5-fsck.log',
                'msg "fsck: rc=$FSCKRC (0 clean, 1 repaired, 4 needs a manual run)"; msg "$($BB tail -3 /run/m5-fsck.log)"')
        s = sub(s, 'echo "selftest: installing the self-revert watchdog', 'msg "selftest: installing the self-revert watchdog')
        # debug toggle without a rebuild: `touch /etc/m5-verbose` on the root and the next boot raises the console loglevel
        # to 8 as soon as the root is mounted (userspace-time kernel text on the console). Costs one stat() when absent.
        s = sub(s, '        if $BB mount -t ext4 -o noatime "$ROOT" /mnt 2>/dev/null; then\n',
                '        if $BB mount -t ext4 -o noatime "$ROOT" /mnt 2>/dev/null; then\n'
                '            [ -e /mnt/etc/m5-verbose ] && echo "8 4 1 7" > /proc/sys/kernel/printk\n')
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
