#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# r1-local.sh v3 (2026-11-06 evening: steps a-d, --battery, USB checks fixed) - run AS ROOT AT THE LINUX CONSOLE of the J716s (16-inch MacBook Pro M5 Pro, T6050).
# No network, no tether. Collects the R1 evidence and runs the plan's active checks for one step:
#
#   bash /boot/r1-local.sh a [--quick]    R1-A  (Step 1: boot and desktop checks)
#   bash /boot/r1-local.sh b [--quick]    R1-B  (Step 2: battery with the probe trace)
#   bash /boot/r1-local.sh c [--quick]    R1-C  (Step 4: USB host DTB)
#   bash /boot/r1-local.sh d              general: passive collection plus the battery and USB
#                                         presence checks, no prompts (any payload, R2 included)
#
# --battery says "the battery driver is expected on" (no initcall_blacklist=macsmc_power...).
# Without it the script decides from /proc/cmdline: no blacklist means battery expected, and the
# battery presence checks run in every step; with the blacklist the driver is expected to be off.
# Step b always expects the battery on. Step d runs the USB checks only on the usbhost DTB.
#
# --quick skips every prompt that needs hands or eyes (keyboard-backlight question, lid, MagSafe,
# USB ports), so the script runs unattended in about a minute (step a still takes ~35 s for the
# idle wait and the three load samples).
#
# Logs go to /boot/r1-logs/r1-<step>-<YYYYmmdd-HHMM>/ (the ESP; /dev/nvme0n1p4 is mounted on /boot
# first if /boot is not a vfat mount). The last thing on screen is a framed PASS/FAIL/SKIP summary
# (also saved as summary.txt): photograph that block. The script never reboots, never writes a
# charge threshold, never touches /sys/bus/nvmem.
# shellcheck disable=SC2012  # ls on sysfs names is fine here
set -u
export LC_ALL=C

USAGE="usage: bash r1-local.sh a|b|c|d [--quick] [--battery]"
STEP=""; QUICK=0; BATTERY_OPT=0
for a in "$@"; do
    case "$a" in
        a|b|c|d|A|B|C|D) STEP=$(printf '%s' "$a" | tr 'ABCD' 'abcd') ;;
        --quick) QUICK=1 ;;
        --battery) BATTERY_OPT=1 ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
done
[ -n "$STEP" ] || { echo "$USAGE" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root (you are at the console: log in as root)" >&2; exit 1; }
case "$STEP" in a) PAYLOAD=R1-A ;; b) PAYLOAD=R1-B ;; c) PAYLOAD=R1-C ;; d) PAYLOAD=general ;; esac

# Is the battery driver expected on? --battery or step b: yes. Otherwise: yes when the command
# line carries no initcall_blacklist=macsmc_power... (the payload is "battery on"), no when it does.
CMDLINE=$(tr -d '\n' 2>/dev/null < /proc/cmdline)
BLACKLIST=0; case "$CMDLINE" in *initcall_blacklist=macsmc_power*) BLACKLIST=1 ;; esac
TRACE=0; case "$CMDLINE" in *macsmc_power.trace=1*) TRACE=1 ;; esac
if [ "$BATTERY_OPT" = 1 ] || [ "$STEP" = b ] || [ "$BLACKLIST" = 0 ]; then BATTERY=1; else BATTERY=0; fi

EXPECT_RELEASE=7.2.2-ge1d2d7313745
ESP_DEV=/dev/nvme0n1p4
PS_DIR=${R1_PS_DIR:-/sys/class/power_supply}   # overridable for offline tests

