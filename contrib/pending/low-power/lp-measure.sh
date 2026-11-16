#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# lp-measure.sh - idle power, cpuidle, cpufreq and one s2idle cycle on the J716s (MacBook Pro 16", M5 Pro).
#
#   bash lp-measure.sh            run everything this kernel supports (detached: setsid; see below)
#
# Two kernels, one script:
#   baseline  the installed kernel (no apple_wdt.s2idle_wake_s): idle, load, pm_test s2idle steps only
#   test      the low-power branch: the same, plus idle parking on/off, the WD0 wake-timer check and a
#             real s2idle woken by the WD0 timer (WD1 resets the Mac if that wake does not come)
#
# Results: /var/tmp/lowpower/<mode>-<YYYYmmdd-HHMMSS>/ (summary.txt first), then a DONE file there.
# Bounded: every command has a timeout; the whole run takes about 25 min (test) / 8 min (baseline).
# Silent: no audio is played; cards are only listed.
set -u
export LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

MODE=baseline
[ -e /sys/module/apple_wdt/parameters/s2idle_wake_s ] && MODE=test
OUT=/var/tmp/lowpower/$MODE-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
exec > >(tee -a "$OUT/log.txt") 2>&1
SUM=$OUT/summary.txt
say() { echo "[$(date +%T)] $*"; }
sum() { echo "$*" | tee -a "$SUM"; }
kmsg() { echo "lowpower: $*" > /dev/kmsg 2>/dev/null || true; }

say "mode $MODE, kernel $(uname -r), out $OUT"

# ------------------------------------------------------------------ locate the sensors
HW_SYS=""; HW_HPC=""; HW_AC=""
for l in /sys/class/hwmon/hwmon*/power*_label; do
    [ -r "$l" ] || continue
    case "$(cat "$l")" in
        "Total System Power") HW_SYS=${l%_label}_input ;;
        "Heatpipe Power") HW_HPC=${l%_label}_input ;;
        "AC Input Power") HW_AC=${l%_label}_input ;;
    esac
