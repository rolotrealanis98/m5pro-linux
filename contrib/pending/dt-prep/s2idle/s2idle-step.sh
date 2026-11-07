#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# s2idle-step.sh - one s2idle test step on the J716s (MacBook Pro 16-inch, M5 Pro, T6050), Aurora kernel.
# Run as root (console or ssh). The step runs detached (setsid), so an ssh session over the USB tether
# may drop while the gadget is suspended without killing the test. Everything goes to
#   /boot/r1-logs/sleep-<step>-<YYYYmmdd-HHMMSS>/   (the ESP; /dev/nvme0n1p4 is mounted on /boot if needed)
#
#   bash s2idle-step.sh wd2   [--guard S]    S0: WD2 calibration. Arms the spare SoC watchdog and does NOT
#                                            disarm it: the Mac must reset after S s (default 30).
#   bash s2idle-step.sh s1    [--guard S]    freezer only      (pm_test=freezer)
#   bash s2idle-step.sh s2    [--guard S]    freezer + devices (pm_test=devices)
#   bash s2idle-step.sh s3    [--guard S]    + late/noirq      (pm_test=platform)
#   bash s2idle-step.sh s4    [--guard S] [--wake rtc|button] [--seconds N]
#                                            real s2idle; rtc: rtcwake -m mem -s N (default 20), only if
#                                            rtc0 has a wake alarm; button: wait for the power button / lid
#   options: --guard 0 (no WD2 guard), --foreground (do not detach), --console (keep consoles awake)
#
# Recovery: apple_wdt STOPS the A/B watchdog (WD1) in its suspend callback, in every step s2-s4, so
# WD1 cannot recover a hang there. The guard arms WD2 of the same block (0x28836c000 + 0x20, a "normal
# machine reset" timer the driver never touches; 24 MHz) before the step and clears it after. Without a
# guard, or if WD2 does not reset this SoC (run "wd2" once first), a hang needs a 10 s power-button hold.
# The script never writes "disk" to /sys/power/state (this kernel has CONFIG_HIBERNATION=y).
set -u
export LC_ALL=C

USAGE="usage: bash s2idle-step.sh wd2|s1|s2|s3|s4 [--guard S] [--wake rtc|button] [--seconds N] [--foreground] [--console]"
STEP=""; GUARD=""; WAKE=""; SECS=20; FG=0; CONSOLE=0; CHILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        wd2|s1|s2|s3|s4) STEP=$1 ;;
        --guard) GUARD=${2:-}; shift ;;
        --wake) WAKE=${2:-}; shift ;;
        --seconds) SECS=${2:-}; shift ;;
        --foreground) FG=1 ;;
        --console) CONSOLE=1 ;;
        --child) CHILD=1 ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$STEP" ] || { echo "$USAGE" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
case "$STEP" in wd2) : "${GUARD:=30}" ;; *) : "${GUARD:=120}" ;; esac
case "$GUARD$SECS" in *[!0-9]*) echo "--guard and --seconds take whole seconds" >&2; exit 2 ;; esac
[ "$GUARD" -le 178 ] || { echo "--guard: at most 178 s (32-bit count at 24 MHz)" >&2; exit 2; }

WDT_BASE=0x28836c000          # t6050-die0.dtsi wdt: watchdog@28836c000 (apple,t6050-wdt)
WD2_CUR=0x20; WD2_BITE=0x24; WD2_CTRL=0x2c; WDT_HZ=24000000; CTRL_RESET_EN=4

# ------------------------------------------------------------------ log directory, then detach
if [ "$CHILD" = 0 ]; then
    if [ "$(findmnt -n -o FSTYPE -T /boot 2>/dev/null)" != vfat ]; then
        mount /dev/nvme0n1p4 /boot 2>/dev/null || true
    fi
    ROOT=/boot/r1-logs
    mkdir -p "$ROOT" 2>/dev/null && [ -w "$ROOT" ] || ROOT=/var/tmp/r1-logs
    mkdir -p "$ROOT"
    LOGDIR=$ROOT/sleep-$STEP-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$LOGDIR"
    export S2I_LOGDIR=$LOGDIR
    ARGS=("$STEP" --guard "$GUARD" --seconds "$SECS" --child)
    [ -n "$WAKE" ] && ARGS+=(--wake "$WAKE")
    [ "$CONSOLE" = 1 ] && ARGS+=(--console)
    echo "s2idle-step: $STEP -> $LOGDIR"
    if [ "$FG" = 1 ]; then
        bash "$0" "${ARGS[@]}" 2>&1 | tee "$LOGDIR/run.log"
        exit "${PIPESTATUS[0]}"
    fi
    setsid -f bash "$0" "${ARGS[@]}" > "$LOGDIR/run.log" 2>&1 < /dev/null
    echo "detached; follow with: tail -f $LOGDIR/run.log   (summary: $LOGDIR/summary.txt)"
    exit 0
