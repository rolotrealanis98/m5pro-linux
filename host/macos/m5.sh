#!/bin/bash
# SPDX-License-Identifier: MIT
# macOS-side tether helpers for the M5, for when the Studio is booted into macOS instead of
# Omarchy. Same layout as the Linux side: m1n1 at ~/Work/m1n1 (branch m5-t6050, venv in .venv),
# omarchy-m5 at ~/Work/omarchy-m5 (branch j716s). The M5 in m1n1 enumerates as USB 1209:316d
# "Asahi Linux / Generic CDC" with the Mac's serial number: /dev/cu.usbmodem<serial>1 is the
# proxy and ...3 the secondary. Found via ioreg below; override with M1N1DEVICE. No udev needed.
#
#   host/macos/m5.sh wait [secs]   wait until stage-1 m1n1 answers on the proxy (default 240 s)
#   host/macos/m5.sh fw            firmware version, chip, m1n1 base (is it mBoot-20457.41.2 still?)
#   host/macos/m5.sh smp-test      the 27.3 re-test: wdt-arm 150 -> release-variants.py -> wdt off
#   host/macos/m5.sh shell         m1n1 proxy shell
#   host/macos/m5.sh py FILE ...   run a proxyclient script (wdt-arm.py, probes) against the M5
#   host/macos/m5.sh boot-linux    chainload build/m1n1-chain.bin, then linux.py with the kernel built
#                                  here (omarchy-m5 vendor/linux), in tmux session "m5linux"; all cores
#   host/macos/m5.sh console       attach to that tmux session
#   host/macos/m5.sh log [secs]    capture m1n1's console (the proxy's secondary USB interface,
#                                  /dev/cu.usbmodem<serial>3) to ~/Work/m5-logs/m1n1-console-*.log
#                                  until it disappears or secs elapse; shows what stage-1 prints
#                                  after its USB init, including the ESP chainload steps
#   host/macos/m5.sh reboot        macvdmtool reboot of the M5 over the Thunderbolt debug-port cable
#   host/macos/m5.sh autoboot      hands-free tether: whenever stage-1 m1n1 appears on USB, run
#                                  boot-linux (Arch root, all cores); Ctrl-C to stop. Interim
#                                  "untethered" until the ESP stage-1 is installed.
set -u
M=$HOME/Work/m1n1; O=$HOME/Work/omarchy-m5
R=$(cd "$(dirname "$0")/../.." && pwd)
LOGS=$HOME/Work/m5-logs
m1n1_dev() {   # /dev/cu.usbmodem<serial>1 of the first 1209:316d device, else the old P_01 name
    local ser
    ser=$(ioreg -p IOUSB -l -w0 2>/dev/null | python3 -c '
import sys, re
for b in sys.stdin.read().split("+-o "):
    if re.search(r"\"idVendor\" = 4617\b", b) and re.search(r"\"idProduct\" = 12653\b", b):
        m = re.search(r"\"USB Serial Number\" = \"([^\"]+)\"", b)
        if m: print(m.group(1)); break')
    [ -n "$ser" ] && [ -e "/dev/cu.usbmodem${ser}1" ] && echo "/dev/cu.usbmodem${ser}1" || echo /dev/cu.usbmodemP_01
}
export M1N1DEVICE=${M1N1DEVICE:-$(m1n1_dev)}
PY=$M/.venv/bin/python
# The proxyclient shells out to `brew --prefix llvm` at import with a 2 s timeout, which fails
# under load (a kernel build); hide brew from it and name the toolchain directly instead.
run() { (cd "$M/proxyclient" && PATH=/usr/bin:/bin:/usr/sbin:/sbin TOOLCHAIN=/opt/homebrew/opt/llvm/bin/ LLDDIR=/opt/homebrew/opt/lld/bin/ PYTHONPATH=. "$PY" "$@"); }
fw_snippet='
from m1n1.setup import *
ch = u.adt["/chosen"]
for k in sorted(ch._properties):
    if any(s in k for s in ("firmware", "version", "boot-objects", "security")):
        v = getattr(ch, k.replace("-", "_"), None)
        print(f"/chosen/{k} = {v!r}")
print(f"chip {u.adt.compatible[0]!r} m1n1 base {u.base:#x}")
'
case ${1:-} in
wait)
    t=${2:-240}; t0=$(date +%s)
    while :; do
        if [ -e "$M1N1DEVICE" ]; then
            sleep 3
            out=$(timeout 25 "$PY" -c 'import sys; sys.path.insert(0, "'"$M/proxyclient"'"); from m1n1.setup import *; print(f"proxy ok base {u.base:#x}")' 2>/dev/null | tail -1)
            [[ $out == proxy\ ok* ]] && { echo "$out after $(( $(date +%s) - t0 )) s"; exit 0; }
        fi
        [ $(( $(date +%s) - t0 )) -ge "$t" ] && { echo "timeout: $M1N1DEVICE not answering"; exit 1; }
        sleep 3
    done ;;
fw)   run -c "$fw_snippet" ;;
shell) run "$M/proxyclient/tools/shell.py" ;;
py)   shift; run "$@" ;;
smp-test)
    mkdir -p "$LOGS"; log=$LOGS/smp-$(date +%Y%m%d-%H%M%S).log
    echo "log: $log"
    {
        echo "== $(date) =="; run -c "$fw_snippet" || exit 1
        echo "== arming watchdog 150 s =="; run "$O/scripts/probes/wdt-arm.py" 150 || exit 1
        echo "== release-variants.py =="; run "$R/scripts/probes/release-variants.py"; rc=$?
        echo "== disarming =="
        if run "$O/scripts/probes/wdt-arm.py" --off; then :; else
            echo "proxy gone: the M5 reset itself. After a crumb hit that is the stub's 8 s watchdog (expected)."
            echo "Run 'm5.sh wait && m5.sh fw' to confirm it is back in stage-1."
        fi
        exit $rc
    } 2>&1 | tee "$log" ;;
