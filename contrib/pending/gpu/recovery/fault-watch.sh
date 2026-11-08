#!/usr/bin/env bash
# GPU fault watcher for the MacBook (J716s). Run as root (dmesg), next to the stress load, with a kernel that carries
# gpu/faults 0001 (the cause + client lines). Nothing here changes the system.
#
#   fault-watch.sh [-o OUTDIR] [-t SECONDS]
#
# Tails the kernel log and, for every new line that names a recovery cause, a blamed queue or a client, prints it with a
# wall-clock timestamp. Counts recoveries per firmware reason and per client. On exit (SECONDS elapsed, Ctrl-C or TERM)
# writes OUTDIR/summary.txt (default /root/fault-watch-<date>/, mode 700) and prints it. OUTDIR also keeps events.log
# (the timestamped lines) and dmesg.raw (every GPU/G17 line seen, untimestamped).
#
# Lines matched (patch 0001 and the recovery patches):
#   G17: recovery snapshot gen N ...                       -> one recovery
#   G17: recovery cause gen N: <text> (firmware reason R, ...) / none recorded (...)   -> reason R (or "none")
#   G17: recovery gen N queue Q [blamed] [guilty] [cancelled]: K retained commands, client comm[tgid]   -> client
#   GPU work of a client failed ... client comm[tgid]      -> client (lost-device report, recovery patches)
set -u
OUT=; SECS=0
while getopts o:t: o; do case $o in o) OUT=$OPTARG;; t) SECS=$OPTARG;; *) sed -n 2,16p "$0"; exit 2;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
OUT=${OUT:-/root/fault-watch-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"; chmod 700 "$OUT"
EV=$OUT/events.log; RAW=$OUT/dmesg.raw; : > "$EV"; : > "$RAW"
START=$(date +%s); START_ISO=$(date '+%F %T')
UP0=$(cut -d' ' -f1 /proc/uptime)
KERNEL=$(uname -r)

declare -A REASON CLIENT BLAMED
RECOV=0; CAUSES=0; LOST=0
bump() { local -n a=$1; a[$2]=$(( ${a[$2]:-0} + 1 )); }

summary() {
  local end=$(date +%s)
  {
    echo "fault-watch summary"
    echo "kernel      $KERNEL"
    echo "cmdline     $(cat /proc/cmdline)"
    echo "window      $START_ISO .. $(date '+%F %T') ($((end - START)) s)"
    echo "recoveries  $RECOV snapshots, $CAUSES cause lines"
    echo "lost-device client reports  $LOST"
    echo "-- per reason"
    for k in "${!REASON[@]}"; do printf '%6d  %s\n' "${REASON[$k]}" "$k"; done | sort -rn
    echo "-- per client (any queue named in a recovery, or reported as failed)"
    for k in "${!CLIENT[@]}"; do printf '%6d  %s\n' "${CLIENT[$k]}" "$k"; done | sort -rn
    echo "-- per blamed client (the firmware's blamed queue)"
    for k in "${!BLAMED[@]}"; do printf '%6d  %s\n' "${BLAMED[$k]}" "$k"; done | sort -rn
    for f in /sys/module/aurora/parameters/m5_pause_timeout_us /sys/module/aurora/parameters/m5_idle_hold /sys/module/aurora/parameters/m5_idle_standby_us; do
      [ -r "$f" ] && echo "param       $(basename $f)=$(cat $f)"
    done
  } > "$OUT/summary.txt"
  cat "$OUT/summary.txt"
}
finish() { trap - INT TERM EXIT; kill "${DPID:-0}" 2>/dev/null; summary; exit 0; }
trap finish INT TERM EXIT

echo "fault-watch: $KERNEL, output $OUT, ${SECS} s (0 = until Ctrl-C)" >&2
exec 3< <(exec dmesg -w 2>/dev/null)
DPID=$!
while :; do
  if [ "$SECS" -gt 0 ] && [ $(( $(date +%s) - START )) -ge "$SECS" ]; then break; fi
  IFS= read -r -t 1 -u 3 line || { rc=$?; [ "$rc" -gt 128 ] && continue; break; }
  # skip the replayed buffer: only lines stamped after this script started
  if [[ $line =~ ^\[\ *([0-9]+)\.[0-9]+\] ]]; then [ "${BASH_REMATCH[1]}" -lt "${UP0%.*}" ] && continue; fi
  case $line in
    *"G17: recovery"*|*"GPU work of a client failed"*|*"the client sees a lost device"*) ;;
    *) continue;;
  esac
  now=$(date '+%F %T')
  printf '%s\n' "$line" >> "$RAW"
  case $line in
    *"G17: recovery snapshot"*) RECOV=$((RECOV + 1));;
    *"G17: recovery cause"*)
      CAUSES=$((CAUSES + 1))
      if [[ $line =~ firmware\ reason\ ([0-9]+) ]]; then
        r="reason ${BASH_REMATCH[1]}"
        [[ $line =~ cause\ gen\ [0-9]+:\ ([^\(]*)\( ]] && { t=${BASH_REMATCH[1]}; r="$r (${t% })"; }
      elif [[ $line == *"none recorded"* ]]; then r="none recorded (host-request path)"
      else r="unparsed"; fi
      bump REASON "$r";;
  esac
  if [[ $line =~ client\ ([^[:space:]\[]+)\[[0-9]+\] ]]; then
    cn=${BASH_REMATCH[1]}; bump CLIENT "$cn"
    if [[ $line == *"G17: recovery gen"*queue* ]]; then [[ $line == *" blamed"* ]] && bump BLAMED "$cn"; else LOST=$((LOST + 1)); fi
  fi
  case $line in *"cause gen"*|*" blamed"*|*"client "*) printf '%s  %s\n' "$now" "$line" | tee -a "$EV";; esac
done