fi

LOGDIR=${S2I_LOGDIR:?}
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
flush() { sync -f "$LOGDIR/run.log" 2>/dev/null; sync; }
kmsg() { echo "s2idle-step: $*" > /dev/kmsg 2>/dev/null; }
FAILS=0; NOTES=""
fail() { say "FAIL: $*"; FAILS=$((FAILS + 1)); NOTES="$NOTES\nFAIL: $*"; }
note() { say "NOTE: $*"; NOTES="$NOTES\nNOTE: $*"; }

# ------------------------------------------------------------------ WD2 through /dev/mem
mmio() {    # mmio read OFF | mmio write OFF VAL
    python3 - "$WDT_BASE" "$@" <<'PY' 2>&1
import mmap, os, struct, sys
base = int(sys.argv[1], 0)
op, off = sys.argv[2], int(sys.argv[3], 0)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x4000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
if op == "write":
    struct.pack_into("<I", m, off, int(sys.argv[4], 0))
print(hex(struct.unpack_from("<I", m, off)[0]))
PY
}
have_mmio() { command -v python3 >/dev/null 2>&1 && [ -c /dev/mem ]; }
wd2_arm() {
    local s=$1
    have_mmio || { note "no python3 or /dev/mem: WD2 guard not armed"; return 1; }
    mmio write $WD2_CTRL 0 >/dev/null
    mmio write $WD2_CUR 0 >/dev/null
    mmio write $WD2_BITE $((s * WDT_HZ)) >/dev/null
    local c; c=$(mmio write $WD2_CTRL $CTRL_RESET_EN)
    say "WD2 armed: reset in ${s}s (CTRL=$c BITE=$(mmio read $WD2_BITE) CUR=$(mmio read $WD2_CUR))"
    kmsg "WD2 armed ${s}s"
}
wd2_disarm() {
    have_mmio || return 0
    local cur; cur=$(mmio read $WD2_CUR)
    mmio write $WD2_CTRL 0 >/dev/null
    say "WD2 disarmed (count was $cur = $(( cur / WDT_HZ )) s; CTRL=$(mmio read $WD2_CTRL))"
}

# ------------------------------------------------------------------ guards
say "step $STEP, guard ${GUARD}s, kernel $(uname -r)"
{
    echo "cmdline: $(cat /proc/cmdline)"
    echo "state: $(cat /sys/power/state 2>/dev/null)"
    echo "mem_sleep: $(cat /sys/power/mem_sleep 2>/dev/null)"
    echo "pm_test: $(cat /sys/power/pm_test 2>/dev/null || echo absent)"
    echo "cpuidle driver: $(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)"
    for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        [ -d "$s" ] && echo "  $(basename $s): $(cat $s/name) usage=$(cat $s/usage) s2idle_usage=$(cat $s/s2idle/usage 2>/dev/null)"
    done
    echo "watchdog0: $(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null) state=$(cat /sys/class/watchdog/watchdog0/state 2>/dev/null) timeout=$(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null)"
    echo "rtc0: $(cat /sys/class/rtc/rtc0/name 2>/dev/null) wakealarm=$([ -e /sys/class/rtc/rtc0/wakealarm ] && echo yes || echo no)"
    echo "boot-slot: $(tr -d '\0' < /proc/device-tree/chosen/m5pro,boot-slot 2>/dev/null)"
    echo "wakeup-enabled devices:"; grep -l enabled /sys/devices/*/*/power/wakeup /sys/devices/platform/*/*/power/wakeup 2>/dev/null | sed 's|/power/wakeup||; s|^|  |'
} > "$LOGDIR/guards.txt"
cat "$LOGDIR/guards.txt"

grep -qw freeze /sys/power/state || { fail "/sys/power/state has no freeze (CONFIG_SUSPEND)"; }
case "$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)" in
    apple_idle) ;; *) fail "cpuidle driver is not apple_idle: s2idle would never freeze the tick" ;;
esac
grep -qE '(^| )idle=nop( |$)' /proc/cmdline && fail "idle=nop on the command line"
case "$STEP" in
    s1|s2|s3) [ -w /sys/power/pm_test ] || fail "no /sys/power/pm_test: kernel without CONFIG_PM_DEBUG (patch s2idle-plan/0001)" ;;
    s4) grep -q '\[s2idle\]' /sys/power/mem_sleep 2>/dev/null || fail "mem_sleep is not [s2idle]" ;;
