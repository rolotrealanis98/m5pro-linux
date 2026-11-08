#!/usr/bin/env bash
# GPU recovery isolation check for the MacBook (daily-dcp-recovery-test kernel). Run as root from a TTY or ssh,
# with the Hyprland session up on the panel. Nothing here changes the system; it observes around one trigger.
#
#   recovery-test.sh TRIGGER-CMD [ARGS...]
#
# TRIGGER-CMD is the faulting client: a program, run as the session user, that makes the GPU firmware recover
# (the reproducer is not part of this directory; see REPORT.md). Its process name is what the dmesg check expects
# on the "client sees a lost device" line.
#
# Checks (PASS/FAIL per line, exit 0 only if all pass):
#   1 Hyprland survives: same pid before and after.
#   2 swaps continue: dcp:iomfb_swap_complete events in the 10 s after the trigger ended > 0, and the rate is
#     within half of the rate before (the panel runs 120 Hz; an idle desktop with VRR may swap less, so the
#     baseline is measured with vkcube running).
#   3 vkcube (bystander) is alive after, or exited on its own with an error (not a crash signal).
#   4 dmesg after the mark shows a recovery or a watchdog line, and "the client sees a lost device" ONLY for the
#     trigger's process name (never Hyprland, vkcube, quickshell, ...).
#   5 Hyprland's log has no new "Cannot commit when a page-flip is awaiting" line.
#   6 no RCU stall, hung task or apple-drm fence timeout lines (reported, the last one is a WARN not a FAIL).
set -u
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
[ $# -ge 1 ] || { sed -n 2,22p "$0"; exit 2; }
OUT=${OUT:-/root/recovery-test-$(date +%Y%m%d-%H%M%S)}; mkdir -p "$OUT"; chmod 700 "$OUT"
TRIG=("$@"); TRIG_NAME=$(basename "$1" | cut -c1-15)
HPID=$(pgrep -x Hyprland | head -1); [ -n "$HPID" ] || { echo "Hyprland not running"; exit 2; }
HUSER=$(ps -o user= -p "$HPID" | tr -d ' '); HUID=$(id -u "$HUSER")
HLOG=${HYPR_LOG:-$(ls -t /run/user/$HUID/hypr/*/hyprland.log 2>/dev/null | head -1)}
ENVF=/proc/$HPID/environ
asuser() { # run as the session user with the compositor's Wayland environment
  sudo -u "$HUSER" env $(tr '\0' '\n' < "$ENVF" | grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DISPLAY|MESA_LOADER_DRIVER_OVERRIDE|LD_LIBRARY_PATH|VK_ICD_FILENAMES|VK_DRIVER_FILES)=') "$@"
}
T=/sys/kernel/tracing; [ -d $T/events ] || mount -t tracefs nodev $T
EV=$T/events/dcp/iomfb_swap_complete
[ -d $EV ] || { echo "no dcp:iomfb_swap_complete tracepoint"; exit 2; }
swaps() { # count swap events over $1 seconds
  echo 0 > $T/tracing_on; echo > $T/trace; echo 1 > $EV/enable; echo 1 > $T/tracing_on
  sleep "$1"; echo 0 > $T/tracing_on; grep -c iomfb_swap_complete $T/trace; echo 0 > $EV/enable
}
log() { echo "$*" | tee -a "$OUT/summary.txt"; }
FAIL=0; pass() { log "PASS $*"; }; fail() { log "FAIL $*"; FAIL=1; }

log "kernel $(uname -r)  Hyprland pid $HPID user $HUSER  trigger '${TRIG[*]}'  log ${HLOG:-none}"
HLINES=$( [ -n "$HLOG" ] && wc -l < "$HLOG" || echo 0)
cat /sys/kernel/debug/dri/*/state > "$OUT/drm-state-before.txt" 2>/dev/null

asuser vkcube --wsi wayland > "$OUT/vkcube.log" 2>&1 & VK=$!
sleep 5
BASE=$(swaps 10); log "baseline: $BASE swaps in 10 s (vkcube pid $VK)"
MARK="recovery-test mark $(date +%s)"; echo "$MARK" > /dev/kmsg

asuser "${TRIG[@]}" > "$OUT/trigger.log" 2>&1; TRC=$?
log "trigger exited with $TRC"
sleep 2
AFTER=$(swaps 10); log "after: $AFTER swaps in 10 s"

dmesg | sed -n "/$MARK/,\$p" > "$OUT/dmesg-after.txt"
cat /sys/kernel/debug/dri/*/state > "$OUT/drm-state-after.txt" 2>/dev/null
[ -n "$HLOG" ] && tail -n +"$((HLINES + 1))" "$HLOG" > "$OUT/hyprland-new.log"

# 1
NOW=$(pgrep -x Hyprland | head -1)
[ "$NOW" = "$HPID" ] && pass "Hyprland alive, pid $HPID" || fail "Hyprland pid $HPID -> ${NOW:-none}"
# 2
if [ "$AFTER" -gt 0 ] && [ $((AFTER * 2)) -ge "$BASE" ]; then pass "swaps continue ($BASE -> $AFTER per 10 s)"
else fail "swaps $BASE -> $AFTER per 10 s"; fi
# 3
if kill -0 $VK 2>/dev/null; then pass "vkcube alive"; kill $VK; wait $VK 2>/dev/null
else wait $VK; RC=$?
  if [ $RC -ge 128 ]; then fail "vkcube died by signal $((RC - 128))"; else pass "vkcube exited cleanly ($RC)"; fi
fi
# 4
grep -E "G17: (GPU recovery|recovery gen)|recovery snapshot|Compute watchdog|render slot" "$OUT/dmesg-after.txt" > "$OUT/recovery-lines.txt"
[ -s "$OUT/recovery-lines.txt" ] && pass "recovery/watchdog lines: $(wc -l < "$OUT/recovery-lines.txt")" \
  || fail "no recovery or watchdog line after the mark (the trigger did not reach the GPU's recovery)"
grep "the client sees a lost device" "$OUT/dmesg-after.txt" > "$OUT/lost-device.txt"
OTHERS=$(grep -v "client $TRIG_NAME\[" "$OUT/lost-device.txt")
if ! grep -q "client $TRIG_NAME\[" "$OUT/lost-device.txt"; then fail "the trigger ($TRIG_NAME) did not see a lost device"
else pass "the trigger sees a lost device"; fi
[ -z "$OTHERS" ] && pass "no bystander saw a lost device" || { fail "bystanders lost their device:"; echo "$OTHERS" | tee -a "$OUT/summary.txt"; }
# 5
if [ -n "$HLOG" ] && grep -q "Cannot commit when a page-flip is awaiting" "$OUT/hyprland-new.log"; then
  fail "Hyprland: 'Cannot commit when a page-flip is awaiting' x$(grep -c 'page-flip is awaiting' "$OUT/hyprland-new.log")"
else pass "no stuck page flip in Hyprland's log"; fi
# 6
grep -E "rcu: INFO|rcu_preempt detected stalls|blocked for more than|hung_task" "$OUT/dmesg-after.txt" > "$OUT/stalls.txt"
[ -s "$OUT/stalls.txt" ] && fail "RCU stall / hung task lines: $(wc -l < "$OUT/stalls.txt") (stalls.txt)" || pass "no RCU stall or hung task"
grep -q "in-fence .* not signalled after" "$OUT/dmesg-after.txt" && log "WARN apple-drm dropped a stuck plane fence (expected only if a GPU fence wedged)"
grep -q "flip_done timed out" "$OUT/dmesg-after.txt" && log "WARN flip_done timed out (DCP did not complete a swap in 10 s; its event was failed)"
log "results in $OUT"; exit $FAIL
