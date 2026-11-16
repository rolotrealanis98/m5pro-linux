#!/bin/bash
# next3-check.sh: one bounded, non-interactive, silent regression pass for j716s-next3. Run as root after boot.
# Output: /var/tmp/next3/<ts>/ (summary.txt first). Never plays audio; the sleep is a 30 s s2idle with the WD0 wake timer.
OUT=/var/tmp/next3/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"; SUM=$OUT/summary.txt
WAKE=/sys/module/apple_wdt/parameters/s2idle_wake_s; FB=/sys/module/apple_wdt/parameters/s2idle_fallback_s
sum() { echo "$*" | tee -a "$SUM"; }
run() { local l=$1; shift; { echo "### $*"; timeout ${TMO:-30} bash -c "$*" 2>&1; echo "rc=$?"; } > "$OUT/$l.txt"; }
rd() { cat "$1" 2>/dev/null | tr -d '\0'; }
trap 'echo 0 > $WAKE 2>/dev/null; echo none > /sys/power/pm_test 2>/dev/null' EXIT

health() {  # label
  local l=$1 f=$OUT/health-$1.txt
  {
  echo "--- kernel $(uname -r) slot $(rd /proc/device-tree/chosen/m5pro,boot-slot) cmdline: $(cat /proc/cmdline)"
  echo "--- cpus: nproc $(nproc) online $(rd /sys/devices/system/cpu/online)"
  echo "--- display"; for c in /sys/class/drm/card*-eDP-*; do echo "$c status=$(rd $c/status) enabled=$(rd $c/enabled)"; timeout 5 cat $c/modes 2>/dev/null | head -3; echo "vrr_capable=$(rd $c/vrr_capable)"; done
  for p in /sys/kernel/debug/dri/*/state; do timeout 5 grep -E "vrr|mode:|refresh" "$p" 2>/dev/null | head -8; done
  echo "--- gpu"; command ls /dev/dri 2>/dev/null | tr '\n' ' '; echo
  echo "--- wifi"; ip -br link show 2>/dev/null | grep -E '^(wl|wlan)'; iw dev 2>/dev/null | grep -E 'Interface|ssid|type' | head -4
  echo "--- bt"; timeout 8 bluetoothctl show 2>/dev/null | grep -E 'Controller|Powered' | head -3; command ls /sys/class/bluetooth 2>/dev/null
  echo "--- usb"; timeout 5 lsusb -t 2>/dev/null
  echo "  speeds: $(for d in /sys/bus/usb/devices/*/speed; do echo -n "$(basename $(dirname $d))=$(cat $d) "; done)"
  echo "  superspeed: $(grep -lE '^(5000|10000|20000)$' /sys/bus/usb/devices/*/speed 2>/dev/null | sed 's|/speed||; s|.*/||' | tr '\n' ' ')"
  for t in /sys/class/typec/port?; do [ -d "$t" ] && echo "  $(basename $t): data $(rd $t/data_role) power $(rd $t/power_role)"; done
  echo "--- pci"; timeout 8 lspci -nn 2>/dev/null | grep -E "1a00|Apollo|JHL|Thunderbolt|Intel|Apple" | head -20
  echo "--- thunderbolt"; for d in /sys/bus/thunderbolt/devices/*; do [ -e "$d" ] && echo "  $(basename $d) $(rd $d/device_name) gen=$(rd $d/generation) rx=$(rd $d/rx_speed) tx=$(rd $d/tx_speed) auth=$(rd $d/authorized)"; done
  echo "--- audio (listed only)"; cat /proc/asound/cards 2>/dev/null
  echo "--- cpufreq"; for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "  $(basename $p): cur=$(rd $p/scaling_cur_freq) min=$(rd $p/scaling_min_freq) max=$(rd $p/scaling_max_freq) gov=$(rd $p/scaling_governor) park=$(rd $p/park_stats)"; done
  echo "--- cpuidle"; for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do echo "  $(basename $s) $(rd $s/name) usage=$(rd $s/usage) time=$(rd $s/time)"; done
  } > "$f" 2>&1
}

sum "next3-check start $(date) kernel $(uname -r)"
sum "slot: $(rd /proc/device-tree/chosen/m5pro,boot-slot)"
sum "loader log (aura phram): $(for n in $(awk -F: '/aura_stage/ {print $1}' /proc/mtd); do tr -d '\000' < /dev/mtdblock${n#mtd}; done 2>/dev/null | grep -a -E 'version|1\.0\.0|SMP: installed|speaker|USB: T6050' | head -6 | tr '\n' '|')"
sum "speaker id (/chosen/asahi,speaker-id): $(od -An -tx1 /proc/device-tree/chosen/asahi,speaker-id 2>/dev/null | tr -s ' ')"
health boot
grep -E 'nproc|enabled|vrr|renderD|wl|Powered|superspeed|1a00|N-|gen=' "$OUT/health-boot.txt" | sed 's/^/  boot: /' | tee -a "$SUM"

run dmesg-boot-errors "dmesg -l err,crit,alert,emerg | head -80"
run dmesg-boot-warn "dmesg -l warn | head -60"
run gpu-dmesg "dmesg | grep -iE 'asahi|aurora|initdata|gpu|agx' | head -50"
run modules "lsmod | grep -iE 'thunderbolt|usb4|snd|asahi|appledrm|apple_wdt|brcm|btbcm|cpufreq|clpc'; modprobe -n -v thunderbolt_net thunderbolt_apple 2>&1; modinfo -F filename thunderbolt_net thunderbolt_apple thunderbolt"
run vulkan "command -v vulkaninfo >/dev/null && vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName|apiVersion' | head -4"
run wifi-ping "ping -c 3 -W 2 \$(ip route | awk '/default/ {print \$3; exit}')"
TMO=300 run sgv2-verify "/root/audio-j716/speakerguardd-v2/sgv2-silent-check.sh verify"
run sgv2-state "systemctl is-active speakerguardd 2>&1; systemctl list-units --no-legend 'speakerguard*' 2>&1; dmesg | grep -iE 'macaudio|ramp|ceiling|speaker' | head -30"
run vrr-modeset "dmesg | grep -iE 'vrr|fw27|panel' | head -20"
run tipc-clpc "cat /sys/kernel/debug/clpc/status 2>/dev/null; ls /sys/module/clpc/parameters 2>/dev/null; ls /sys/module/apple_soc_cpufreq/parameters 2>/dev/null; ls /sys/module/apple_sleep/parameters 2>/dev/null; cat /sys/module/apple_sleep/parameters/t6050_boot_writes 2>/dev/null"
run park-load "timeout 8 sh -c 'while :; do :; done' & sleep 8; for p in /sys/devices/system/cpu/cpufreq/policy*; do echo \$p \$(cat \$p/park_stats 2>/dev/null) cur=\$(cat \$p/scaling_cur_freq); done"
sum "--- cpufreq/cpuidle:"; grep -A12 -E '^--- cpufreq' "$OUT/health-boot.txt" | head -14 | tee -a "$SUM"

# One real s2idle, woken by the WD0 timer after 30 s; WD1 resets the machine 60 s after the wake was due if the timer fails.
if [ -e "$WAKE" ] && [ -e /sys/power/state ]; then
  echo none > /sys/power/pm_test 2>/dev/null
  echo 60 > "$FB"; echo 30 > "$WAKE"
  logger -k "next3: s2idle enter" 2>/dev/null || echo "next3: s2idle enter" > /dev/kmsg
  sync; sleep 1; t0=$(date +%s.%N); echo freeze > /sys/power/state; rc=$?; t1=$(date +%s.%N)
  echo 0 > "$WAKE"
  echo "next3: s2idle back rc=$rc" > /dev/kmsg
  sum "s2idle: rc=$rc wall $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.1f", b-a}') s (30 s timer; 31-45 s is a timer wake)"
  dmesg | awk 'index($0,"next3: s2idle enter"){p=1} p' > "$OUT/dmesg-s2idle.txt"
  grep -E 'apple-watchdog|s2idle:|PM: (suspend|resume)|woken|wakeup|timed out|failed' "$OUT/dmesg-s2idle.txt" | head -20 | sed 's/^/  /' | tee -a "$SUM"
  for f in success fail failed_suspend failed_suspend_noirq failed_resume failed_resume_noirq last_failed_dev; do echo -n "$f=$(rd /sys/power/suspend_stats/$f) "; done | sed 's/^/  stats: /' | tee -a "$SUM"; echo | tee -a "$SUM"
  sleep 8; health after-s2idle
  diff <(grep -E 'nproc|eDP|vrr|wl|Powered|superspeed|1a00|gen=|^[ 0-9]+\[' "$OUT/health-boot.txt") <(grep -E 'nproc|eDP|vrr|wl|Powered|superspeed|1a00|gen=|^[ 0-9]+\[' "$OUT/health-after-s2idle.txt") > "$OUT/health-diff.txt"
  sum "health before vs after the s2idle (empty = same): $(wc -l < "$OUT/health-diff.txt") differing lines"; sed 's/^/  /' "$OUT/health-diff.txt" | head -20 | tee -a "$SUM"
  run wifi-ping-after "ping -c 3 -W 2 \$(ip route | awk '/default/ {print \$3; exit}')"
  TMO=300 run sgv2-verify-after "/root/audio-j716/speakerguardd-v2/sgv2-silent-check.sh verify"
else
  sum "no apple_wdt.s2idle_wake_s: s2idle skipped"
fi
run dmesg-final-errors "dmesg -l err,crit,alert,emerg | head -120"
run dmesg-final-pm "dmesg | grep -iE 'stopping requests|timeout|timed out|failed to|error|WARNING|BUG|Oops' | head -80"
cp /sys/fs/pstore/* "$OUT/" 2>/dev/null
touch "$OUT/DONE"; sum "done $(date); results in $OUT"
