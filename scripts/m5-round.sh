#!/bin/bash
# One unattended macOS-guest round on the M5:
#   wait for a fresh m1n1 -> run m5-guest.sh in tmux -> wait until the guest goes quiet
#   -> break into the hv shell -> dump hv-diag.py to build/smp/diag-<n>.txt -> reboot the Mac.
# The Mac reboots back into the installed m1n1 (the stub is the default startup disk).
#   scripts/probes/m5-round.sh <n> [--now|--running]
#     --now: m1n1 is already fresh, don't wait; --running: round <n> already runs in m5hv
set -euo pipefail
n=${1:?attempt number}
P=$HOME/Work/omarchy-m5/scripts/probes
OUT=$HOME/Work/omarchy-m5/build/smp/diag-$n.txt
enum() { journalctl -k --no-pager | grep -c 'usb 3-1.3.2: new high-speed' || true; }

mode=${2:-}
if [ "$mode" = "" ]; then
    before=$(enum)
    until [ "$(enum)" -gt "$before" ] && lsusb -d 1209:316d >/dev/null 2>&1 &&
          [ -e /dev/m1n1 ] && ! fuser /dev/ttyACM0 >/dev/null 2>&1; do sleep 3; done
    sleep 3
fi
if [ "$mode" != --running ]; then
tmux kill-session -t m5hv 2>/dev/null || true
tmux new-session -d -s m5hv -x 220 -y 50 "$P/m5-guest.sh $n"
tmux set-option -t m5hv remain-on-exit on >/dev/null
tmux set-option -t m5hv history-limit 50000 >/dev/null
echo "round $n started $(date +%T)"
fi

pane() { tmux capture-pane -p -t m5hv -S -50000; }   # the -l log is buffered; the console is not
until pane | grep -q "Jumping to entrypoint"; do
    tmux list-panes -t m5hv -F '#{pane_dead}' | grep -q 1 && { echo "launcher died"; tmux capture-pane -p -t m5hv -S -40; exit 1; }
    sleep 5
done
echo "jumped $(date +%T)"

last="" quiet=0
until [ $quiet -ge 60 ]; do
    s=$(pane | md5sum); if [ "$s" = "$last" ]; then quiet=$((quiet + 5)); else quiet=0 last=$s; fi
    tmux capture-pane -p -t m5hv | grep -q '^>>>' && break     # guest already dropped to the shell
    sleep 5
done
echo "quiet $(date +%T)"

tmux capture-pane -p -t m5hv | grep -q '^>>>' || "$P/hvsh.sh" --break >/dev/null
"$P/hvsh.sh" "import builtins; builtins.exec(open('$P/hv-diag.py').read())" > "$OUT"
pane | grep -v "^\(PT\[\|TTY> hv_sprr: L[0-9]\)" | tail -60 >> "$OUT"
echo "diag -> $OUT"
"$P/hvsh.sh" "p.reboot()" >/dev/null 2>&1 &
sleep 5
tmux kill-session -t m5hv 2>/dev/null || true
echo "reboot sent $(date +%T)"
