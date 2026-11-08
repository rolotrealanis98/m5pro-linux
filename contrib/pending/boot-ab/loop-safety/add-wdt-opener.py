#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""add-wdt-opener.py - give a test initramfs the /dev/watchdog0 opener (loop-safety, option A), v2.

  add-wdt-opener.py --in IN.cpio.gz --out OUT.cpio.gz

Takes any initramfs made by mk-selftest-initramfs.sh (base + overlay, optionally + the FTAB archive), reads its
final /init, patches three places (anchors are asserted, the script refuses a different /init), and appends ONE
more newc archive that replaces /init and adds /etc/m5-wdt-opener. Output is a single gzip member (m5pro keeps
only the last member). The input is not modified. Stdlib only; no macOS cpio needed. Output mode 0600.

What the patched /init does, only when the cmdline has m5.selftest=1 (the daily is untouched). Every step logs to
the console and to /dev/kmsg ("m5-wdt: ..." in dmesg):
  1. writes PMU boot_stage 0x31 ("initramfs reached", scratchpad 0xf801, as m5-stage-mark.sh) from a background
     subshell that waits for the PMU nvmem.
  2. after devtmpfs: a background subshell opens /dev/watchdog0 once and writes "." every 10 s. The magic close
     character 'V' is never written. The PID is always remembered (v1 probed /proc/PID/fd/9, which does not exist
     while the loop runs its sleep with 9>&-, concluded "not open" and never handed over).
  3. before switch_root: installs /etc/systemd/system.conf.d/m5pro-watchdog.conf (RuntimeWatchdogSec=60,
     RebootWatchdogSec=5min) unless the root already sets RuntimeWatchdogSec; then kill -9 the petter AND every
     other holder of /dev/watchdog0 found in /proc/*/fd (plain close: the dog stays armed, 30 s left) and waits
     until nobody holds it, so the root's systemd opens it within ~1-3 s of exec; writes boot_stage 0x32.
  (m5.wdt=off on the cmdline: marks only, no opener/drop-in/hand-over: the negative test.)
  4. if the init stays in the initramfs (root never mounted: DIAG + ssh), the petter is killed after
     m5.wdt_diag=SECONDS (default 600; 0 = pet forever) so the machine resets and stage 1 falls back.
"""
import argparse, gzip, os, pathlib, struct, sys

MARK = "m5-wdt-opener v2"


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
# ---- m5-wdt-opener v2 (loop-safety): only with m5.selftest=1 -----------------------------------
# Stage 1 hands the watchdog to Linux armed (m1n1.wdt=keep, 30 s) and the kernel core feeds it until
# userspace opens /dev/watchdog0 (watchdog.open_timeout=N on the cmdline bounds that wait). Open it
# here, once, and pet it from a background subshell. NEVER write 'V' (magic close: it would stop
# the dog for good). Messages go to the console AND /dev/kmsg (dmesg: "m5-wdt: ...").
m5log() { echo "m5-wdt: $*"; echo "<5>m5-wdt: $*" > /dev/kmsg 2>/dev/null; }
# boot_stage in the PMU scratchpad (0xf801 = 63489), the same byte m5-stage-mark.sh writes: "1" = 0x31, "2" = 0x32
m5mark() {
    for d in /sys/bus/nvmem/devices/*; do
        case "$($BB ls -l $d/of_node 2>/dev/null)" in
        *spmi@28a014000/pmic@e*) $BB echo -n "$1" | $BB dd of=$d/nvmem bs=1 seek=63489 conv=notrunc 2>/dev/null && return 0 ;;
        esac
    done
    return 1
}
# close every open file on /dev/watchdog0 (plain close, no magic character): the petter, and anything it spawned
m5wdt_release() {
    [ -n "$M5WDT" ] && kill -9 $M5WDT 2>/dev/null
    i=0
    while [ $i -lt 30 ]; do
        held=
        for f in /proc/[0-9]*/fd/*; do
            case "$($BB readlink $f 2>/dev/null)" in
            */watchdog0) p=${f#/proc/}; p=${p%%/*}; if [ "$p" != "$$" ]; then held="$held $p"; kill -9 $p 2>/dev/null; fi ;;
            esac
        done
        [ -z "$held" ] && return 0
        i=$((i+1)); $BB sleep 0.1
    done
    return 1
}
M5WDT=; M5SELF=; M5NOWDT=
if $BB grep -q 'm5\.selftest=1' /proc/cmdline; then
    M5SELF=1
    # m5.wdt=off: negative test, marks only (0x31/0x32), no opener, no drop-in, no hand-over
    if $BB grep -q 'm5\.wdt=off' /proc/cmdline; then M5NOWDT=1; fi
    m5log "initramfs reached, m5.selftest=1 (stage mark 0x31)"
    ( i=0; until m5mark 1; do i=$((i+1)); [ $i -ge 100 ] && { m5log "stage mark 0x31: PMU nvmem not found"; exit 0; }; $BB sleep 0.2; done
      m5log "stage mark 0x31 written" ) &
    i=0; while [ -z "$M5NOWDT" ] && [ ! -c /dev/watchdog0 ] && [ $i -lt 100 ]; do $BB sleep 0.1; i=$((i+1)); done
    if [ -n "$M5NOWDT" ]; then
        m5log "m5.wdt=off: not opening /dev/watchdog0 (negative test)"
    elif [ -c /dev/watchdog0 ]; then
        ( exec 9<>/dev/watchdog0 || exit 1
          while :; do echo . >&9; $BB sleep 10 9>&-; done ) &
        M5WDT=$!       # always remembered: the hand-over kills it whatever the probe below says
        i=0; until $BB ls -l /proc/$M5WDT/fd 2>/dev/null | $BB grep -q watchdog0; do
            i=$((i+1)); [ $i -ge 30 ] && break; $BB sleep 0.1
        done
        # (fd 9 itself is closed while the pet loop runs its sleep, so look for any fd on the device)
        if [ $i -lt 30 ]; then m5log "/dev/watchdog0 opened, petting every 10 s (pid $M5WDT)"
        else m5log "WARNING: /dev/watchdog0 not seen open after 3 s (pid $M5WDT); it is still killed at the hand-over"; fi
    else
        m5log "no /dev/watchdog0 after 10 s; the kernel core keeps feeding it"
    fi
