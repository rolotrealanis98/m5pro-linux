#!/bin/bash
# ON the MacBook as root: log memory every second; when MemAvailable < FLOOR_MB, kill the named processes and
# save /proc/meminfo, dmesg tail and the apple/gpu framebuffer lists. memwatch.sh LOG FLOOR_MB [pattern...]
LOG=$1; FLOOR=$2; shift 2
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
while true; do
  a=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  printf '%s up=%s MemAvail=%s Shmem=%s Slab=%s Vmalloc=%s Mapped=%s\n' "$(date +%T)" "$(cut -d. -f1 /proc/uptime)" "$a" \
    "$(awk '/^Shmem:/{print int($2/1024)}' /proc/meminfo)" "$(awk '/^Slab:/{print int($2/1024)}' /proc/meminfo)" \
    "$(awk '/^VmallocUsed/{print int($2/1024)}' /proc/meminfo)" "$(awk '/^Mapped/{print int($2/1024)}' /proc/meminfo)" >> "$LOG"
  if [ "$a" -lt "$FLOOR" ]; then
    echo "$(date +%T) FLOOR: MemAvailable $a MB < $FLOOR; killing: $*" >> "$LOG"
    for p in "$@"; do pkill -KILL -f "$p"; done
    { echo "== meminfo"; cat /proc/meminfo; echo "== vmstat"; grep -E "nr_|pgalloc" /proc/vmstat | head -60; echo "== dmesg tail"; dmesg | tail -n 40; echo "== fbs"; for d in /sys/kernel/debug/dri/[0-9]; do echo "-- $d"; grep -c '^framebuffer\[' $d/framebuffer 2>/dev/null; done; echo "== clients"; cat /sys/kernel/debug/dri/0/clients 2>/dev/null | head -20; } > "${LOG%.log}-floor.txt" 2>&1
    sleep 5; echo "$(date +%T) after kill: MemAvail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)" >> "$LOG"
  fi
  sleep 1
done
