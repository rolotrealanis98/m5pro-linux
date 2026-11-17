#!/usr/bin/env bash
# Attended trackpad palm test for the J716s. About 12 minutes, hands on the pad.
#
#   part1  any kernel (today's too): the controller's classes for deliberate fingers, thumbs and
#          palms, and the sizes the libinput quirks need. 7 steps x 10 s.
#   part2  j716s-trackpad kernel only: what libinput does with the kernel's palms, and A/B of the
#          runtime parameters. 4 steps x 15 s.
#
# Run from the folder holding this script and tp-contacts.py:
#   sudo bash attended-test.sh part1     (then, once booted on the trackpad kernel)
#   sudo bash attended-test.sh part2
# Results land in ./results-<part>-<time>/ ; send that folder back. Each step prints PASS/FAIL.
# Read-only: nothing is installed; part2 changes /sys/module/hid_magicmouse/parameters values and
# puts them back at the end (a reboot also resets them).
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
P=/sys/module/hid_magicmouse/parameters
EV=$(for e in /sys/class/input/event*; do grep -qx "Apple MTP multi-touch" "$e/device/name" 2>/dev/null && echo "/dev/input/${e##*/}"; done | head -1)
case "${1:-}" in part1|part2) ;; *) echo "usage: sudo bash $0 part1|part2"; exit 1 ;; esac
if [ "$1" = part2 ] && [ ! -e $P/mtp_hover_filter ]; then
  echo "not the trackpad kernel (no $P/mtp_hover_filter)"; exit 1
