#!/bin/bash
# Drive the m1n1 hv shell in tmux session m5hv (scripts/probes/m5-guest.sh).
#   hvsh.sh --break          Ctrl-C the guest, wait for the >>> prompt
#   hvsh.sh 'ctx()'          run one shell line, print what it printed
set -euo pipefail
S=m5hv
prompts() { tmux capture-pane -p -t $S -S -2000 | grep -c '^>>>' || true; }
before=$(prompts)
if [ "${1:-}" = --break ]; then
    tmux send-keys -t $S C-c
else
    tmux send-keys -t $S -l "$1"
    tmux send-keys -t $S Enter
fi
for _ in $(seq 1 120); do
    [ "$(prompts)" -gt "$before" ] && break
    sleep 0.5
done
# everything after the previous prompt
tmux capture-pane -p -t $S -S -2000 | awk -v n="$before" '/^>>>/{c++} c>=n' | grep -v '^PT\[' | tail -60
