#!/bin/sh
# m5pro: let the SSD controller finish its background work before the platform restart
# (m5pro-linux contrib/pending/boot-ab/firstboot/REPORT.md). v1 was `sync; sleep 20` on every shutdown.
# v2 (fast-boot): the wait is needed after a write burst (an ESP copy, a dd, a package install: the failures needed a
# restart within about a second of >= 40 MB of writes; plain reboots without a burst were clean in RESTART-EXP2/3), so it
# runs only when more than THRESH_MIB were written to nvme0n1 in the last WIN seconds. The writes are counted from
# /run/m5pro-io-samples (m5pro-iosample.timer, every 15 s) and the device's own counter. Anything unknown (no samples,
# uptime under WIN+15 s, unreadable counter) behaves like v1. Settings: /etc/default/m5pro-settle (THRESH_MIB WIN WAIT).
sync
S=${M5_SAMPLES:-/run/m5pro-io-samples}; DEV=${M5_STAT:-/sys/block/nvme0n1/stat}; UP=${M5_UPTIME:-/proc/uptime}
: "${THRESH_MIB:=24}" "${WIN:=60}" "${WAIT:=20}"
[ -r /etc/default/m5pro-settle ] && . /etc/default/m5pro-settle
burst=1
now=$(date +%s); cur=$(awk '{print $7}' "$DEV" 2>/dev/null); up=$(awk '{print int($1)}' "$UP" 2>/dev/null)
if [ -n "$cur" ] && [ -n "$up" ] && [ "$up" -ge $((WIN + 15)) ] && [ -r "$S" ]; then
    base=$(awk -v lim=$((now - WIN)) '$1 >= lim {print $2; exit}' "$S")
    if [ -n "$base" ]; then
        d=$(( (cur - base) / 2048 ))                       # 512-byte sectors -> MiB
        echo "<5>m5pro-settle: $d MiB written in the last ~${WIN} s (threshold $THRESH_MIB)" 2>/dev/null > /dev/kmsg
        [ "$d" -lt "$THRESH_MIB" ] && burst=0
    fi
fi
[ "$burst" = 1 ] && sleep "$WAIT"
exit 0