done
BAT=""; ACPS=""
for p in /sys/class/power_supply/*; do
    case "$(cat "$p/type" 2>/dev/null)" in
        Battery) BAT=$p ;;
        Mains) ACPS=$p ;;
    esac
done
BL=$(command ls -d /sys/class/backlight/* 2>/dev/null | head -1)
CLPC=$(command ls -d /sys/kernel/debug/*performance-controller* 2>/dev/null | head -1)
POLICIES=$(command ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null)
NCPU=$(nproc)
rd() { cat "$1" 2>/dev/null || echo NA; }

# DVFS command registers of the three clusters (CPUs 0-5, 6-11, 12-17), read through /dev/mem: the state each
# cluster was last asked for, parked or not. The reader's own cluster is awake while it reads.
dvfs() {
    timeout 5 python3 -I - <<'PY' 2>/dev/null || echo "dvfs NA"
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
out = []
for name, base in (("mc0", 0x210e20000), ("mc1", 0x211e20000), ("pc", 0x212e20000)):
    m = mmap.mmap(fd, 0x4000, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    cmd = struct.unpack_from("<Q", m, 0x20)[0]
    out.append("%s=%d%s" % (name, cmd & 0x1f, "b" if cmd >> 31 & 1 else ""))
    m.close()
cpu = open("/proc/self/stat").read().rsplit(")", 1)[1].split()[36]
print("dvfs " + " ".join(out) + " reader_cpu=" + cpu)
PY
}

info() {
    {
        echo "cmdline: $(cat /proc/cmdline)"
        echo "boot-slot: $(tr -d '\0' < /proc/device-tree/chosen/m5pro,boot-slot 2>/dev/null)"
        echo "--- idle/WFxT boot lines"; dmesg | grep -iE 'idling in WFI|idle=nop|WFxT|wfxt|preserving registers' | head
        echo "--- cpuidle: $(rd /sys/devices/system/cpu/cpuidle/current_driver) / $(rd /sys/devices/system/cpu/cpuidle/current_governor)"
        for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
            [ -d "$s" ] && echo "  $(basename "$s"): $(rd "$s/name") lat=$(rd "$s/latency") res=$(rd "$s/residency") disable=$(rd "$s/disable")"
        done
        echo "--- cpufreq"
        for p in $POLICIES; do
            echo "  $(basename "$p"): cpus=$(rd "$p/related_cpus") drv=$(rd "$p/scaling_driver") gov=$(rd "$p/scaling_governor") min=$(rd "$p/scaling_min_freq") max=$(rd "$p/scaling_max_freq") cur=$(rd "$p/scaling_cur_freq") lat=$(rd "$p/cpuinfo_transition_latency")"
            echo "    freqs: $(rd "$p/scaling_available_frequencies") boost: $(rd "$p/scaling_boost_frequencies")"
        done
        echo "boost: $(rd /sys/devices/system/cpu/cpufreq/boost)"
        echo "idle_park: $(rd /sys/module/apple_soc_cpufreq/parameters/idle_park)"
        echo "--- cpufreq / clpc / pmc boot lines"; dmesg | grep -iE 'cpufreq|DVFS|clpc|pmc|fast.die|thermal ownership' | head -40
        echo "--- clpc: $CLPC"; [ -n "$CLPC" ] && timeout 5 cat "$CLPC/status"
        echo "platform_profile: $(rd /sys/firmware/acpi/platform_profile) choices: $(rd /sys/firmware/acpi/platform_profile_choices)"
        for d in /sys/class/platform-profile/*; do [ -d "$d" ] && echo "  $(basename "$d"): $(rd "$d/name") $(rd "$d/profile") [$(rd "$d/choices")]"; done
        echo "--- power: sys=$HW_SYS hpc=$HW_HPC ac=$HW_AC bat=$BAT mains=$ACPS bl=$BL"
        [ -n "$BAT" ] && for f in status capacity charge_behaviour power_now current_now voltage_now charge_now energy_now; do echo "  bat $f: $(rd "$BAT/$f")"; done
        [ -n "$ACPS" ] && echo "  mains online: $(rd "$ACPS/online")"
        echo "--- sleep: state=$(rd /sys/power/state) mem_sleep=$(rd /sys/power/mem_sleep) pm_test=$(rd /sys/power/pm_test)"
        echo "apple_wdt: wake=$(rd /sys/module/apple_wdt/parameters/s2idle_wake_s) fallback=$(rd /sys/module/apple_wdt/parameters/s2idle_fallback_s)"
        grep -E 'wdt|watchdog' /proc/interrupts
        echo "watchdog0: $(rd /sys/class/watchdog/watchdog0/identity) state=$(rd /sys/class/watchdog/watchdog0/state) timeout=$(rd /sys/class/watchdog/watchdog0/timeout)"
        echo "rtc: $(for r in /sys/class/rtc/rtc*; do echo -n "$(basename "$r")=$(rd "$r/name") wakealarm=$([ -e "$r/wakealarm" ] && echo y || echo n); "; done)"
        echo "wakeup-enabled: $(grep -l enabled /sys/devices/platform/*/power/wakeup /sys/devices/platform/*/*/power/wakeup 2>/dev/null | sed 's|/power/wakeup||; s|.*/||' | tr '\n' ' ')"
    } > "$OUT/info.txt" 2>&1
    cat "$OUT/info.txt"
}

# cpuidle usage/time per CPU and state, cpufreq time_in_state per policy
snap() {
    local f=$OUT/snap-$1.txt c s p fr t
    {
        for c in /sys/devices/system/cpu/cpu[0-9]*; do
            for s in "$c"/cpuidle/state*; do
                [ -d "$s" ] && echo "idle $(basename "$c") $(basename "$s") $(rd "$s/usage") $(rd "$s/time") $(rd "$s/s2idle/usage") $(rd "$s/s2idle/time")"
            done
        done
        for p in $POLICIES; do
            while read -r fr t; do echo "tis $(basename "$p") $fr $t"; done < "$p/stats/time_in_state" 2>/dev/null
            echo "trans $(basename "$p") $(rd "$p/stats/total_trans")"
            [ -r "$p/park_stats" ] && echo "park $(basename "$p") $(awk '{print $2, $4}' "$p/park_stats")"
        done
    } > "$f"
}