esac
if [ "$STEP" = s4 ]; then
    if [ -z "$WAKE" ]; then
        if [ -e /sys/class/rtc/rtc0/wakealarm ]; then WAKE=rtc; else WAKE=button; fi
    fi
    if [ "$WAKE" = rtc ] && [ ! -e /sys/class/rtc/rtc0/wakealarm ]; then
        fail "--wake rtc: rtc0 has no wake alarm (macsmc-rtc needs the PMU alarm cells and an SPMI interrupt; gen-4 SPMI here is polled)"
    fi
    if [ "$WAKE" = button ] && [ "$GUARD" = 0 ]; then
        note "button wake without a guard: if nobody presses, only a power-button hold recovers"
    fi
fi
if [ "$FAILS" -gt 0 ]; then
    printf "RESULT: ABORTED before any sleep%b\n" "$NOTES" | tee "$LOGDIR/summary.txt"; flush; exit 1
fi

# ------------------------------------------------------------------ WD2 calibration (S0)
if [ "$STEP" = wd2 ]; then
    [ "$GUARD" -gt 0 ] || { echo "wd2 needs --guard > 0" >&2; exit 2; }
    printf "RESULT: WD2 armed for %ss and left armed; the Mac must reset by itself.\nAfter the reboot: journalctl -b -1 -k | tail; cat /proc/device-tree/chosen/m5pro,boot-slot\n" "$GUARD" > "$LOGDIR/summary.txt"
    flush
    wd2_arm "$GUARD" || { echo "RESULT: could not arm WD2" >> "$LOGDIR/summary.txt"; flush; exit 1; }
    flush
    for i in $(seq 1 $((GUARD + 60))); do
        sleep 1; [ $((i % 5)) = 0 ] && { say "alive ${i}s, WD2 count $(mmio read $WD2_CUR)"; flush; }
    done
    wd2_disarm
    echo "RESULT: FAIL - no reset after $((GUARD + 60))s: WD2 does not reset this SoC; do not rely on the guard" >> "$LOGDIR/summary.txt"
    flush; exit 1
fi

# ------------------------------------------------------------------ before
snap() {    # snap before|after
    local d=$LOGDIR/$1; mkdir -p "$d"
    cp /proc/interrupts "$d/interrupts" 2>/dev/null
    for f in /sys/power/suspend_stats/*; do echo "$(basename $f): $(cat $f 2>/dev/null)"; done > "$d/suspend_stats" 2>/dev/null
    cat /sys/kernel/debug/wakeup_sources > "$d/wakeup_sources" 2>/dev/null
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state1/s2idle/usage; do echo "$s $(cat $s)"; done > "$d/s2idle_usage" 2>/dev/null
    lsusb > "$d/lsusb" 2>/dev/null; ls /sys/bus/usb/devices > "$d/usb-devices" 2>/dev/null
    ip -br link > "$d/ip-link" 2>/dev/null; ip -br addr > "$d/ip-addr" 2>/dev/null
    ls /dev/input/by-path /dev/input/by-id > "$d/input" 2>&1
    cat /sys/class/watchdog/watchdog0/state > "$d/watchdog0" 2>/dev/null
    for t in /sys/class/typec/port*; do [ -d "$t" ] && echo "$t $(cat $t/data_role 2>/dev/null)"; done > "$d/typec" 2>/dev/null
    date +%s.%N > "$d/wall"; cat /proc/uptime > "$d/uptime"
}
snap before
[ -w /sys/power/pm_print_times ] && echo 1 > /sys/power/pm_print_times
[ -w /sys/power/pm_debug_messages ] && echo 1 > /sys/power/pm_debug_messages
sysctl -q -w kernel.panic=10 kernel.panic_on_oops=1 2>/dev/null   # a panic reboots through apple_wdt's restart
if [ "$CONSOLE" = 1 ]; then echo N > /sys/module/printk/parameters/console_suspend; fi
# Keep xHCI and its PHYs set up across sleep (edimoldovan 9f8535b38fcb does this from the DT on J714c)
for w in /sys/bus/platform/devices/xhci-hcd*/power/wakeup; do [ -w "$w" ] && echo enabled > "$w"; done

case "$STEP" in s1) LEVEL=freezer ;; s2) LEVEL=devices ;; s3) LEVEL=platform ;; s4) LEVEL=none ;; esac
[ -w /sys/power/pm_test ] && echo "$LEVEL" > /sys/power/pm_test
say "pm_test=$(cat /sys/power/pm_test 2>/dev/null || echo absent) wake=${WAKE:-pm_test_delay}"
kmsg "begin $STEP"
flush; sleep 2; flush