# ---------------------------------------------------------------------------- helpers
TO=""; command -v timeout >/dev/null 2>&1 && TO=timeout
tmo() { local s=$1; shift; if [ -n "$TO" ]; then "$TO" "$s" "$@"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------- log directory
if [ "$(findmnt -n -o FSTYPE -T /boot 2>/dev/null)" != vfat ]; then
    say "/boot is not a vfat mount: mounting $ESP_DEV on /boot"
    mkdir -p /boot
    mount -t vfat "$ESP_DEV" /boot 2>&1 || say "WARNING: mounting $ESP_DEV failed"
fi
STAMP=$(date +%Y%m%d-%H%M)
LOGROOT=/boot/r1-logs
if ! mkdir -p "$LOGROOT" 2>/dev/null || [ ! -w "$LOGROOT" ]; then
    say "WARNING: cannot write $LOGROOT; logging to /var/tmp/r1-logs instead (copy it out by hand)"
    LOGROOT=/var/tmp/r1-logs; mkdir -p "$LOGROOT"
fi
DIR=$LOGROOT/r1-$STEP-$STAMP
n=1; while [ -e "$DIR" ]; do n=$((n + 1)); DIR=$LOGROOT/r1-$STEP-$STAMP-$n; done
mkdir -p "$DIR"
say "r1-local.sh step $STEP ($PAYLOAD), logs: $DIR"

# ---------------------------------------------------------------------------- results
RES_N=0
RES_STATE=(); RES_NAME=(); RES_DETAIL=()
result() { # result STATE NAME DETAIL
    RES_STATE[RES_N]=$1; RES_NAME[RES_N]=$2; RES_DETAIL[RES_N]=$(printf '%s' "$3" | tr '\n' ' ' | sed 's/^ *//' | cut -c1-62)
    RES_N=$((RES_N + 1))
    printf '  %-4s %-14s %s\n' "$1" "$2" "${RES_DETAIL[RES_N - 1]}"
}

CLEAN_PIDS=""; UFW_WAS_ACTIVE=""; UFW_TOUCHED=0
cleanup() {
    local p
    for p in $CLEAN_PIDS; do kill "$p" 2>/dev/null; done
    if [ "$UFW_TOUCHED" = 1 ] && [ "$UFW_WAS_ACTIVE" != 1 ]; then ufw --force disable >/dev/null 2>&1; fi
    sync
}
trap cleanup EXIT

# ask PROMPT: read one line from the console (empty and non-interactive both mean "no answer")
ANSWER=""
ask() {
    ANSWER=""
    printf '%s' "$1"
    if [ -t 0 ]; then read -r -t 180 ANSWER; else echo; fi
}
pause() { ask "$1 [Enter] "; }

# first value of KEY=... in a power_supply uevent file
uev() { sed -n "s/^POWER_SUPPLY_$2=//p" "$1" 2>/dev/null | head -1; }
isnum() { case "$1" in ''|*[!0-9-]*) return 1 ;; *) return 0 ;; esac; }
# timestamp of the first dmesg line matching an extended regex; empty if none
dmesg_ts() { grep -E -m1 "$1" "$DIR/dmesg.txt" 2>/dev/null | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p'; }

# ---------------------------------------------------------------------------- passive collection
collect_common() {
    say "== passive collection"
    dmesg > "$DIR/dmesg.txt" 2>&1
    dmesg -l err,warn > "$DIR/dmesg-errwarn.txt" 2>&1
    if have journalctl; then tmo 60 journalctl -b --no-pager > "$DIR/journal.txt" 2>&1; fi
    cat /proc/cmdline > "$DIR/cmdline.txt" 2>&1
    uname -a > "$DIR/uname.txt" 2>&1
    nproc > "$DIR/nproc.txt" 2>&1
    if have lscpu; then
        tmo 10 lscpu > "$DIR/lscpu.txt" 2>&1
        grep -E 'Architecture|^CPU\(s\)|Model name|Thread|Core|Cluster|Socket|MHz' "$DIR/lscpu.txt" > "$DIR/lscpu-summary.txt" 2>&1
    fi
    {
        for p in 0 6 12; do
            d=/sys/devices/system/cpu/cpufreq/policy$p
            echo "=== $d"
            if [ -d "$d" ]; then
                find "$d" -type f 2>/dev/null | sort | while read -r f; do
                    printf '%s: ' "${f#"$d"/}"
                    tmo 2 cat "$f" 2>&1 | head -c 1500 | tr '\n' ' '
                    echo
                done
            else
                echo "(missing)"
            fi
        done
    } > "$DIR/cpufreq.txt" 2>&1
    {
        ls -l /sys/class/drm 2>&1
        for c in /sys/class/drm/card*-*; do
            [ -e "$c" ] || continue
            echo "=== $c"
            for a in status enabled dpms modes; do
                printf '%s: ' "$a"; tmo 2 cat "$c/$a" 2>&1 | tr '\n' ' '; echo
            done
        done
    } > "$DIR/drm.txt" 2>&1
    cat /sys/class/graphics/fb0/virtual_size > "$DIR/fb0-virtual_size.txt" 2>&1
    if [ -e /proc/device-tree/chosen/asahi,show-notch ]; then
        { if have xxd; then xxd /proc/device-tree/chosen/asahi,show-notch; else od -An -tx1 /proc/device-tree/chosen/asahi,show-notch; fi; } > "$DIR/show-notch.txt" 2>&1
    else
        echo "asahi,show-notch not present" > "$DIR/show-notch.txt"
    fi
    cat /proc/bus/input/devices > "$DIR/input-devices.txt" 2>&1
    { have zramctl && tmo 10 zramctl; echo "--- swapon"; have swapon && tmo 10 swapon --show; echo "--- comp_algorithm"; cat /sys/block/zram0/comp_algorithm 2>&1; } > "$DIR/zram.txt" 2>&1
    { have iptables && tmo 10 iptables -V || echo "iptables not installed"; } > "$DIR/iptables-V.txt" 2>&1
    ls -l /sys/class/leds > "$DIR/leds.txt" 2>&1
    {
        ls -l /sys/class/power_supply 2>&1
        for d in /sys/class/power_supply/*; do
            [ -e "$d" ] || continue
            echo "=== $d/uevent"; tmo 3 cat "$d/uevent" 2>&1
        done
    } > "$DIR/power_supply.txt" 2>&1
}

collect_extra_b() {
    grep 'macsmc-power' "$DIR/dmesg.txt" > "$DIR/trace.txt" 2>&1
    grep -iE 'battery|BCF0|CHLS|CHWA' "$DIR/dmesg.txt" > "$DIR/battery-dmesg.txt" 2>&1
}

collect_extra_c() {
    { have lsusb && tmo 10 lsusb -t; have lsusb && tmo 10 lsusb; have lsusb || echo "lsusb not installed"; } > "$DIR/lsusb.txt" 2>&1
    ls -l /sys/bus/usb/devices > "$DIR/usb-devices.txt" 2>&1
    grep -iE 'dwc3|xhci|usb|tipd|cd321x' "$DIR/dmesg.txt" > "$DIR/usb-dmesg.txt" 2>&1
    ip -br link > "$DIR/ip-br-link.txt" 2>&1
    { ls /sys/class/udc 2>&1; for r in /sys/class/usb_role/*; do [ -e "$r" ] && echo "$r role=$(cat "$r/role" 2>&1)"; done; } > "$DIR/udc-roles.txt" 2>&1
}

# ---------------------------------------------------------------------------- common checks
chk_kernel() {
    local rel cmd miss="" mode
    rel=$(uname -r); cmd=${CMDLINE%% }
    [ "$rel" = "$EXPECT_RELEASE" ] || miss="$miss release=$rel"
    [ "$STEP" != b ] || [ "$TRACE" = 1 ] || miss="$miss no-trace=1"
    if [ "$BATTERY" = 1 ]; then
        [ "$BLACKLIST" = 0 ] || miss="$miss blacklist-present"
        mode="battery on"
    else
        [ "$BLACKLIST" = 1 ] || miss="$miss no-blacklist"
        mode="battery gated"
    fi
    case "$cmd" in *default_governor*) miss="$miss default_governor" ;; esac
    case "$cmd" in *"idle=nop arm64.nowfxt") ;; *) miss="$miss tail-not-idle=nop" ;; esac
    if [ -z "$miss" ]; then result PASS kernel-args "$rel, $mode, args as planned"; else result FAIL kernel-args "$miss ($mode)"; fi
}

chk_cpus() {
    local n up
    n=$(nproc 2>/dev/null)
    up=$(grep -i 'smp: Brought up' "$DIR/dmesg.txt" | head -1 | sed 's/^\[[^]]*\] *//')
    if [ "$n" = 18 ]; then result PASS cpus-18 "nproc 18"; else result FAIL cpus-18 "nproc=$n ${up}"; fi
}

# ---------------------------------------------------------------------------- step a checks
chk_nvme_trackpad() {
    local t ok
    t=$(dmesg_ts 'nvme0n1: p[0-9]')
    if [ -z "$t" ]; then
        result FAIL nvme "no 'nvme0n1: pN' line in dmesg"
    else
        ok=$(awk -v t="$t" 'BEGIN { print (t < 15) ? "y" : "n" }')
        if [ "$ok" = y ]; then result PASS nvme "partitions at ${t}s (<15)"; else result FAIL nvme "partitions at ${t}s (>=15)"; fi
    fi
    if grep -q 'Touch MT ready' "$DIR/dmesg.txt"; then
        result PASS trackpad "Touch MT ready at $(dmesg_ts 'Touch MT ready')s"
    else
        result FAIL trackpad "no 'Touch MT ready'"
    fi
    if grep -qiE 'macsmc.low.gpio|low-gpio' "$DIR/dmesg.txt"; then result PASS low-gpio "macsmc-low-gpio probed"; else result FAIL low-gpio "no macsmc-low-gpio line"; fi
}

chk_smc_core() {
    local miss="" k
    grep -i 'smc' "$DIR/dmesg.txt" > "$DIR/smc-lines.txt"
    for k in 'macsmc[-_]gpio' 'low[-_.]gpio' 'power/lid events' 'rtc' 'reboot'; do
        grep -iE "macsmc|smc" "$DIR/smc-lines.txt" | grep -qiE "$k" || miss="$miss $k"
    done
    grep -q "hwmon hwmon0" "$DIR/dmesg.txt" || miss="$miss hwmon"
    if [ -z "$miss" ]; then result PASS smc-core "gpio low-gpio input rtc reboot"; else result FAIL smc-core "missing:$miss"; fi
    if [ "$BATTERY" = 1 ]; then return; fi
    if grep -v 'Kernel command line' "$DIR/dmesg.txt" | grep -q 'macsmc-power'; then
        result FAIL no-macsmc-pwr "macsmc-power lines present (should be gated)"
    else
        result PASS no-macsmc-pwr "no macsmc-power line"
    fi
}

chk_cpufreq() { # chk_cpufreq [noidle]: governor and max always; the idle read only without "noidle"
    local base=/sys/devices/system/cpu/cpufreq p g mx bad="" idle max
    for p in 0 6 12; do
        g=$(cat $base/policy$p/scaling_governor 2>/dev/null); mx=$(cat $base/policy$p/cpuinfo_max_freq 2>/dev/null)
        [ "$g" = schedutil ] || bad="$bad p$p:gov=${g:-none}"
        [ "$mx" = 4308000 ] || bad="$bad p$p:max=${mx:-none}"
    done
    if [ -z "$bad" ]; then result PASS cpufreq-gov "schedutil x3, max 4308000"; else result FAIL cpufreq-gov "$bad"; fi
    # Reading scaling_cur_freq from a shell wakes the cluster: schedutil reads high at 0.00 load while
    # time_in_state shows the idle floor (RESULTS.md, Round R2). Treat this FAIL as a known artifact.
    [ "${1:-}" != noidle ] || return 0
    say "   (idle wait 10 s ...)"; sleep 10
    idle="$(cat $base/policy0/scaling_cur_freq 2>/dev/null)/$(cat $base/policy6/scaling_cur_freq 2>/dev/null)/$(cat $base/policy12/scaling_cur_freq 2>/dev/null)"
    max=1344000/1344000/1308000
    if [ "$idle" = "$max" ]; then result PASS cpufreq-idle "$idle"; else result FAIL cpufreq-idle "got $idle want $max"; fi
}

chk_cpufreq_load() {
    # Pin `yes` to one CPU per cluster for 8 s; sample the matching policy at 4 s (and 8 s, for the log).
    local cpu pid cur4 cur8 mx pol bad="" det=""
    : > "$DIR/cpufreq-load.txt"
    if ! have taskset; then result SKIP cpufreq-load "taskset not installed"; return; fi
    for cpu in 1 7 13; do
        pol=/sys/devices/system/cpu/cpu$cpu/cpufreq
        mx=$(cat $pol/cpuinfo_max_freq 2>/dev/null)
        if [ -z "$mx" ]; then bad="$bad cpu$cpu:no-cpufreq"; continue; fi
        taskset -c "$cpu" yes > /dev/null 2>&1 & pid=$!
        CLEAN_PIDS="$CLEAN_PIDS $pid"
        sleep 4; cur4=$(cat $pol/scaling_cur_freq 2>/dev/null)
        sleep 4; cur8=$(cat $pol/scaling_cur_freq 2>/dev/null)
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        echo "cpu$cpu ($(basename "$(readlink -f $pol 2>/dev/null)")): max=$mx cur@4s=$cur4 cur@8s=$cur8" >> "$DIR/cpufreq-load.txt"
        det="$det cpu$cpu=$cur4"
        [ "$cur4" = "$mx" ] || bad="$bad cpu$cpu:$cur4!=$mx"
    done
    if [ -z "$bad" ]; then result PASS cpufreq-load "loaded cluster at max:$det"; else result FAIL cpufreq-load "$bad"; fi
}

chk_kbd() {
    local led=/sys/class/leds/kbd_backlight mx bad="" v
    if [ ! -d "$led" ]; then led=$(ls -d /sys/class/leds/*kbd_backlight* 2>/dev/null | head -1); fi
    if [ -z "$led" ] || [ ! -d "$led" ]; then result FAIL kbd-sysfs "no kbd_backlight in /sys/class/leds"; return; fi
    mx=$(cat "$led/max_brightness" 2>/dev/null)
    [ "$mx" = 255 ] || bad="$bad max=$mx"
    [ "$QUICK" = 1 ] || say "   >>> WATCH THE KEYS: backlight goes 0 -> 32 -> 255 -> 0, 2 s each"
    for v in 0 32 255 0; do
        echo "$v" > "$led/brightness" 2>>"$DIR/kbd.txt" || bad="$bad write$v-failed"
        echo "wrote $v, reads back $(cat "$led/brightness" 2>&1)" >> "$DIR/kbd.txt"
        sleep 2
    done
    dmesg > "$DIR/dmesg-after-kbd.txt" 2>&1
    if dmesg -l err,warn | grep -iE 'fpwm|pwm' | grep -v 'failed to read period' > "$DIR/kbd-errors.txt" 2>&1 && [ -s "$DIR/kbd-errors.txt" ]; then bad="$bad pwm/pmgr-errors"; fi
    if [ -z "$bad" ]; then result PASS kbd-sysfs "max 255, 0/32/255/0 written, no pwm errors"; else result FAIL kbd-sysfs "$bad"; fi
    if [ "$QUICK" = 1 ]; then result SKIP kbd-visual "--quick"; return; fi
    ask "   Did the keys dim, go full, then off? (y/n) "
    echo "answer: $ANSWER" >> "$DIR/kbd.txt"
    case "$ANSWER" in
        y|Y|yes) result PASS kbd-visual "operator saw dim/full/off" ;;
        n|N|no) result FAIL kbd-visual "operator saw no change" ;;
        *) result SKIP kbd-visual "no answer" ;;
    esac
}

chk_edp() {
    local c st md nm
    c=$(ls -d /sys/class/drm/card*-eDP-1 2>/dev/null | head -1)
    if [ -z "$c" ]; then result FAIL edp "no card*-eDP-1: $(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"; return; fi
    st=$(cat "$c/status" 2>&1); nm=$(grep -c . "$c/modes" 2>/dev/null)
    md=$(head -1 "$c/modes" 2>/dev/null)
    if [ "$st" = connected ] && [ "$nm" = 1 ]; then result PASS edp "$(basename "$c") connected, 1 mode $md"; else result FAIL edp "$(basename "$c") $st, ${nm:-0} modes $md"; fi
}

chk_lid() {
    local ev dev
    if ! have evtest; then result SKIP lid "evtest not installed"; return; fi
    if [ -z "$TO" ]; then result SKIP lid "no timeout command"; return; fi
    if [ "$QUICK" = 1 ]; then result SKIP lid "--quick"; return; fi
    ev=$(awk '/^N: Name=/ { n = ($0 ~ /Apple SMC power\/lid events/) } n && /^H: Handlers=/ { for (i = 1; i <= NF; i++) if ($i ~ /^event/) { print $i; exit } }' /proc/bus/input/devices)
    if [ -z "$ev" ]; then result FAIL lid "no 'Apple SMC power/lid events' input device"; return; fi
    dev=/dev/input/$ev
    say "   >>> LID TEST: after Enter, CLOSE the lid, then OPEN it, within 15 s (sleep is inhibited)"
    pause "   ready?"
    if have systemd-inhibit; then
        systemd-inhibit --what=handle-lid-switch:sleep --who=r1-local --why="lid test" timeout 15 evtest "$dev" > "$DIR/lid-evtest.txt" 2>&1
    else
        timeout 15 evtest "$dev" > "$DIR/lid-evtest.txt" 2>&1
    fi
    if grep -q 'SW_LID.*value 1' "$DIR/lid-evtest.txt" && grep -q 'SW_LID.*value 0' "$DIR/lid-evtest.txt"; then
        result PASS lid "SW_LID 1 then 0 on $ev"
    elif grep -q 'SW_LID' "$DIR/lid-evtest.txt"; then
        result FAIL lid "only one SW_LID edge seen on $ev"
    else
        result FAIL lid "no SW_LID event on $ev in 15 s"
    fi
}

chk_notch() {
    local vs prop
    vs=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)
    prop=$(tr '\n' ' ' < "$DIR/show-notch.txt" | cut -c1-40)
    if [ "$vs" = "3456,2234" ] && [ -e /proc/device-tree/chosen/asahi,show-notch ]; then
        result PASS notch "fb0 $vs, notch rows kept (stage-2 m1n1 0017), show-notch: $prop"
    elif [ "$vs" = "3456,2160" ] && [ -e /proc/device-tree/chosen/asahi,show-notch ]; then
        result PASS notch "fb0 $vs, notch trimmed (old m1n1), show-notch: $prop"
    elif [ "$vs" = "3456,2160" ]; then
        result FAIL notch "fb0 $vs but no asahi,show-notch property"
    else
        result FAIL notch "fb0=${vs:-none} (want 3456,2234 or 3456,2160); $prop"
    fi
}

chk_zram() {
    local alg
    alg=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
    case "$alg" in
        *"[zstd]"*) result PASS zram "zram0 with [zstd]" ;;
        "") result FAIL zram "no zram0 (zram-generator missing/not set up?)" ;;
        *) result FAIL zram "algorithm: $alg" ;;
    esac
}

chk_ufw() {
    local v bad="" out
    v=$(tmo 10 iptables -V 2>&1)
    case "$v" in *nf_tables*) result PASS iptables "$v" ;; "") result FAIL iptables "iptables not installed" ;; *) result FAIL iptables "$v" ;; esac
    if ! have ufw; then result SKIP ufw "ufw not installed"; return; fi
    tmo 10 ufw status 2>&1 | grep -qi '^Status: active' && UFW_WAS_ACTIVE=1
    UFW_TOUCHED=1
    {
        echo "# ufw --force enable"; tmo 60 ufw --force enable 2>&1
        echo "# ufw status verbose"; tmo 30 ufw status verbose 2>&1
        echo "# nft list ruleset | head -40"; tmo 30 nft list ruleset 2>&1 | head -40
        echo "# ufw --force disable"
        if [ "$UFW_WAS_ACTIVE" = 1 ]; then echo "(ufw was already active before this run: left enabled)"; else tmo 60 ufw --force disable 2>&1; fi
    } > "$DIR/ufw.txt" 2>&1
    UFW_TOUCHED=0
    out=$(cat "$DIR/ufw.txt")
    case "$out" in *"can't initialize iptables"*|*"Couldn't load match"*|*"Couldn't load target"*|*"ERROR"*|*"Failed to"*|*"Table does not exist"*) bad="$bad errors-in-ufw.txt" ;; esac
    case "$out" in *"Status: active"*) ;; *) bad="$bad not-active" ;; esac
    if [ -z "$bad" ]; then result PASS ufw "enabled with default rules, disabled again"; else result FAIL ufw "$bad"; fi
}

chk_noise() {
    local n
    dmesg > "$DIR/dmesg-final.txt" 2>&1
    dmesg -l err,warn > "$DIR/dmesg-errwarn-final.txt" 2>&1
    n=$(grep -v 'Kernel command line' "$DIR/dmesg-final.txt" | grep -ciE 'soft lockup|hard lockup|rcu.*stall|Oops|\bBUG:|Call trace|Kernel panic' || true)
    if [ "$n" = 0 ]; then
        result PASS noise "$(grep -c . "$DIR/dmesg-errwarn-final.txt") err/warn lines, no lockup/oops (diff vs B2 later)"
    else
        result FAIL noise "$n lockup/oops/trace lines in dmesg"
    fi
}

# ---------------------------------------------------------------------------- step b checks
chk_battery() {
    local ps=$PS_DIR u st cap v cn cf cyc tmp acon tte bat ac
    bat=$ps/macsmc-battery; ac=$ps/macsmc-ac
    if [ -d "$bat" ]; then result PASS bat-present "macsmc-battery"; else result FAIL bat-present "macsmc-battery missing: $(ls "$ps" 2>/dev/null | tr '\n' ' ')"; fi
    if [ -d "$ac" ]; then result PASS ac-present "macsmc-ac"; else result FAIL ac-present "macsmc-ac missing"; fi
    if [ "$TRACE" = 0 ]; then result SKIP probe-done "no macsmc_power.trace=1 on the command line"
    elif grep -q 'probe done' "$DIR/trace.txt" 2>/dev/null; then result PASS probe-done "trace has 'probe done'"
    else result FAIL probe-done "no 'probe done' in the trace"; fi
    if [ ! -d "$bat" ]; then return; fi
    u=$bat/uevent
    st=$(uev "$u" STATUS); cap=$(uev "$u" CAPACITY); v=$(uev "$u" VOLTAGE_NOW)
    cn=$(uev "$u" CHARGE_NOW); cf=$(uev "$u" CHARGE_FULL); cyc=$(uev "$u" CYCLE_COUNT); tmp=$(uev "$u" TEMP)
    tte=$(uev "$u" TIME_TO_EMPTY_NOW)
    acon=$(cat "$ac/online" 2>/dev/null)
    case "$acon:$st" in
        1:Charging|1:Full|1:"Not charging"|0:Discharging) result PASS bat-status "$st, ac online=$acon" ;;
        *) result FAIL bat-status "STATUS='$st' with ac online='$acon'" ;;
    esac
    if isnum "$cap" && [ "$cap" -ge 1 ] && [ "$cap" -le 100 ]; then result PASS bat-capacity "$cap % (compare with macOS)"; else result FAIL bat-capacity "CAPACITY='$cap'"; fi
    if isnum "$v" && [ "$v" -ge 11000000 ] && [ "$v" -le 13100000 ]; then result PASS bat-voltage "$v uV (11.0-13.1e6)"; else result FAIL bat-voltage "VOLTAGE_NOW='$v' (want 11.0-13.1e6)"; fi
    if isnum "$cn" && isnum "$cf"; then
        if [ "$cf" -gt 15000000 ]; then result FAIL bat-charge "FULL=$cf (~20e6 = B0RM byte order wrong)"
        elif [ "$cn" -le "$cf" ]; then result PASS bat-charge "NOW $cn <= FULL $cf uAh"
        else result FAIL bat-charge "NOW $cn > FULL $cf"; fi
    else
        result FAIL bat-charge "CHARGE_NOW='$cn' CHARGE_FULL='$cf'"
    fi
    if isnum "$cyc"; then result PASS bat-cycles "CYCLE_COUNT $cyc (compare with macOS)"; else result FAIL bat-cycles "CYCLE_COUNT='$cyc'"; fi
    if isnum "$tmp" && [ "$tmp" -ge 200 ] && [ "$tmp" -le 400 ]; then result PASS bat-temp "TEMP $tmp (20-40 C)"; else result FAIL bat-temp "TEMP='$tmp' (want 200-400)"; fi
    if [ "$acon" = 1 ] && [ -n "$tte" ]; then result FAIL bat-tte "TIME_TO_EMPTY_NOW=$tte on AC (should be absent)"; else result PASS bat-tte "no TIME_TO_EMPTY on AC"; fi
}

chk_chwa() {
    local w="n" l="n"
    [ -s "$DIR/trace.txt" ] || { result SKIP charge-keys "no trace lines"; return; }
    grep -q 'rd CHWA' "$DIR/trace.txt" && w=y
    grep -q 'rd CHLS' "$DIR/trace.txt" && l=y
    if [ "$w" = y ] || [ "$l" = y ]; then result PASS charge-keys "trace read CHWA=$w CHLS=$l (read only)"; else result FAIL charge-keys "neither CHWA nor CHLS in trace"; fi
}

chk_magsafe() {
    local ac=$PS_DIR/macsmc-ac/online bat=$PS_DIR/macsmc-battery/uevent a0 a1 a2 s0 s1 s2
    if [ ! -e "$ac" ]; then result SKIP magsafe "no macsmc-ac"; return; fi
    if [ "$QUICK" = 1 ]; then result SKIP magsafe "--quick"; return; fi
    a0=$(cat "$ac" 2>&1); s0=$(uev "$bat" STATUS)
    say "   MagSafe now: online=$a0 status=$s0"
    pause "   >>> UNPLUG the MagSafe cable, then press"
    sleep 2; a1=$(cat "$ac" 2>&1); s1=$(uev "$bat" STATUS)
    pause "   >>> PLUG the MagSafe cable back in, then press"
    sleep 2; a2=$(cat "$ac" 2>&1); s2=$(uev "$bat" STATUS)
    echo "before: online=$a0 status=$s0; unplugged: online=$a1 status=$s1; replugged: online=$a2 status=$s2" > "$DIR/magsafe.txt"
    if [ "$a0" = 1 ] && [ "$a1" = 0 ] && [ "$a2" = 1 ]; then
        result PASS magsafe "online 1->0->1, status $s0/$s1/$s2"
    else
        result FAIL magsafe "online $a0->$a1->$a2, status $s0/$s1/$s2"
    fi
}

# ---------------------------------------------------------------------------- step c checks
chk_usb_core() {
    local nphy r udc
    nphy=$(grep -c 'phy-apple-usb2' "$DIR/dmesg.txt")
    if [ "$nphy" -ge 3 ] && grep -q 'xhci' "$DIR/dmesg.txt"; then result PASS usb-phy-xhci "$nphy phy lines, xhci present"; else result FAIL usb-phy-xhci "phy lines=$nphy, xhci=$(grep -c xhci "$DIR/dmesg.txt")"; fi
    # -110 counts only on usb/xhci/dwc3/phy lines: the apple-pmgr-pwrstate probe timeouts (~23 s) are not USB.
    if grep -iE 'usb|xhci|dwc3|phy' "$DIR/dmesg.txt" | grep -v 'apple-pmgr-pwrstate' | grep -qE 'error -110| -110$' \
        || grep -qE 'HC died|DART.*fault' "$DIR/dmesg.txt"; then
        result FAIL usb-errors "-110 on a usb/xhci/dwc3/phy line, HC died or DART fault"
    else
        result PASS usb-errors "no usb -110 (pmgr -110 ignored), HC died, DART fault"
    fi
    r=$(cat /sys/class/usb_role/2aa280000.usb-role-switch/role 2>&1)
    udc=$(ls /sys/class/udc 2>/dev/null | sort | tr '\n' ' ')
    if [ "$r" = host ]; then result PASS usb-role "2aa280000 role=host"; else result FAIL usb-role "2aa280000 role=$r"; fi
    if [ "$udc" = "2a2280000.usb 382280000.usb " ]; then result PASS usb-udc "udc: $udc"; else result FAIL usb-udc "udc: ${udc:-none} (want 2a2280000.usb 382280000.usb)"; fi
}

# non-hub USB devices as "vid:pid product"
usb_list() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue
        printf '%s:%s %s\n' "$(cat "$d/idVendor")" "$(cat "$d/idProduct" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)"
    done | sort
}
link_list() { ip -br link 2>/dev/null | awk '{print $1}' | sort; }

# every enumerated device below a root hub (bus-port names like 1-1, 1-1.2.1), hubs included, as
# "name vid:pid product"
usb_present() {
    local d n
    for d in /sys/bus/usb/devices/*; do
        n=$(basename "$d")
        case "$n" in [0-9]*-[0-9]*) ;; *) continue ;; esac
        case "$n" in *:*) continue ;; esac
        [ -f "$d/idVendor" ] || continue
        printf '%s %s:%s %s\n' "$n" "$(cat "$d/idVendor")" "$(cat "$d/idProduct" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null | sed 's/ *$//')"
    done
}

# usb-enum: passive. Devices enumerated now (sysfs) and 'new ... USB device' lines in dmesg.
chk_usb_enum() {
    local nnew ndev list
    dmesg > "$DIR/dmesg-usbenum.txt" 2>&1
    nnew=$(grep -cE 'usb [0-9]+-[0-9.]+: new .*USB device' "$DIR/dmesg-usbenum.txt")
    list=$(usb_present)
    ndev=$(printf '%s' "$list" | grep -c .)
    { echo "new-device lines: $nnew"; echo "devices present: $ndev"; printf '%s\n' "$list"; } > "$DIR/usb-enum.txt"
    if [ "$ndev" -ge 1 ] || [ "$nnew" -ge 1 ]; then
        result PASS usb-enum "$ndev present, $nnew new-device lines: $(printf '%s' "$list" | awk '{print $2}' | tr '\n' ' ')"
    else
        result FAIL usb-enum "nothing enumerated below the root hubs (no VBUS, or nothing plugged before boot)"
    fi
}

chk_usb_ports() {
    local port u0 u1 l0 l1 newu newl got="" miss="" dm0 note npre
    if [ "$QUICK" = 1 ]; then result SKIP usb-ports "--quick"; return; fi
    have ip || { result SKIP usb-ports "no ip command"; return; }
    npre=$(usb_present | grep -c .)
    { echo "devices present before the test: $npre"; usb_present; } > "$DIR/usb-ports.txt"
    say "   >>> USB-Ethernet adapter test, one port at a time (left-rear, left-front, right)."
    say "       Note: the left-front port may have no VBUS; the adapter then stays dark."
    for port in left-rear left-front right; do
        pause "   Unplug the adapter from every port, then press"
        u0=$(usb_list); l0=$(link_list); dm0=$(dmesg | wc -l)
        pause "   PLUG the adapter into the $(echo "$port" | tr '[:lower:]' '[:upper:]') port, then press (waits 6 s)"
        sleep 6
        u1=$(usb_list); l1=$(link_list)
        newu=$(comm -13 <(printf '%s\n' "$u0") <(printf '%s\n' "$u1") | tr '\n' ';')
        newl=$(comm -13 <(printf '%s\n' "$l0") <(printf '%s\n' "$l1") | tr '\n' ' ')
        {
            echo "=== $port: new usb device(s): ${newu:-none}; new link(s): ${newl:-none}"
            dmesg | tail -n +"$((dm0 + 1))"
            echo "devices present after: $(usb_present | grep -c .)"; usb_present
        } >> "$DIR/usb-ports.txt"
        if [ -n "$newu$newl" ]; then got="$got $port(${newl:-usb})"; else miss="$miss $port"; fi
    done
    note=""; case "$miss" in *left-front*) note=" (left-front may lack VBUS)" ;; esac
    if [ -n "$got" ]; then
        result PASS usb-ports "enumerates:$got; dark:${miss:- none}$note"
    elif [ "$npre" -ge 1 ]; then
        # plugged before boot: the chain was already up, and a replug does not re-enumerate (no tipd/cd321x driver)
        result PASS usb-ports "$npre device(s) enumerated since boot; replug showed nothing new$note"
    else
        result FAIL usb-ports "no port enumerated$note"
    fi
}

# ---------------------------------------------------------------------------- run
# the USB checks make sense only on the usbhost DTB (model string ends in "USB host")
USBHOST=0; grep -aq 'USB host' /proc/device-tree/model 2>/dev/null && USBHOST=1
collect_common
if [ "$BATTERY" = 1 ]; then collect_extra_b; fi
case "$STEP" in
    c) collect_extra_c ;;
    d) if [ "$USBHOST" = 1 ]; then collect_extra_c; fi ;;
esac
say "== checks"
chk_kernel
chk_cpus
case "$STEP" in
    a)
        chk_nvme_trackpad
        chk_smc_core
        if [ "$BATTERY" = 1 ]; then chk_battery; chk_chwa; fi
        chk_cpufreq
        chk_cpufreq_load
        result SKIP opp-offset "needs dvfs-regs/cpuhz tools (not run solo)"
        chk_kbd
        chk_edp
        chk_lid
        chk_notch
        chk_zram
        chk_ufw
        chk_noise
        ;;
    b)
        chk_battery
        chk_chwa
        chk_magsafe
        chk_noise
        ;;
    c)
        if [ "$BATTERY" = 1 ]; then chk_battery; chk_chwa; fi
        chk_usb_core
        chk_usb_enum
        chk_usb_ports
        # refresh the USB logs after the port test
        dmesg > "$DIR/dmesg-final.txt" 2>&1
        grep -iE 'dwc3|xhci|usb|tipd|cd321x' "$DIR/dmesg-final.txt" > "$DIR/usb-dmesg-final.txt" 2>&1
        ip -br link > "$DIR/ip-br-link-final.txt" 2>&1
        ls -l /sys/bus/usb/devices > "$DIR/usb-devices-final.txt" 2>&1
        if have lsusb; then tmo 10 lsusb > "$DIR/lsusb-final.txt" 2>&1; fi
        chk_noise
        ;;
    d)
        chk_nvme_trackpad
        chk_smc_core
        if [ "$BATTERY" = 1 ]; then chk_battery; chk_chwa; fi
        chk_cpufreq noidle
        chk_edp
        chk_notch
        chk_zram
        if [ "$USBHOST" = 1 ]; then
            chk_usb_core
            chk_usb_enum
        else
            result SKIP usb "normal DTB (no 'USB host' in the model string)"
        fi
        chk_noise
        ;;
esac

# ---------------------------------------------------------------------------- summary
np=0; nf=0; ns=0; i=0
while [ "$i" -lt "$RES_N" ]; do
    case "${RES_STATE[i]}" in PASS) np=$((np + 1)) ;; FAIL) nf=$((nf + 1)) ;; *) ns=$((ns + 1)) ;; esac
    i=$((i + 1))
done
{
    echo "==================== R1-$STEP ($PAYLOAD) SUMMARY ===================="
    echo "$(uname -r)  $(date '+%F %H:%M')  PASS $np  FAIL $nf  SKIP $ns"
    i=0
    while [ "$i" -lt "$RES_N" ]; do
        printf '%-4s %-14s %s\n' "${RES_STATE[i]}" "${RES_NAME[i]}" "${RES_DETAIL[i]}"
        i=$((i + 1))
    done
    echo "logs: $DIR"
    echo "==================== END R1-$STEP SUMMARY ===================="
} > "$DIR/summary.txt"
sync
echo
cat "$DIR/summary.txt"
echo
echo "Log directory: $DIR"
case "$STEP" in
    a) echo "Photograph the block above. Then restart:  systemctl reboot   (it must come back on R1-A; this script does not reboot)." ;;
    b) echo "Photograph the block above. Then restart twice:  systemctl reboot   (each must come back; this script does not reboot)." ;;
    c) echo "Photograph the block above. Then restart:  systemctl reboot   (this script does not reboot)." ;;
    d) echo "Nothing was plugged, unplugged or rewritten; this script does not reboot." ;;
esac
sync
