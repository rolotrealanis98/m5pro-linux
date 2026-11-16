#!/bin/bash
# SPDX-License-Identifier: MIT
# run-hv27-gpu.sh - Studio side of the attended GPU InitData capture (request hv-gpu-initdata-1): macOS 27.3
# (26C5035r) under the m1n1 hypervisor on the J716s, rung iii-a (no SSD), GPU mailbox tracer from SPTM's first AMCC
# read. Derived from the 2026-11-08 run-hv27.sh; everything lives under /Volumes/m5pro/bench/hv27-gpu.
#
#   run-hv27-gpu.sh check          offline preflight (no MacBook): files, hashes, venv, proxyclient imports, modules
#   run-hv27-gpu.sh smoke          wait for the proxy stage-2, identify it (must be v2.0.0-132-g63e6053c), stay
#   run-hv27-gpu.sh gpu [-- extra run_guest args]
#                                  single-core guest, ANS stripped, hv27-trace-late.py + hv27-gpu-initdata.py;
#                                  dumps under runs/<ts>-gpu/capture/, then the compare script runs on exit
#   run-hv27-gpu.sh compare RUNDIR re-run the comparison on a finished run
#   run-hv27-gpu.sh reboot         abort helper: connect to an idle proxy (no hv running) and watchdog-reset the Mac
# Env: HV27_ARGS (guest boot args, default "-v debug=0x14e wdt=-1 cpus=1"), HV27_WDT=keep|off (default keep: the
# stage-1 watchdog stays armed, m1n1 pets it from proxy requests and the hv tick; an idle shell > ~150 s resets the
# Mac into the fallback daily), HV27_SHELL=1 (stop in the shell before the guest starts; needs HV27_WDT=off),
# HV27_GPU_* (passed to the module, see hv/hv27-gpu-initdata.py).
# Stop: Ctrl-C -> hypervisor shell; cont() resumes; reboot() = watchdog reset -> iBoot counts it -> stage-1 boots
# boot.bin.prev. Ctrl-D in the final shell exits (the compare step then runs).
set -u
H=/Volumes/m5pro/bench/hv27-gpu
M=$H/m1n1-63e6053c                         # proxyclient = the stage-2's tree (63e6053c + hv27 proxyclient patch)
PY=$H/venv/bin/python
G=$H/guest/raw
BIN=$H/payload/m1n1-hv27-proxy.bin         # = archive m1n1-identity.bin; only read for its version string
BIN_SHA=3ea655950e932392a273576847ec9713171fc52fee3217f46ad538168a11eae1
ARGS=${HV27_ARGS:--v debug=0x14e wdt=-1 cpus=1}
TS=$(date +%Y%m%d-%H%M%S)

