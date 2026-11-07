#!/bin/bash
# SPDX-License-Identifier: MIT
# firstboot-probe - one line per boot that says which kind of fallback it was. Runs on the
# Studio. Call it right after ssh comes back:
#
#   T=$(date +%s); ssh ... 'systemctl reboot'; ...wait for ssh...; firstboot-probe.sh "$T"
#   env: HOST=root@<macbook>  SSHO="-i ~/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes"
#
# delta = kernel start (Studio clock minus the MacBook's uptime) minus the moment the reboot was
# sent. A clean reboot measured 21-27 s on 2026-11-07. With slot=fallback-after-failure:
#   delta <= 35 s    first pass: the session that ran the reboot was counted as failed and the
#                    new boot.bin was never read on this boot
#   36-54 s          attempt, m1n1 exception/panic (it reboots at once)
#   55-74 s          attempt, Linux panic in its first seconds + CONFIG_PANIC_TIMEOUT=10
#   75-169 s         attempt, Linux froze after apple_wdt probed (30 s bite)
#   >= 170 s         attempt, the stage-1 watchdog (hang before Linux took it over)
# Calibration: reset -> kernel start of the next boot is 22-26 s (sysrq-c panic, crashlog
# run-pram.log); a clean reboot is 21-29 s depending on the script.
# pmu = boot_stage, error|panic<<4, error stage. Error stage 00 = died in its own orderly
# restart; 30 = while iBoot/m1n1/Linux ran; 31/32 = in the chainloaded slot before Linux took
# over (0017 with chainload.stage-mark=1).
set -u
T0=${1:?reboot epoch (date +%s when the reboot was sent)}
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
    if   [ "$delta" -le 35 ];  then kind=first-pass
    elif [ "$delta" -le 54 ];  then kind=attempt-m1n1-reboot
    elif [ "$delta" -le 74 ];  then kind=attempt-linux-panic
    elif [ "$delta" -le 169 ]; then kind=attempt-apple-wdt-bite
    else kind=attempt-stage1-watchdog; fi ;;
"") kind=unknown-slot ;;
esac
echo "probe $(date -u +%H:%M:%S) delta=${delta}s slot=${slot:-?} pmu=${pmu:-?} kind=$kind unsafe_shutdowns=$uns boot.bin=$bb kernel=$kver${s1:+ stage1=$s1}"
