#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""add-wdt-opener.py - give a test initramfs the /dev/watchdog0 opener (loop-safety, option A).

  add-wdt-opener.py --in IN.cpio.gz --out OUT.cpio.gz

Takes any initramfs made by mk-selftest-initramfs.sh (base + overlay, optionally + the FTAB archive), reads its
final /init, patches three places (anchors are asserted, the script refuses a different /init), and appends ONE
more newc archive that replaces /init and adds /etc/m5-wdt-opener. Output is a single gzip member (m1n1 keeps
only the last member). The input is not modified. Stdlib only; no macOS cpio needed. Output mode 0600.

What the patched /init does, only when the cmdline has m5.selftest=1 (the daily is untouched):
  1. right after devtmpfs: a background subshell opens /dev/watchdog0 once and writes "." every 10 s.
     The magic close character 'V' is never written; the pet loop closes fd 9 for its children so that
     killing the subshell releases the device at once.
  2. before switch_root, if the root has no RuntimeWatchdogSec>0 in system.conf(.d), installs
     /etc/systemd/system.conf.d/m5pro-watchdog.conf (RuntimeWatchdogSec=60, RebootWatchdogSec=5min), then
     kill -9 the petter (plain close: the dog stays armed, 30 s left) so the root's systemd opens the device
     within ~1-3 s of exec and pets it from then on.
  3. if the init stays in the initramfs (root never mounted: DIAG + ssh), the petter is killed after
     m5.wdt_diag=SECONDS (default 600; 0 = pet forever) so the machine resets and stage 1 falls back.
