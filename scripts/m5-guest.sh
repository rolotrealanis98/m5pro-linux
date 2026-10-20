#!/bin/bash
# One macOS-guest round on the M5 from a fresh m1n1: chainload the working-tree
# build, then boot this Mac's own boot objects under the SPTM-emulating hv.
#   tmux new-session -d -s m5hv scripts/probes/m5-guest.sh <n>
#   tmux attach -t m5hv      # watch / take over
set -euo pipefail
n=${1:?attempt number}
M=$HOME/Work/m1n1
D=$HOME/Work/omarchy-m5/build/macos-26B5112a
L=$HOME/Work/omarchy-m5/build/smp
export M1N1DEVICE=/dev/m1n1 PYTHONPATH=$M/proxyclient
PY=$M/.venv/bin/python
cd "$M/proxyclient"

# Dead-man switch: the chained m1n1 keeps the watchdog armed and pets it (m1n1.wdt=keep), so a
# wedged m1n1 resets the Mac back into the installed stage-1 within 170 s.
$PY "$HOME/Work/omarchy-m5/scripts/probes/wdt-arm.py" 170 2>&1 | grep armed
$PY tools/chainload.py -r -n ../build/m1n1-chain.bin m1n1.wdt=keep 2>&1 | tail -3
sleep 3
# --strip-node iop-ans-nub: XNU cannot boot the SSD controller firmware, so an unattended macOS
# can never write the disk. (Stripping all of "ans" kills SPTM: it needs sart-ans.)
exec $PY tools/run_guest.py --sptm-mode emulation -p "$D/sptm.macho" -t "$D/txm.macho" \
    --strip-node iop-ans-nub \
    -m "$HOME/Work/omarchy-m5/scripts/probes/hv-trace-cpu-start.py" -l "$L/guest-$n.log" \
    "$D/kernelcache.macho" -- -v debug=0x14e serial=3
