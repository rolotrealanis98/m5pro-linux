#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# quiet-run.sh - wait (up to 3 h) for the panel to be off with no Chrome test running, then take the panel-off idle
# snapshot and the per-profile A/B. Detached, root: setsid -f bash quiet-run.sh >/dev/null 2>&1 </dev/null
set -u
D=/var/tmp/power1; OUT=$D/quiet-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"; exec > "$OUT/log.txt" 2>&1
end=$(( $(date +%s) + 10800 ))
quiet() { grep -q Off /sys/class/drm/card*-eDP-*/dpms && ! pgrep -f 'gpu-ab|run-ab.sh|cdp.py' >/dev/null; }
while :; do
    [ "$(date +%s)" -lt "$end" ] || { echo "no quiet window"; touch "$OUT/DONE"; exit 0; }
    if quiet; then sleep 60; quiet && break; fi
    sleep 20
done
echo "quiet at $(date -Is)"
bash $D/idle-snap.sh 60 quiet-paneloff
quiet && bash $D/profile-ab.sh 45 || echo "panel came on: profile A/B skipped"
touch "$OUT/DONE"
