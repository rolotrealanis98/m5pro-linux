#!/bin/bash
# SPDX-License-Identifier: MIT
# firstboot-probe - one line per boot that says which kind of fallback it was. Runs on the
# Studio. Call it right after ssh comes back:
#
#   T=$(date +%s); ssh ... 'systemctl reboot'; ...wait for ssh...; firstboot-probe.sh "$T" [CLEAN_BASE]
#   env: HOST=root@<macbook>  SSHO="-i ~/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes"
#
# delta = kernel start (Studio clock minus the MacBook's uptime) minus the moment the reboot was
# sent. The bands are relative to CLEAN_BASE, the delta of a clean reboot measured with the same
# script (env CLEAN_BASE or the second argument, default 50 s). With slot=fallback-after-failure:
#   delta <= base+8        first pass: the session that ran the reboot was counted as failed (a
#                          "counted restart", error stage 00) and the new boot.bin was never read
#   base+9  .. base+27     attempt, m1n1 exception/panic (it reboots at once)
#   base+28 .. base+47     attempt, Linux panic in its first seconds + CONFIG_PANIC_TIMEOUT=10
#   base+48 .. base+142    attempt, Linux froze after apple_wdt probed (30 s bite)
#   >= base+143            attempt, the stage-1 watchdog (hang before Linux took it over)
# Old absolute bands (2026-11-07, clean 21-29 s, before the 20 s m5pro-settle shutdown hook):
#   <= 35 first pass, 36-54 m1n1 reboot, 55-74 Linux panic, 75-169 apple_wdt, >= 170 stage-1 wdt.
# With the settle hook and the loops' "sync; sleep 5", those absolute bands called a counted
# restart (delta 55 s, e03be5ac on 2026-11-08) "attempt-linux-panic".
# Calibration, 2026-11-08 (~/Work/agents/daily-dcp/loop/run-dcp-bisect*.log, run-dcp-round4.log;
# settle hook installed, esp-put 60 s settle, then "sync; sleep 5; systemctl reboot"):
#   clean                      48, 49, 49, 49, 50, 50, 50, 51 s  -> CLEAN_BASE 50
#   counted restart (pmu 300100, error stage 00)        55 s          (base+5)
#   stage-1 watchdog (pmu 300130, error stage 30)       207-209 s     (base+157..159)
# Reset -> kernel start of the next boot is 22-26 s (sysrq-c panic, crashlog run-pram.log), so a
# Linux panic band starts about 35 s above a clean boot, a counted restart sits within +8 s.
# pmu = boot_stage, error|panic<<4, error stage. Error stage 00 = died in its own orderly
# restart; 30 = while iBoot/m1n1/Linux ran; 31/32 = in the chainloaded slot before Linux took
# over (0017 with chainload.stage-mark=1).
set -u
T0=${1:?reboot epoch (date +%s when the reboot was sent)}
BASE=${2:-${CLEAN_BASE:-50}}
HOST=${HOST:?set HOST=root@<macbook>}
read -r -a O <<< "${SSHO:--i $HOME/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8}"
line=$(ssh "${O[@]}" "$HOST" 'up=$(cut -d" " -f1 /proc/uptime)
r() { tr -d "\0" < /proc/device-tree/chosen/$1 2>/dev/null; }
u=$(nvme smart-log /dev/nvme0 2>/dev/null | awk -F: "/unsafe_shutdowns/{gsub(/[ ,]/,\"\",\$2); print \$2}")
b=$(sha256sum /boot/m1n1/boot.bin 2>/dev/null | cut -c1-8)
echo "$up|$(r m5pro,boot-slot)|$(r m5pro,pmu-scrpad)|$(r m5pro,stage1)|${u:-?}|${b:-unmounted}|$(uname -r)"')
now=$(date +%s)
IFS='|' read -r up slot pmu s1 uns bb kver <<< "$line"
delta=$(awk -v n="$now" -v u="$up" -v t="$T0" 'BEGIN{printf "%d", n-u-t}')
kind=clean
case "$slot" in
*after-failure)
    r=$(( delta - BASE ))
    if   [ "$r" -le 8 ];   then kind=first-pass
    elif [ "$r" -le 27 ];  then kind=attempt-m1n1-reboot
    elif [ "$r" -le 47 ];  then kind=attempt-linux-panic
    elif [ "$r" -le 142 ]; then kind=attempt-apple-wdt-bite
    else kind=attempt-stage1-watchdog; fi ;;
"") kind=unknown-slot ;;
esac
echo "probe $(date -u +%H:%M:%S) delta=${delta}s base=${BASE}s slot=${slot:-?} pmu=${pmu:-?} kind=$kind unsafe_shutdowns=$uns boot.bin=$bb kernel=$kver${s1:+ stage1=$s1}"