# Differences between two snaps: per state usage and residency summed over all CPUs; per policy time in state
snapdiff() {
    awk -v a="$OUT/snap-$1.txt" -v lbl="$2" '
        BEGIN { while ((getline l < a) > 0) { split(l, x, " "); if (x[1] == "trans") { tr0[x[2]] = x[3]; continue }
                if (x[1] == "park") { pk0[x[2]] = x[3]; pm0[x[2]] = x[4]; continue }
                k = x[1] " " x[2] " " x[3]; u[k] = x[4]; t[k] = x[5]; su[k] = x[6]; st[k] = x[7] } }
        $1 == "idle" { k = $1 " " $2 " " $3; du[$3] += $4 - u[k]; dt[$3] += $5 - t[k]; dsu[$3] += $6 - su[k]; dst[$3] += $7 - st[k] }
        $1 == "tis" { k = $1 " " $2 " " $3; d = $4 - u[k]; if (d > 0) tis[$2] = tis[$2] sprintf(" %d:%.2fs", $3 / 1000, d / 100) }
        $1 == "trans" { tr[$2] = $3 - tr0[$2] }
        $1 == "park" { pk[$2] = sprintf("%d parks, parked %.1f s", $3 - pk0[$2], ($4 - pm0[$2]) / 1000) }
        END {
            for (s in du) printf "%s cpuidle %s: entries %d, residency %.1f s (all CPUs), s2idle entries %d, s2idle %.1f s\n", lbl, s, du[s], dt[s] / 1e6, dsu[s], dst[s] / 1e6
            for (p in tis) printf "%s cpufreq %s: transitions %d, MHz:time%s\n", lbl, p, tr[p], tis[p]
            for (p in pk) printf "%s park %s: %s\n", lbl, p, pk[p]
        }' "$OUT/snap-$3.txt" | sort
}

sample_line() {
    local now sys hpc ac bp bc bv fr=""
    now=$(date +%s.%N | cut -c1-14)
    sys=$(rd "$HW_SYS"); hpc=$(rd "$HW_HPC"); ac=$(rd "$HW_AC")
    bp=$(rd "$BAT/power_now"); bc=$(rd "$BAT/current_now"); bv=$(rd "$BAT/voltage_now")
    for p in $POLICIES; do fr="$fr $(rd "$p/scaling_cur_freq")"; done
    echo "$now $sys $hpc $ac $bp $bc $bv$fr"
}