"""
import argparse, gzip, os, pathlib, struct, sys

MARK = "m5-wdt-opener v1"


# ------------------------------------------------------------------ newc cpio
def parse(b):
    off, out = 0, []
    while off + 110 <= len(b):
        if b[off:off + 6] != b"070701":
            if b[off:off + 4] == b"\0\0\0\0":
                off += 4
                continue
            sys.exit(f"cpio: bad magic at {off}")
        f = [int(b[off + 6 + 8 * i:off + 14 + 8 * i], 16) for i in range(13)]
        mode, fs, nsz = f[1], f[6], f[11]
        name = b[off + 110:off + 110 + nsz - 1].decode()
        p = (off + 110 + nsz + 3) & ~3
        out.append((name, mode, b[p:p + fs]))
        off = (p + fs + 3) & ~3
    return out


def entry(ino, name, mode, data=b""):
    nm = name.encode() + b"\0"
    h = b"070701" + b"".join(b"%08x" % v for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0))
    h += nm
    h += b"\0" * ((-len(h)) % 4)
    return h + data + b"\0" * ((-len(data)) % 4)


# ------------------------------------------------------------------ the patch
OPENER = r'''
# ---- m5-wdt-opener v1 (loop-safety): only with m5.selftest=1 -----------------------------------
# Stage 1 hands the watchdog to Linux armed (m1n1.wdt=keep, 30 s) and the kernel core feeds it until
# userspace opens /dev/watchdog0 (watchdog.open_timeout=N on the cmdline bounds that wait). Open it
# here, once, and pet it from a background subshell. NEVER write 'V' (magic close: it would stop
# the dog for good). The loop closes fd 9 for its children, so killing the subshell frees the device.
M5WDT=
if $BB grep -q 'm5\.selftest=1' /proc/cmdline; then
    i=0; while [ ! -c /dev/watchdog0 ] && [ $i -lt 100 ]; do $BB sleep 0.1; i=$((i+1)); done
    if [ -c /dev/watchdog0 ]; then
        ( exec 9<>/dev/watchdog0 || exit 1
          while :; do echo . >&9; $BB sleep 10 9>&-; done ) &
        M5WDT=$!
        $BB sleep 0.3
        if [ -e /proc/$M5WDT/fd/9 ]; then
            echo "m5-wdt: /dev/watchdog0 opened, petting every 10 s (pid $M5WDT)"
        else
            echo "m5-wdt: could not open /dev/watchdog0; the kernel core keeps feeding it"; M5WDT=
        fi
    else
        echo "m5-wdt: no /dev/watchdog0 after 10 s; the kernel core keeps feeding it"
    fi
fi
# ---- end m5-wdt-opener ---------------------------------------------------------------------------
'''

HANDOVER = r'''            if [ -n "$M5WDT" ]; then
                # m5-wdt-opener: hand the watchdog to the root's systemd (single-open device: close first).
                if ! $BB grep -qsE '^[[:space:]]*RuntimeWatchdogSec=[1-9]' /mnt/etc/systemd/system.conf /mnt/etc/systemd/system.conf.d/*.conf /mnt/usr/lib/systemd/system.conf.d/*.conf 2>/dev/null; then
                    echo "m5-wdt: root has no RuntimeWatchdogSec: installing /etc/systemd/system.conf.d/m5pro-watchdog.conf"
                    $BB mkdir -p /mnt/etc/systemd/system.conf.d
                    $BB cat > /mnt/etc/systemd/system.conf.d/m5pro-watchdog.conf <<'WDT'
[Manager]
RuntimeWatchdogSec=60
RebootWatchdogSec=5min
WDT
                fi
                echo "m5-wdt: closing /dev/watchdog0 (no magic character); systemd takes over within a few seconds"
                kill -9 $M5WDT 2>/dev/null; wait $M5WDT 2>/dev/null; M5WDT=
            fi
'''

GRACE = r'''if [ -n "$M5WDT" ]; then
    # m5-wdt-opener: still in the initramfs (root did not mount). Bounded, so the loop can recover.
    GRACE=$($BB sed -n 's/.*\bm5\.wdt_diag=\([0-9][0-9]*\).*/\1/p' /proc/cmdline); GRACE=${GRACE:-600}
    if [ "$GRACE" -gt 0 ]; then
        echo "m5-wdt: no root: petting stops in $GRACE s, then the watchdog resets the machine (stage-1 fallback). m5.wdt_diag=0 pets forever"
        ( $BB sleep $GRACE; kill -9 $M5WDT ) &
    else
        echo "m5-wdt: no root: m5.wdt_diag=0, petting forever"
    fi
fi
'''


def patch(init):
    t = init.decode()
    if MARK in t:
        sys.exit("input /init already has the opener")
    a1 = "$BB mkdir -p /dev/pts && $BB mount -t devpts devpts /dev/pts 2>/dev/null\n"
    a2 = "            $BB umount /dev/pts 2>/dev/null\n"
    a3 = "exec $BB sh\n"
    for a in (a1, a2, a3):
        if t.count(a) != 1:
            sys.exit(f"anchor not found exactly once in /init: {a!r} (a different /init: refusing)")
    t = t.replace(a1, a1 + OPENER)
    t = t.replace(a2, HANDOVER + a2)
    assert t.endswith(a3), "exec $BB sh is not the last line"
    t = t[:-len(a3)] + GRACE + a3
    return t.encode()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--in", dest="src", required=True, type=pathlib.Path)
    ap.add_argument("--out", required=True, type=pathlib.Path)
    a = ap.parse_args()
    b = a.src.read_bytes()
    raw = gzip.decompress(b)          # raises if the input is not one clean gzip stream
    if b[:3] != b"\x1f\x8b\x08":
        sys.exit("input is not gzip")
    ents = parse(raw)
    inits = [e for e in ents if e[0] == "init"]
    if not inits:
        sys.exit("no /init in input")
    new_init = patch(inits[-1][2])
    ov = entry(900001, "etc", 0o40755)
    ov += entry(900002, "etc/m5-wdt-opener", 0o100644, (MARK + "\n").encode())
    ov += entry(900003, "init", 0o100755, new_init)
    ov += entry(0, "TRAILER!!!", 0)
    pad = (-len(raw)) % 4
    blob = gzip.compress(raw + b"\0" * pad + ov, 9, mtime=0)
    fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(blob)
    os.chmod(a.out, 0o600)
    # verify: re-read, last /init has the marker, the first 'init' unchanged, one gzip member
    chk = gzip.decompress(a.out.read_bytes())
    e2 = parse(chk)
    assert [e for e in e2 if e[0] == "init"][-1][2] == new_init and MARK.encode() in new_init
    assert chk.startswith(raw), "base archive changed"
    print(f"{a.out}  {len(blob)} bytes  (init {len(inits[-1][2])} -> {len(new_init)} bytes)")


if __name__ == "__main__":
    main()
