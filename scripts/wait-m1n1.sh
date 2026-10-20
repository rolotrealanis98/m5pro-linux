#!/bin/bash
# Wait until the M5 is back in m1n1 with a free, answering proxy (after a watchdog reset).
#   wait-m1n1.sh [timeout-seconds]   (default 240)
set -u
M=$HOME/Work/m1n1; t=${1:-240}; t0=$(date +%s)
while :; do
    if lsusb -d 1209:316d >/dev/null 2>&1 && [ -e /dev/m1n1 ] && ! fuser /dev/ttyACM0 >/dev/null 2>&1; then
        sleep 3
        if out=$(cd "$M/proxyclient" && M1N1DEVICE=/dev/m1n1 PYTHONPATH=. timeout 20 ../.venv/bin/python -c 'from m1n1.setup import *; print(f"proxy ok base {u.base:#x}")' 2>/dev/null | tail -1) && [[ $out == proxy\ ok* ]]; then
            echo "$out after $(( $(date +%s) - t0 )) s"; exit 0; fi
    fi
    [ $(( $(date +%s) - t0 )) -ge "$t" ] && { echo "timeout: m1n1 not back"; exit 1; }
    sleep 3
done