# Samples the sensors every second for $2 s; averages in the summary.
window() {
    local lbl=$1 secs=$2 f=$OUT/power-$1.txt i
    echo "# t sys_uW hpc_uW ac_uW bat_power_uW bat_current_uA bat_voltage_uV cur_kHz_per_policy" > "$f"
    echo "dpms-before: $(cat /sys/class/drm/card*-eDP-*/dpms 2>/dev/null | tr '\n' ' ') bl=$(rd "$BL/actual_brightness")" > "$OUT/dvfs-$lbl.txt"
    snap "$lbl-a"
    head -1 /proc/stat > "$OUT/stat-$lbl-a.txt"; cp /proc/interrupts "$OUT/irqw-$lbl-a.txt"
    for i in $(seq 1 "$secs"); do
        sample_line >> "$f"
        [ $((i % 10)) = 5 ] && dvfs >> "$OUT/dvfs-$lbl.txt"
        [ "$i" = $((secs / 2)) ] && timeout 5 top -b -n 1 -w 200 2>/dev/null | head -22 > "$OUT/top-$lbl.txt"
        sleep 1
    done
    head -1 /proc/stat > "$OUT/stat-$lbl-b.txt"; cp /proc/interrupts "$OUT/irqw-$lbl-b.txt"
    [ -n "$CLPC" ] && timeout 5 cat "$CLPC/status" > "$OUT/clpc-$lbl.txt" 2>&1
    snap "$lbl-b"
    echo "dpms-after: $(cat /sys/class/drm/card*-eDP-*/dpms 2>/dev/null | tr '\n' ' ')" >> "$OUT/dvfs-$lbl.txt"
    awk -v lbl="$lbl" '!/^#/ { n++; s += $2; h += $3; a += $4; if ($5 != "NA") { b += $5; nb++ } if ($6 != "NA" && $7 != "NA") { iv += $6 * $7 / 1e6; ni++ }
                       for (k = 8; k <= NF; k++) f[k] += $k; nf = NF }
        END { printf "%s (%d s): system %.3f W, heatpipe %.3f W, AC in %.3f W, battery power_now %.3f W, current*voltage %.3f W", lbl, n, s / n / 1e6, h / n / 1e6, a / n / 1e6, nb ? b / nb / 1e6 : 0, ni ? iv / ni / 1e6 : 0
              printf ", mean cur MHz:"; for (k = 8; k <= nf; k++) printf " %d", f[k] / n / 1000; printf "\n" }' "$f" | tee -a "$SUM"
    awk '/^dvfs/ { for (k = 2; k <= 4; k++) { split($k, x, "="); c[x[1]] = c[x[1]] " " x[2] } } END { for (n in c) printf "  dvfs %s:%s\n", n, c[n] }' "$OUT/dvfs-$lbl.txt" | sort | tee -a "$SUM"
    grep dpms "$OUT/dvfs-$lbl.txt" | tr '\n' ' ' | sed 's/^/  /' | tee -a "$SUM"; echo | tee -a "$SUM"
    snapdiff "$lbl-a" "  $lbl" "$lbl-b" | tee -a "$SUM"
    paste "$OUT/stat-$lbl-a.txt" "$OUT/stat-$lbl-b.txt" | awk '{ n = (NF - 2) / 2; for (k = 2; k <= n + 1; k++) { d = $(k + n + 1) - $k; t += d; if (k == 5 || k == 6) idle += d } printf "  cpu busy %.1f %% of 18 CPUs\n", 100 * (t - idle) / t }' | tee -a "$SUM"
    awk 'NR == FNR { if (FNR > 1) { v = 0; for (k = 2; k <= 19; k++) v += $k; a[$1] = v } next }
         FNR > 1 { v = 0; for (k = 2; k <= 19; k++) v += $k; d = v - a[$1]; if (d > 0) { $1 = $1; printf "%d %s %s\n", d, $1, $NF } }' "$OUT/irqw-$lbl-a.txt" "$OUT/irqw-$lbl-b.txt" | sort -rn | head -6 | sed 's/^/  irqs: /' | tee -a "$SUM"
    grep -E 'last_vote|host_gpu' "$OUT/clpc-$lbl.txt" 2>/dev/null | sed 's/^/  clpc: /' | tee -a "$SUM"
    sed -n '8,12p' "$OUT/top-$lbl.txt" 2>/dev/null | cut -c1-120 | sed 's/^/  top: /' | tee -a "$SUM"
}

# ------------------------------------------------------------------ restore on exit
BL_OLD=""; CB_OLD=""; PARK_OLD=""
restore() {
    [ -n "$BL_OLD" ] && echo "$BL_OLD" > "$BL/brightness" 2>/dev/null
    [ -n "$CB_OLD" ] && echo "$CB_OLD" > "$BAT/charge_behaviour" 2>/dev/null
    [ -n "$PARK_OLD" ] && echo "$PARK_OLD" > /sys/module/apple_soc_cpufreq/parameters/idle_park 2>/dev/null
    [ -n "${GPU_OLD:-}" ] && echo "$GPU_OLD" > /sys/module/clpc/parameters/gpu_floor 2>/dev/null
    [ -e /sys/module/sn201202x/parameters/s2idle_spmi_sleep ] && echo Y > /sys/module/sn201202x/parameters/s2idle_spmi_sleep 2>/dev/null
    [ -e /sys/module/apple_wdt/parameters/s2idle_wake_s ] && echo 0 > /sys/module/apple_wdt/parameters/s2idle_wake_s 2>/dev/null
    echo none > /sys/power/pm_test 2>/dev/null
    true
}
trap 'restore; say "restored"' EXIT

info
sum "mode $MODE kernel $(uname -r) slot $(tr -d '\0' < /proc/device-tree/chosen/m5pro,boot-slot 2>/dev/null)"
sum "sensors: system=${HW_SYS:-none} heatpipe=${HW_HPC:-none} battery=${BAT:-none} AC online=$(rd "$ACPS/online") battery $(rd "$BAT/capacity")% $(rd "$BAT/status")"