boot-linux)
    # M5_ARTIFACTS=dir overrides; default: the Linux-side builds recovered from the Omarchy volume
    # (~/Work/studio-artifacts, the exact files that booted in October), else what was built here.
    if [ -n "${M5_ARTIFACTS:-}" ] || [ -d "$HOME/Work/studio-artifacts" ]; then
        A=${M5_ARTIFACTS:-$HOME/Work/studio-artifacts}
        IMG=$A/Image.gz; DTB=$A/t6050-j716s.dtb; IRF=$A/initramfs.cpio.gz; CHAIN=$A/m1n1-chain.bin
    else
        K=$O/vendor/linux/arch/arm64/boot; IMG=$K/Image.gz; DTB=$K/dts/apple/t6050-j716s.dtb; IRF=$O/build/initramfs.cpio.gz
        CHAIN=$M/build/m1n1-chain.bin
    fi
    IRF=${LINUX_INITRD:-$IRF}   # LINUX_INITRD= overrides (e.g. the esp-install overlay)
    echo "kernel $IMG"; echo "dtb    $DTB"; echo "initrd $IRF"; echo "m1n1   $CHAIN"
    for f in "$IMG" "$DTB" "$IRF" "$CHAIN"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
    ARGS=${LINUX_ARGS:-"earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5"}
    mkdir -p "$LOGS"; log=$LOGS/linux-$(date +%Y%m%d-%H%M%S).log; echo "log: $log"
    echo "== chainload $CHAIN (-r -n) =="
    run "$M/proxyclient/tools/chainload.py" -r -n "$CHAIN" 2>&1 | tee "$log" | tail -5
    sleep 4; "$0" wait 120 | tee -a "$log" || exit 1
    echo "== linux.py (tmux session m5linux; '$0 console' to attach) =="
    tmux kill-session -t m5linux 2>/dev/null || true
    tmux new-session -d -s m5linux -x 200 -y 50 "cd '$M/proxyclient' && PATH=/usr/bin:/bin:/usr/sbin:/sbin TOOLCHAIN=/opt/homebrew/opt/llvm/bin/ M1N1DEVICE='$M1N1DEVICE' PYTHONPATH=. '$PY' tools/linux.py '$IMG' '$DTB' '$IRF' -b '$ARGS' 2>&1 | tee -a '$log'; echo '[linux.py exited]'; sleep 86400"
    sleep 25; tmux capture-pane -p -t m5linux | grep -vE '^\s*$' | tail -25 ;;
console) tmux attach -t m5linux ;;
log)
    # m1n1 keeps no console backlog, so open the primary interface the instant it enumerates and
    # record everything it prints from then on (a stage-1 doing an ESP chainload prints its steps
    # right after USB init). Polls every 50 ms; stops when the device goes away or secs elapse.
    secs=${2:-180}; mkdir -p "$LOGS"; log=$LOGS/m1n1-console-$(date +%Y%m%d-%H%M%S).log; echo "log: $log"
    "$PY" - "$secs" "$log" <<'PYEOF'
import glob, re, serial, subprocess, sys, time
secs, log = int(sys.argv[1]), sys.argv[2]
def m1n1_primary():
    for d in glob.glob("/dev/cu.usbmodem*1"):
        if "204101" in d: continue           # the ESP32 on this desk
        return d
    return None
t0 = time.time(); dev = None
if "--next" in sys.argv[3:] or True:
    # wait for the current m1n1 (if any) to go away first, so the capture is of the *next* boot
    while m1n1_primary() and time.time() - t0 < secs: time.sleep(0.2)
    if time.time() - t0 >= secs: sys.exit("m1n1 never went away")
    print(f"previous m1n1 gone after {time.time()-t0:.0f}s; waiting for the next boot", flush=True)
    t0 = time.time()
while time.time() - t0 < secs and not dev:
    dev = m1n1_primary() or (time.sleep(0.05) or None)
if not dev: sys.exit(f"no m1n1 device in {secs}s")
print(f"opened {dev} after {time.time()-t0:.1f}s", flush=True)
with open(log, "ab") as f:
    try:
        s = serial.Serial(dev, 115200, timeout=0.2); s.dtr = True
        while time.time() - t0 < secs:
            b = s.read(65536)
            if b:
                f.write(b); f.flush(); sys.stdout.write(b.decode("utf-8", "replace")); sys.stdout.flush()
    except (serial.SerialException, OSError) as ex:
        print(f"\n[device gone: {ex}]")
PYEOF
    ;;
reboot) sudo /Users/rolo/Work/macvdmtool/macvdmtool reboot 2>&1 | tail -2 ;;
autoboot)
    echo "autoboot: watching for stage-1 m1n1 (device $(m1n1_dev)); Ctrl-C stops"
    while :; do
        if "$0" wait 20 >/dev/null 2>&1; then
            echo "$(date +%T) autoboot: m1n1 is up, booting Linux"
            "$0" boot-linux 2>&1 | grep -E '^(kernel|log:|== |proxy ok)' || true
            # the kernel owns USB now; wait for it to go away before watching again
            sleep 60
        fi
        sleep 5
    done ;;
*)    sed -n 2,16p "$0"; exit 2 ;;
esac