fi
# ---- end m5-wdt-opener ---------------------------------------------------------------------------
'''

HANDOVER = r'''            if [ -n "$M5SELF" ] && [ -n "$M5NOWDT" ]; then
                ( m5mark 2 ) &
                $BB sleep 0.3
            elif [ -n "$M5SELF" ]; then
                # m5-wdt-opener: hand the watchdog to the root's systemd (single-open device: close first).
                if $BB grep -qsE '^[[:space:]]*RuntimeWatchdogSec=[1-9]' /mnt/etc/systemd/system.conf /mnt/etc/systemd/system.conf.d/*.conf /mnt/usr/lib/systemd/system.conf.d/*.conf 2>/dev/null; then
                    m5log "root already sets RuntimeWatchdogSec"
                else
                    $BB mkdir -p /mnt/etc/systemd/system.conf.d
                    $BB cat > /mnt/etc/systemd/system.conf.d/m5pro-watchdog.conf <<'WDT'
[Manager]
RuntimeWatchdogSec=60
RebootWatchdogSec=5min
WDT
                    if $BB grep -qs '^RuntimeWatchdogSec=60' /mnt/etc/systemd/system.conf.d/m5pro-watchdog.conf; then
                        $BB sync; m5log "installed /etc/systemd/system.conf.d/m5pro-watchdog.conf"
                    else
                        m5log "WARNING: could not write m5pro-watchdog.conf: systemd will not open the watchdog, it will bite ~30 s after switch_root"
                    fi
                fi
                if m5wdt_release; then m5log "/dev/watchdog0 released (no magic character), nobody holds it; systemd opens it next"
                else m5log "WARNING: /dev/watchdog0 still held after 3 s"; fi
                M5WDT=
                ( m5mark 2 ) &
                $BB sleep 0.3
            fi
'''

GRACE = r'''if [ -n "$M5WDT" ]; then
    # m5-wdt-opener: still in the initramfs (root did not mount). Bounded, so the loop can recover.
    GRACE=$($BB sed -n 's/.*\bm5\.wdt_diag=\([0-9][0-9]*\).*/\1/p' /proc/cmdline); GRACE=${GRACE:-600}
    if [ "$GRACE" -gt 0 ]; then
        m5log "no root: petting stops in $GRACE s, then the watchdog resets the machine (stage-1 fallback). m5.wdt_diag=0 pets forever"
        ( $BB sleep $GRACE; kill -9 $M5WDT ) &
    else
        m5log "no root: m5.wdt_diag=0, petting forever"
    fi
fi
'''


def patch(init):
    t = init.decode()
    if "m5-wdt-opener" in t:
        sys.exit("input /init already has an opener")
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