# ------------------------------------------------------------------ the step
[ "$GUARD" -gt 0 ] && { wd2_arm "$GUARD"; flush; }
T0=$(date +%s)
# shellcheck disable=SC2320  # the status of the sysfs write is the result
case "$STEP" in
    s1|s2|s3) echo freeze > /sys/power/state; RC=$? ;;
    s4) if [ "$WAKE" = rtc ]; then rtcwake -d rtc0 -m mem -s "$SECS"; RC=$?
        else say "press the power button (or close and open the lid) to wake"; flush
             echo mem > /sys/power/state; RC=$?
        fi ;;
esac
T1=$(date +%s)
[ "$GUARD" -gt 0 ] && wd2_disarm
kmsg "end $STEP rc=$RC"
[ -w /sys/power/pm_test ] && echo none > /sys/power/pm_test
[ "$CONSOLE" = 1 ] && echo Y > /sys/module/printk/parameters/console_suspend
say "returned rc=$RC after $((T1 - T0))s"
sleep 3
snap after

# ------------------------------------------------------------------ verdict
dmesg | sed -n '/s2idle-step: begin '"$STEP"'/,$p' > "$LOGDIR/dmesg.txt"
D=$LOGDIR/dmesg.txt
[ "$RC" = 0 ] || fail "write to /sys/power/state returned $RC"
grep -q 'PM: suspend entry (s2idle)' "$D" || fail "no 'PM: suspend entry (s2idle)'"
grep -q 'PM: suspend exit' "$D" || fail "no 'PM: suspend exit'"
grep -qE 'Freezing .* failed|refusing to freeze' "$D" && fail "freezer: $(grep -m1 -E 'refusing to freeze|Freezing .* failed' "$D")"
grep -qE 'PM: failed to (suspend|resume)|Some devices failed to suspend|returns -[0-9]+' "$D" && \
    fail "device callback: $(grep -m3 -E 'PM: failed to|dpm_run_callback|returns -[0-9]+' "$D" | tr '\n' ' ')"
grep -qE 'Wakeup pending|last active wakeup source' "$D" && note "early wake: $(grep -m2 -E 'Wakeup pending|last active wakeup source' "$D" | tr '\n' ' ')"
grep -qE 'Unsupported test mode' "$D" && fail "pm_test level not allowed for s2idle"
grep -qE 'Internal error|Unable to handle|SError|Oops|BUG:|WARNING:' "$D" && fail "kernel splat: $(grep -m1 -E 'Internal error|Unable to handle|SError|Oops|BUG:|WARNING:' "$D")"
case "$STEP" in
    s2|s3) grep -q 'suspend debug: Waiting for' "$D" || fail "pm_test did not reach its level" ;;
    s4) grep -q 'resume from suspend-to-idle' "$D" || note "no 'resume from suspend-to-idle' (pm_debug_messages off?)"
        grep -m1 'Timekeeping suspended for' "$D" >/dev/null && note "$(grep -m1 'Timekeeping suspended for' "$D")"
        grep -m3 'Triggering wakeup from IRQ' "$D" >/dev/null && note "$(grep -m3 'Triggering wakeup from IRQ' "$D" | tr '\n' ' ')" ;;
esac
cmp -s "$LOGDIR/before/usb-devices" "$LOGDIR/after/usb-devices" || note "USB device set changed (diff before/usb-devices after/usb-devices)"
cmp -s "$LOGDIR/before/input" "$LOGDIR/after/input" || fail "input devices changed (keyboard/trackpad?)"
[ "$(cat "$LOGDIR/after/watchdog0")" = "$(cat "$LOGDIR/before/watchdog0")" ] || fail "watchdog0 state changed: $(cat "$LOGDIR/after/watchdog0")"
timeout 30 dd if=/dev/nvme0n1 of=/dev/null bs=1M count=64 iflag=direct 2>"$LOGDIR/after/nvme-read" || fail "NVMe read after resume failed"
diff "$LOGDIR/before/interrupts" "$LOGDIR/after/interrupts" > "$LOGDIR/interrupts.diff"

{
    if [ "$FAILS" = 0 ]; then echo "RESULT: PASS ($STEP, rc=$RC, $((T1 - T0)) s)"; else echo "RESULT: FAIL ($STEP, $FAILS problem(s))"; fi
    printf "%b\n" "$NOTES"
    echo "suspend_stats after:"; sed 's/^/  /' "$LOGDIR/after/suspend_stats"
} | tee "$LOGDIR/summary.txt"
flush