fi
OUT=results-$1-$(date +%H%M%S); mkdir -p "$OUT"
[ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"

flush() { while read -r -t 0.05 -n 4096 _ 2>/dev/null; do :; done; }   # drop typed test text
ask() { echo; echo "== $1"; echo "   $2"; flush; read -r -p "   Hands ready? Press Enter, then start (${3}s)... " _; }
verdicts() { grep -E "^# contacts:" "$OUT/tp-$1.txt" | sed 's/# contacts: //'; }
count() { grep -cE "  $2\$" "$OUT/tp-$1.txt"; }

record() {  # label seconds
  ( cd "$OUT" && python3 -I ../tp-contacts.py --seconds "$2" --label "$1" > /dev/null )
  flush; echo "   recorded: $(verdicts "$1")"
}
expect_fingers() {  # label: every touching contact must stay a finger
  local p; p=$(( $(count "$1" palm-early) + $(count "$1" palm-size) ))
  [ "$p" = 0 ] && echo "   PASS: no finger or thumb taken for a palm" \
               || echo "   FAIL: $p finger/thumb contacts taken for palms (see $OUT/tp-$1.txt)"
}
expect_palms() {  # label: the hand contacts must be palms
  local p f; p=$(( $(count "$1" palm-early) + $(count "$1" palm-size) )); f=$(count "$1" finger)
  [ "$p" -gt 0 ] && [ "$f" = 0 ] && echo "   PASS: $p palm contacts, none left as fingers" \
    || echo "   CHECK: $p palms, $f contacts left as fingers (FAIL if your fingers did not touch; see $OUT/tp-$1.txt)"
}

part1() {
  ask "1/7 fingers" "One fingertip: move the pointer around the middle, then two-finger scroll." 10
  record fingers 10; expect_fingers fingers
  ask "2/7 light" "Feather-light: tiny taps and slow, barely-touching drags with one fingertip." 10
  record light 10; expect_fingers light
  ask "3/7 flat" "Flat finger (pad, not tip) dragged around, then a flat thumb pressed until it clicks." 10
  record flat 10; expect_fingers flat
  ask "4/7 thumb" "Rest your thumb on the bottom edge and click with it, while the index finger moves the pointer." 10
  record thumb 10; expect_fingers thumb
  ask "5/7 typing" "Type normally into this window (the text is discarded), hands where they usually rest. Do NOT touch the pad with fingers." 10
  record typing 10; expect_palms typing
  ask "6/7 palm rest" "Rest the left palm heel on the pad's left side 3 s, then the right one on the right side 3 s, rocking slightly." 10
  record palmrest 10; expect_palms palmrest
  ask "7/7 palm + click" "Right palm resting on the pad; with the left index finger move the pointer and click a few times." 10
  record palmclick 10
  echo "   Note whether the clicks came out as left or right clicks. On today's kernel a resting palm"
  echo "   counts as a second finger, so right clicks here are the bug the trackpad kernel fixes."
  echo; echo "== sizes for the quirks (fingers, steps 1-4):"
  cat "$OUT"/tp-{fingers,light,flat,thumb}.txt | grep -E "^# finger " | sed 's/^/   /'
  echo "   AttrPalmSizeThreshold: ~1.25x the largest tMaj/tMin max above."
  echo "   AttrTouchSizeRange (trackpad kernel): low below the smallest 'smallest axis while touching'."
}

# libinput debug-events opens only the trackpad, so disable-while-typing never fires in it: the
# counts show the kernel's palms and the hover filter alone.
watch_libinput() {  # label seconds: count libinput palm and touch decisions while recording
  timeout "$2" libinput debug-events --verbose --device "$EV" > "$OUT/li-$1.txt" 2>&1 &
  record "$1" "$2"; wait
  echo "   libinput: tool-palm $(grep -c 'palm detected (tool-palm)' "$OUT/li-$1.txt"), touch-size palm $(grep -c 'palm detected (touch size)' "$OUT/li-$1.txt"), touches begun $(grep -c 'touch-size: begin touch' "$OUT/li-$1.txt"), pointer events $(grep -c 'POINTER_MOTION' "$OUT/li-$1.txt")"
}

part2() {
  local hf pe tm; hf=$(cat $P/mtp_hover_filter); pe=$(cat $P/mtp_palm_early); tm=$(cat $P/mtp_palm_tool_min)
  trap 'echo "$hf" > $P/mtp_hover_filter; echo "$pe" > $P/mtp_palm_early; echo "$tm" > $P/mtp_palm_tool_min' EXIT
  grep -H . $P/mtp_* | tee "$OUT/params.txt"
  libinput record -o "$OUT/record-header.yml" "$EV" & sleep 1; kill $! 2>/dev/null; wait 2>/dev/null
  grep -q "ABS_MT_TOOL_TYPE" "$OUT/record-header.yml" && echo "PASS: ABS_MT_TOOL_TYPE present" || echo "FAIL: no ABS_MT_TOOL_TYPE (mtp_palm_class?)"

  ask "A palm rest, defaults" "Same as part 1 step 6: left palm heel on the left side 3 s, right on the right side 3 s, rocking. Watch the pointer." 15
  watch_libinput palm-default 15
  echo "   PASS if tool-palm > 0 and the pointer did not move."
  ask "B palm rest, mtp_palm_early=0" "Same hands again (now the old T6041/J616s rule)." 15
  echo 0 > $P/mtp_palm_early; watch_libinput palm-noearly 15; echo "$pe" > $P/mtp_palm_early
  echo "   Expected: fewer tool-palm than A, and the pointer may move. That is the difference the patch makes."
  ask "C typing, hover filter ON" "Type normally into this window for 15 s, no fingers on the pad." 15
  watch_libinput type-hover-on 15
  ask "D typing, hover filter OFF" "Same typing again." 15
  echo N > $P/mtp_hover_filter; watch_libinput type-hover-off 15; echo "$hf" > $P/mtp_hover_filter
  echo "   Expected: 'touches begun' and 'pointer events' lower in C than in D."
  echo; echo "Then: use the machine normally for a few minutes. Optional, to tune live:"
  echo "   echo 1100 | sudo tee $P/mtp_palm_tool_min   # stricter mid-touch palm floor (default 1400)"
  echo "   echo -1   | sudo tee $P/mtp_palm_tool_min   # back to default"
}

"$1"
[ -n "${SUDO_UID:-}" ] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"
echo; echo "Results: $PWD/$OUT"