# Fixed brightness: half the maximum
if [ -n "$BL" ]; then
    BL_OLD=$(cat "$BL/brightness"); echo $(( $(cat "$BL/max_brightness") / 2 )) > "$BL/brightness"
    sum "backlight $(basename "$BL"): $(cat "$BL/brightness")/$(cat "$BL/max_brightness") (was $BL_OLD)"
fi

# ------------------------------------------------------------------ helpers for the phases below
loadwin() {   # label seconds cpus...
    local lbl=$1 secs=$2 f=$OUT/load-$1.txt c i; shift 2
    for c in "$@"; do taskset -c "$c" timeout "$secs" sh -c 'while :; do :; done' & done
    echo "# t sys_uW hpc_uW ac_uW bat_power_uW bat_current_uA bat_voltage_uV cur_kHz_per_policy" > "$f"
    for i in $(seq 1 $((secs * 2))); do sample_line >> "$f"; sleep 0.5; done
    wait
    for i in 1 2 3 4 5 6; do sleep 0.5; sample_line >> "$f"; done
    { echo "$lbl: last loaded sample and the samples after it:"; tail -8 "$f" | sed 's/^/  /'; } | tee -a "$SUM"
    dvfs | sed 's/^/  after: /' | tee -a "$SUM"
}

health() {
    local lbl=$1 gw
    {
        echo "=== $lbl"
        echo "--- display"; for c in /sys/class/drm/card*-*; do [ -d "$c" ] && echo "  $(basename "$c"): $(rd "$c/status") $(rd "$c/enabled") dpms=$(rd "$c/dpms")"; done
        echo "  backlight: $(rd "$BL/actual_brightness")/$(rd "$BL/max_brightness")"
        echo "--- wifi"; ip -br addr 2>/dev/null; for n in /sys/class/net/wl*; do [ -d "$n" ] && echo "  $(basename "$n"): $(rd "$n/operstate")"; done
        gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
        [ -n "$gw" ] && timeout 10 ping -c 3 -W 2 "$gw" | tail -2
        echo "--- bluetooth"; command ls /sys/class/bluetooth 2>/dev/null; timeout 5 rfkill list 2>/dev/null
        command -v bluetoothctl >/dev/null && timeout 5 bluetoothctl show 2>/dev/null | grep -E 'Controller|Powered'
        echo "--- usb"; timeout 5 lsusb 2>/dev/null; echo "  devices: $(command ls /sys/bus/usb/devices 2>/dev/null | wc -l)"
        echo "  superspeed: $(grep -lE '^(5000|10000|20000)$' /sys/bus/usb/devices/*/speed 2>/dev/null | sed 's|/speed||; s|.*/||' | tr '\n' ' ')"
        for t in /sys/class/typec/port*; do [ -d "$t" ] && echo "  $(basename "$t"): data $(rd "$t/data_role") power $(rd "$t/power_role") partner $([ -d "$t/$(basename "$t")-partner" ] && echo yes || echo no) dev $(basename "$(readlink -f "$t/device")") $(rd "$t/device/of_node/connector/label" | tr -d '\0')"; done
        for r in /sys/kernel/debug/usb/tipd/*/regs; do [ -r "$r" ] && { echo "  tipd $(basename "$(dirname "$r")"):"; timeout 5 cat "$r" | sed 's/^/    /'; }; done
        timeout 5 lsusb -t 2>/dev/null
        echo "--- pci"; echo "  pci devices: $(timeout 5 lspci 2>/dev/null | wc -l)"; timeout 5 lspci 2>/dev/null
        echo "--- audio (listed only)"; cat /proc/asound/cards 2>/dev/null
        echo "--- gpu"; command ls /dev/dri 2>/dev/null | tr '\n' ' '; echo
        command -v vulkaninfo >/dev/null && timeout 20 vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName|apiVersion' | head -4
        [ -n "$CLPC" ] && timeout 5 cat "$CLPC/status"
        echo "--- cpufreq"; for p in $POLICIES; do echo "  $(basename "$p"): cur=$(rd "$p/scaling_cur_freq") gov=$(rd "$p/scaling_governor")"; done
        echo "--- power: system $(rd "$HW_SYS") uW, battery $(rd "$BAT/power_now") uW"
    } > "$OUT/health-$lbl.txt" 2>&1
}

s2idle_cycle() {   # label pm_test wake_s fallback_s
    local lbl=$1 t=$2 w=$3 fb=$4 rc t0 t1 mark
    mark="s2idle $lbl (pm_test=$t wake=$w fallback=$fb)"
    snap "s2-$lbl-a"; cp /proc/interrupts "$OUT/irq-$lbl-a.txt"
    local ch0=$(rd "$BAT/charge_now") en0=$(rd "$BAT/energy_now") bp0=$(rd "$BAT/power_now")
    if [ -e /sys/power/pm_test ]; then
        echo "$t" > /sys/power/pm_test || { sum "$lbl: pm_test=$t refused"; return 1; }
    elif [ "$t" != none ]; then
        sum "$lbl: no /sys/power/pm_test (CONFIG_PM_DEBUG): skipped"; return 1
    fi
    if [ "$w" -gt 0 ]; then
        echo "$fb" > /sys/module/apple_wdt/parameters/s2idle_fallback_s
        echo "$w" > /sys/module/apple_wdt/parameters/s2idle_wake_s
    fi
    kmsg "$mark: enter"; sync; sleep 1
    t0=$(date +%s.%N)
    echo freeze > /sys/power/state; rc=$?
    t1=$(date +%s.%N)
    kmsg "$mark: back rc=$rc"
    [ -e /sys/module/apple_wdt/parameters/s2idle_wake_s ] && echo 0 > /sys/module/apple_wdt/parameters/s2idle_wake_s
    [ -e /sys/power/pm_test ] && echo none > /sys/power/pm_test
    local ch1=$(rd "$BAT/charge_now") en1=$(rd "$BAT/energy_now") bp1=$(rd "$BAT/power_now")
    echo "$lbl $t0 $t1 $ch0 $ch1 $en0 $en1 $bp0 $bp1" >> "$OUT/sleeps.txt"
    snap "s2-$lbl-b"; cp /proc/interrupts "$OUT/irq-$lbl-b.txt"
    dmesg | awk -v m="lowpower: $mark: enter" 'index($0, m) { p = 1 } p' > "$OUT/dmesg-$lbl.txt"
    sum "$lbl: rc=$rc, $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') s wall, wakeup irq $(rd /sys/power/pm_wakeup_irq), charge $ch0 -> $ch1 uAh, energy $en0 -> $en1 uWh"
    grep -E 'apple-watchdog|s2idle:|PM: (suspend|resume)|Freezing|Restarting|wakeup|woken|Wakeup' "$OUT/dmesg-$lbl.txt" | head -15 | sed 's/^/  /' | tee -a "$SUM"
    grep -ciE 'error|fail|timed? ?out|WARNING|Oops|BUG' "$OUT/dmesg-$lbl.txt" | sed 's/^/  dmesg error-like lines: /' | tee -a "$SUM"
    snapdiff "s2-$lbl-a" "  $lbl" "s2-$lbl-b" | grep cpuidle | tee -a "$SUM"
    for f in success fail failed_freeze failed_suspend failed_suspend_noirq failed_resume failed_resume_noirq last_failed_dev last_failed_step; do
        echo -n "$f=$(rd /sys/power/suspend_stats/$f) "; done | sed 's/^/  stats: /' | tee -a "$SUM"; echo | tee -a "$SUM"
    sleep 5
    health "$lbl"
    grep -E 'card.*eDP|wl.*:|Powered|devices:|pci devices:|superspeed:|port[0-9]: data|^ *[0-9] \[|deviceName|loss' "$OUT/health-$lbl.txt" | sed 's/^/  /' | tee -a "$SUM"
}

# Battery charge and energy every 5 s for $2 s, on whatever carries the system now.
batwin() {
    local lbl=$1 secs=$2 f=$OUT/bat-$1.txt i
    echo "# t charge_uAh energy_uWh power_uW current_uA voltage_uV ac_uW sys_uW" > "$f"
    for i in $(seq 0 5 "$secs"); do
        echo "$(date +%s.%N | cut -c1-14) $(rd "$BAT/charge_now") $(rd "$BAT/energy_now") $(rd "$BAT/power_now") $(rd "$BAT/current_now") $(rd "$BAT/voltage_now") $(rd "$HW_AC") $(rd "$HW_SYS")" >> "$f"
        [ "$i" -lt "$secs" ] && sleep 5
    done
    awk -v lbl="$lbl" '!/^#/ { n++; if (n == 1) { t0 = $1; c0 = $2; e0 = $3 } t1 = $1; c1 = $2; e1 = $3; p += $4; a += $7; s += $8 }
        END { d = t1 - t0; printf "%s (%.0f s on %s): power_now %.3f W, AC in %.3f W, system %.3f W; charge %d -> %d uAh, energy %d -> %d uWh = %.3f W from the energy\n",
              lbl, d, (a / n < 1e6 ? "battery" : "charger"), p / n / 1e6, a / n / 1e6, s / n / 1e6, c0, c1, e0, e1, (d > 0 ? (e0 - e1) * 0.0036 / d : 0) }' "$f" | tee -a "$SUM"
}

# ------------------------------------------------------------------ 1. boot state of the Type-C ports and USB
health boot
grep -E 'superspeed:|port[0-9]: data|devices:' "$OUT/health-boot.txt" | sed 's/^/  boot: /' | tee -a "$SUM"

# ------------------------------------------------------------------ 2. idle
kmsg "idle windows"
say "settling 20 s"; sleep 20
PARKP=/sys/module/apple_soc_cpufreq/parameters/idle_park
GPUP=/sys/module/clpc/parameters/gpu_floor
GPU_OLD=""
if [ -e "$PARKP" ]; then
    # Parking on/off twice, A B B A, so that drift and noise show against the difference.
    PARK_OLD=$(cat "$PARKP")
    echo Y > "$PARKP"; window idle-park-1 60
    echo N > "$PARKP"; window idle-nopark-1 60
    echo N > "$PARKP"; window idle-nopark-2 60
    echo Y > "$PARKP"; window idle-park-2 60
else
    window idle 60
fi
if [ -e "$GPUP" ]; then
    GPU_OLD=$(cat "$GPUP")
    echo N > "$GPUP"; window idle-nogpufloor 60
    echo Y > "$GPUP"; window idle-gpufloor 60
    echo "$GPU_OLD" > "$GPUP"
fi
if [ -n "$BAT" ] && grep -q force-discharge "$BAT/charge_behaviour" 2>/dev/null; then
    CB_OLD=$(sed -n 's/.*\[\([a-z-]*\)\].*/\1/p' "$BAT/charge_behaviour")
fi

# ------------------------------------------------------------------ 3. load
kmsg "load"
loadwin single-p 5 12
loadwin single-m 5 0
loadwin all 10 $(seq 0 $((NCPU - 1)))
dmesg | grep -iE 'DVFS|cpufreq' | tail -5 | sed 's/^/  dmesg: /' | tee -a "$SUM"

# ------------------------------------------------------------------ 3b. Type-C data role probe (before the sleeps, which can lose the partner; SWDF may wedge the controller)
# A port with a partner that reads [device] (the PD-level UFP) while USB2 runs as host: ask for host once
# (DR_Swap through SWDF) and see whether its SuperSpeed side appears.
for t in /sys/class/typec/port*; do
    [ -d "$t/$(basename "$t")-partner" ] || continue
    grep -q '\[device\]' "$t/data_role" 2>/dev/null || continue
    sum "$(basename "$t") is [device] with a partner: requesting host"
    kmsg "$(basename "$t") data_role host"
    timeout 15 sh -c "echo host > $t/data_role"; sum "  write rc=$?"
    sleep 8
    health "drswap-$(basename "$t")"
    grep -E 'superspeed:|port[0-9]: data|devices:' "$OUT/health-drswap-$(basename "$t").txt" | sed 's/^/  after: /' | tee -a "$SUM"
    dmesg | tail -40 > "$OUT/dmesg-drswap-$(basename "$t").txt"
done

# ------------------------------------------------------------------ 4. s2idle on the charger
health before-sleep
grep -E 'superspeed:|port[0-9]: data|devices:' "$OUT/health-before-sleep.txt" | sed 's/^/  before sleep: /' | tee -a "$SUM"
kmsg "s2idle steps"
s2idle_cycle pmtest-devices devices 0 0
s2idle_cycle pmtest-platform platform 0 0
WOKE=0
if [ "$MODE" = test ]; then
    # WD0's bark status through /dev/mem, its interrupt still disabled in the kernel; WD0 never gets RESET_EN.
    timeout 15 python3 -I - <<'PY' | tee -a "$SUM"
import mmap, os, struct, time
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x4000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0x28836c000)
rd = lambda o: struct.unpack_from("<I", m, o)[0]
def wr(o, v): struct.pack_into("<I", m, o, v)
before = rd(0x0c)
wr(0x0c, 2); wr(0x00, 0); wr(0x08, 2 * 24000000); wr(0x0c, 1)
time.sleep(4)
after = rd(0x0c); cur = rd(0x00)
wr(0x0c, 2)
print("wd0 check: ctrl before %#x, after 4 s %#x (bit 1 = bark status), count %.1f s, cleared %#x -> %s"
      % (before, after, cur / 24e6, rd(0x0c), "PASS" if after & 2 else "FAIL"))
PY
    if grep -q 'wd0 check.*PASS' "$SUM"; then
        kmsg "real s2idle"
        # First with the polled Type-C controllers left awake, then as by default (SLEEP): which one loses a partner.
        if [ -e /sys/module/sn201202x/parameters/s2idle_spmi_sleep ]; then
            echo N > /sys/module/sn201202x/parameters/s2idle_spmi_sleep
            s2idle_cycle real-30s-awake none 30 60
            echo Y > /sys/module/sn201202x/parameters/s2idle_spmi_sleep
        fi
        s2idle_cycle real-30s none 30 60
        grep -q 'woken by the wake timer' "$OUT/dmesg-real-30s.txt" && WOKE=1
        [ "$WOKE" = 1 ] || sum "real-30s did not end by the wake timer: no further sleep"
    else
        sum "WD0 check failed: no real s2idle (it would end only in the WD1 reset)"
    fi
fi

# ------------------------------------------------------------------ 5. s2idle power on the battery
# The battery carries the system (force-discharge, AC in ~0.1 W). 60 s awake to settle, 60 s awake measured,
# three 150 s sleeps (WD1 reset at 175 s each) with the charge and energy read right before and after each,
# 60 s awake measured again. Drain = energy lost over the sleeps / their wall time.
if [ "$WOKE" = 1 ] && [ -n "$CB_OLD" ]; then
    kmsg "battery s2idle"
    if echo force-discharge > "$BAT/charge_behaviour" 2>/dev/null; then
        sleep 60
        batwin bat-awake-1 60
        : > "$OUT/sleeps.txt"
        for k in 1 2 3; do s2idle_cycle bat-sleep-$k none 150 25; done
        batwin bat-awake-2 60
        echo "$CB_OLD" > "$BAT/charge_behaviour"
        sum "  charge_behaviour back to $(cat "$BAT/charge_behaviour")"
        awk '/^bat-sleep/ { d += $3 - $2; de += $6 - $7; dc += $4 - $5; n++ }
            END { if (d > 0) printf "s2idle drain over %d sleeps, %.0f s: %.3f W from the energy (%d uWh), charge %d uAh\n", n, d, de * 0.0036 / d, de, dc }' "$OUT/sleeps.txt" | tee -a "$SUM"
    else
        sum "force-discharge refused: no battery s2idle number"
    fi
fi

# ------------------------------------------------------------------ 6. after everything: idle again
kmsg "idle after sleep"
window idle-after 60

dmesg > "$OUT/dmesg-full.txt"
grep -iE 'DVFS|stopping requests|clpc|apple-watchdog|pcie-apple|sn201202x|tipd|typec' "$OUT/dmesg-full.txt" | tail -60 > "$OUT/dmesg-key.txt"
restore
sum "done $(date +%T)"
touch "$OUT/DONE"