m1n1_dev() {   # /dev/cu.usbmodem<serial>N of the first 1209:316d device
    local ser
    ser=$(ioreg -p IOUSB -l -w0 2>/dev/null | python3 -I -c '
import sys, re
for b in sys.stdin.read().split("+-o "):
    if re.search(r"\"idVendor\" = 4617\b", b) and re.search(r"\"idProduct\" = 12653\b", b):
        m = re.search(r"\"USB Serial Number\" = \"([^\"]+)\"", b)
        if m: print(m.group(1)); break')
    [ -n "$ser" ] && [ -e "/dev/cu.usbmodem${ser}$1" ] && echo "/dev/cu.usbmodem${ser}$1"
}
run_py() { (cd "$M/proxyclient" && PATH=/usr/bin:/bin:/usr/sbin:/sbin TOOLCHAIN=/opt/homebrew/opt/llvm/bin/ \
            LLDDIR=/opt/homebrew/opt/lld/bin/ PYTHONPATH=. M1N1DEVICE=${M1N1DEVICE:-} "$PY" "$@"); }
newrun() {
    D=$H/runs/$TS-$1; mkdir -p "$D"
    { echo "$0 $*"; date; cat "$M/TREE-COMMIT"; shasum -a 256 "$BIN" "$H/hv/"*.py; (cd "$G" && shasum -a 256 -c SHA256SUMS); } > "$D/RUN.txt" 2>&1
    echo "run dir: $D"
}
wait_dev() {
    echo "waiting for the m1n1 USB proxy (connect within ~140 s of the reboot)..."
    local t0=$(date +%s)
    while :; do
        M1N1DEVICE=$(m1n1_dev 1); CONS=$(m1n1_dev 3)
        [ -n "$M1N1DEVICE" ] && break
        [ $(( $(date +%s) - t0 )) -ge ${HV27_WAIT:-600} ] && { echo "timeout: no 1209:316d device"; exit 1; }
        sleep 0.5
    done
    echo "proxy $M1N1DEVICE console ${CONS:-none} after $(( $(date +%s) - t0 )) s"
    sleep 6   # a request while m1n1 is still initialising its gadget gets garbage
    [ -n "${CONS:-}" ] && { "$PY" -I -c '
import serial, sys, time
s = serial.Serial(sys.argv[1], 115200, timeout=1); s.dtr = True
end = time.time() + float(sys.argv[3])
with open(sys.argv[2], "ab") as f:
    while time.time() < end:
        try: d = s.read(4096)
        except Exception: break
        if d: f.write(d); f.flush()' "$CONS" "$D/console.log" 36000 & echo $! > "$D/console.pid"; }
}
IDENT='
from m1n1.setup import *
import os, sys
chip = u.adt["/chosen"].chip_id
img = iface.readmem(u.base, 0x140000)
i = img.find(b"##m1n1_ver##")
ver = img[i + 12:img.index(b"\0", i)].decode() if i >= 0 else "?"
print(f"m1n1 {ver} chip {chip:#x}")
want = os.environ["HV27_WANT"]
if want != ver:
    sys.exit(f"STOP: the proxy is not the hv27 stage-2 (want {want}); the chain booted something else")
wdt = u.adt["/arm-io/wdt"].get_reg(0)[0]
if os.environ.get("HV27_WDT", "keep") == "keep":
    print(f"stage-1 watchdog left armed (ctrl={p.read32(wdt + 0x1c):#x}); m1n1 pets it from proxy requests and the hv tick")
else:
    p.write32(wdt + 0x1c, 0)
    print(f"stage-1 watchdog disarmed (ctrl={p.read32(wdt + 0x1c):#x}): power-hold is the abort")
'
want() { python3 -I -c 'import sys; b=open(sys.argv[1],"rb").read(); i=b.find(b"##m1n1_ver##"); print(b[i+12:b.index(b"\0",i)].decode())' "$BIN"; }
compare() {
    local R=$1 C
    C=$(command ls -d "$R"/capture 2>/dev/null) || { echo "no capture dir in $R"; return 1; }
    python3 -I "$H/tools/initdata-compare.py" --pr-src "$H/pr1173-src/drivers_gpu_drm_asahi_g17_fw_m5_initdata.rs" \
        --private-json "$R/compare-private.json" --public-md "$R/SUMMARY-public.md" "$C"
}

case ${1:-} in
check)
    ok=1
    [ "$(shasum -a 256 "$BIN" | cut -c1-64)" = "$BIN_SHA" ] && echo "ok   proxy payload 3ea65595 ($(want))" || { echo "FAIL proxy payload hash"; ok=0; }
    (cd "$G" && shasum -a 256 -c SHA256SUMS >/dev/null) && echo "ok   guest files match SHA256SUMS" || { echo "FAIL guest files"; ok=0; }
    head -1 "$M/TREE-COMMIT" | grep -q '^63e6053c' && grep -q hv27-m1n1-uncommitted "$M/TREE-COMMIT" && echo "ok   proxyclient tree 63e6053c + hv27 patch" || { echo "FAIL tree"; ok=0; }
    run_py -c 'import m1n1.hv, m1n1.hv.sprr, m1n1.proxyutils, m1n1.adt; print("ok   proxyclient imports (", m1n1.hv.__file__, ")")' || ok=0
    for f in "$H"/hv/*.py "$H"/tools/*.py; do "$PY" -m py_compile "$f" || { echo "FAIL compile $f"; ok=0; }; done
    echo "ok   modules compile"
    [ $ok = 1 ] && echo "CHECK PASSED" || { echo "CHECK FAILED"; exit 1; } ;;
smoke)
    newrun smoke; wait_dev
    HV27_WANT=$(want) run_py -c "$IDENT" 2>&1 | tee "$D/smoke.log"
    echo "stays in the proxy. Next: '$0 gpu' in this boot." ;;
gpu)
    shift; [ "${1:-}" = -- ] && shift
    for f in kernelcache.macho sptm.macho txm.macho exclavecore.bundle exclave-trustcache.bin exclave-integrity-catalog.bin; do
        [ -f "$G/$f" ] || { echo "missing $G/$f"; exit 1; }; done
    [ -n "${HV27_SHELL:-}" ] && [ "${HV27_WDT:-keep}" = keep ] && { echo "HV27_SHELL=1 needs HV27_WDT=off (an idle shell does not pet the watchdog)"; exit 2; }
    newrun gpu; echo "ARGS=$ARGS HV27_WDT=${HV27_WDT:-keep} $(env | grep '^HV27_GPU_' | tr '\n' ' ')" >> "$D/RUN.txt"
    SH=(); [ -n "${HV27_SHELL:-}" ] && SH=(-S)
    wait_dev
    HV27_WANT=$(want) run_py -c "$IDENT" 2>&1 | tee "$D/ident.log"; [ "${PIPESTATUS[0]}" = 0 ] || exit 1
    HV27_TRACE= HV27_GPU_OUT="$D/capture" run_py tools/run_guest.py --sptm-mode emulation -p "$G/sptm.macho" -t "$G/txm.macho" \
        --exclave-bundle "$G/exclavecore.bundle" --exclave-trustcache "$G/exclave-trustcache.bin" \
        --exclave-integrity-catalog "$G/exclave-integrity-catalog.bin" --strip-node iop-ans-nub \
        -m "$H/hv/hv27-trace-late.py" -m "$H/hv/hv27-gpu-initdata.py" ${SH[@]+"${SH[@]}"} -l "$D/run_guest.log" "$@" \
        "$G/kernelcache.macho" -- $ARGS 2>&1 | tee "$D/hv.log"
    grep -a '^GPUINIT:' "$D/hv.log" > "$D/gpuinit.log" || true
    compare "$D" ;;
compare)
    compare "${2:?run dir}" ;;
reboot)    # abort helper for an idle proxy (no hypervisor running): watchdog reset, counted -> fallback boot.bin.prev
    newrun reboot; wait_dev
    run_py -c 'from m1n1.setup import *; print("watchdog reset requested"); p.reboot()' 2>&1 | tee "$D/reboot.log" ;;
*) sed -n 3,20p "$0"; exit 2 ;;
esac
[ -f "${D:-/nonexistent}/console.pid" ] && kill "$(cat "$D/console.pid")" 2>/dev/null
exit 0
