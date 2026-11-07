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
#   delta <= 32 s    first pass: the session that ran the reboot was counted as failed and the
#                    new boot.bin was never read on this boot
#   32-150 s         the primary was attempted and reset early (m1n1 exception/panic reboots at
#                    once; a kernel freeze after apple_wdt probes bites within 30 s)
#   > 150 s          the stage-1 watchdog (hang before Linux took it over)
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
    if   [ "$delta" -le 32 ];  then kind=first-pass
    elif [ "$delta" -le 150 ]; then kind=attempt-reset-early
    else kind=watchdog; fi ;;
"") kind=unknown-slot ;;
esac
echo "probe $(date -u +%H:%M:%S) delta=${delta}s slot=${slot:-?} pmu=${pmu:-?} kind=$kind unsafe_shutdowns=$uns boot.bin=$bb kernel=$kver${s1:+ stage1=$s1}"
