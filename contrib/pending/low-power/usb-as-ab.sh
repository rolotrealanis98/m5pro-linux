#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# usb-as-ab.sh - USB runtime autosuspend A-B-A on idle peripherals (the classes the power-usb-autosuspend rule covers):
# billboard devices (no driver), r8152 Ethernet, usb-storage. Root. Leaves them as they were.
set -u
export LC_ALL=C
P=$(for l in /sys/class/hwmon/hwmon*/power*_label; do [ "$(cat "$l")" = "Total System Power" ] && echo "${l%_label}_input"; done | head -1)
DEVS=()
for d in /sys/bus/usb/devices/[0-9]*-*; do
    [ -e "$d/power/control" ] || continue
    case "$d" in *:*) continue ;; esac
    drv=$(for i in "$d"/"$(basename "$d")":*; do [ -L "$i/driver" ] && basename "$(readlink "$i/driver")"; done | sort -u | tr '\n' ' ')
    cls=$(cat "$d/bDeviceClass")
    if [ "$cls" = 11 ] || [ -z "$drv" ] || [[ " $drv " == *" r8152 "* ]] || [[ " $drv " == *" usb-storage "* ]]; then
        [[ " $drv " == *" usbhid "* || " $drv " == *" snd-usb-audio "* || " $drv " == *" hub "* ]] && continue
        DEVS+=("$d")
    fi
done
declare -A OLD; for d in "${DEVS[@]}"; do OLD[$d]=$(cat "$d/power/control"); done
restore() { for d in "${DEVS[@]}"; do echo "${OLD[$d]}" > "$d/power/control"; done; }
trap restore EXIT
med() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
phase() { local f=/var/tmp/power1/usbas.$1; : > $f; for i in $(seq 1 "$2"); do cat "$P" >> $f; sleep 1; done
          echo "$1: PSTR median $(med < $f | awk '{printf "%.0f", $1/1000}') mW; states: $(for d in "${DEVS[@]}"; do printf '%s=%s ' "$(basename "$d")" "$(cat "$d/power/runtime_status")"; done)"; }
echo "devices: ${DEVS[*]##*/}"
phase off-1 30
for d in "${DEVS[@]}"; do echo auto > "$d/power/control"; done; sleep 5
phase auto 30
restore; sleep 5
phase off-2 30
