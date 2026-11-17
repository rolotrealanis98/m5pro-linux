# J716s palm rejection: the Asahi commit, what Aurora has, what the J716s needs

Kernel branch: `j716s-trackpad` on `j716s-next6b` (11b0bc3d224d), worktree `/Volumes/m5pro/wt/trackpad`.
Patches here: `0001`-`0003` (git format-patch of that branch). Userspace:
`contrib/validated/desktop/trackpad/local-overrides.trackpad-kernel.quirks`. Owner test: `attended-test.sh`.

## The Asahi commit (d4f767712c, Yicong Hui, 2026-10-31)

"HID: magicmouse: ignore hovering touchpad contacts and report palm contacts", recorded on an M2 Max.
It names the first four bytes of the MTP contact record (`struct tp_finger`), which were two unknown words:

| byte | name | values |
|---|---|---|
| 0 | contact id | constant while the contact lasts |
| 1 | state | 0 not tracked, 1 first seen, 2 hovering, 3 touch down, 4 touching, 5 lifting, 6 after lift, 7 gone |
| 2 | class | 0 unclassified, 1 flat thumb, 2-5 fingertips, 7 palm; 10, 12 unknown |
| 3 | unknown | 0, 1 or 0xff |

Then, on every MTP trackpad:
1. **Hover filter:** report only records in state 3-5. Before, only records with zero touch area were dropped.
2. **Palm:** report class 7 as `MT_TOOL_PALM`, frame by frame, with no size check and no hysteresis.

## What Aurora already has (same file in `integration/aurora` and `j716s-next6b`)

- T6041 (6dd9b71d9834) and J616s (487934122866): class >= 6 **and** raw tool area > 1400, or (T6041 only)
  tool area > 2200, makes a contact `MT_TOOL_PALM` **until it lifts** (per-id bitmap). It reads the id and
  class from the same bytes Asahi names. No hover filter.
- K116s Trackpad26 frames (a68b43218e41): their own format. Already filters state 3-5 and reports class 7 as palm.
- J700 C1FE: separate unmerged branch `aurora/fix/j700-palm-rejection`. Not relevant here.
- Nothing for T6050/J716s: no `ABS_MT_TOOL_TYPE`, no hover filter. No newer trackpad change on any Aurora branch.

## What the J716s sends (hidraw, MTP firmware 6320.86.1, owner using the machine, ~8 min passive)

The J716s uses the standard 0x75 report (product 0x035a), not Trackpad26, and the bytes mean the same as on
the M2 Max.

| contact | where | classes | touch area (<<1, libinput units) | raw tool area |
|---|---|---|---|---|
| fingers | middle | 2, 3, 4 | 36-776 | 710-1435 |
| resting / clicking thumb | bottom edge | 1 | 182-694 | 1000-1360 |
| edge of a hand while typing | side edges, within ~6 mm | 6 (mostly), 7, 10 | 22-1632, mostly < 1450 | 870-1650 |

Findings:
- **Hover contacts reach libinput today.** A third of the contacts never touch down (hands hovering over the
  side edges while typing). In two minutes, 142 hovering/after-lift records were above libinput's 150:130
  touch-begin size, so libinput began touches on them.
- **Palms are invisible to libinput today.** No tool type; palms rarely pass the 1600 size threshold;
  edge palm zones are off for `ModelAppleTouchpad`; pressure is off (`INPUT_PROP_PRESSUREPAD`). Only
  disable-while-typing catches them. Palms that touched down slid up to 12 mm. A resting palm also counts
  as a finger for clickfinger, so palm + one-finger click comes out as a right click.
- **The controller classes J716s palms early.** Edge palms are class 6/7 while hovering or at touch-down,
  and no finger or thumb had class >= 6 before touching down. A thumb resting at the bottom edge was
  reclassed 1 → 12 → 7 after a second of touching (tool area 1160).
- **Neither existing rule fits.** Asahi's class-7-only rule misses class 6, the most common palm class here,
  and drops the palm flag frame by frame. libinput lets go of a palm when its tool type goes back to
  finger (`tp_palm_detect_tool_triggered`), so hysteresis matters. Aurora's tool area > 1400 floor misses
  most J716s palms, because they are smaller than T6041 palms and overlap fingers in tool area.
- **libinput's touch-size gate cuts real touches short.** 4 % of finger frames the controller calls
  touching have one axis under 130, which ends the touch in libinput.

## The branch

1. `HID: magicmouse: name the MTP contact record's ID, state and class bytes`: Asahi's names. No functional change.
2. `HID: magicmouse: drop hovering MTP contacts`: Asahi's hover filter for standard-report pads.
   `hid_magicmouse.mtp_hover_filter` (default Y, **runtime**). C1FE is skipped.
3. `HID: magicmouse: report the J716s trackpad's palms`: enables palms on `apple,j716s`. On the J716s, a
   contact classed >= 6 before it touches down as a finger or thumb is a palm at any size, until it lifts.
   A contact reclassified after touch-down still needs the tool floor, so the thumb above stays a touch.
   T6041/J616s keep their rules. Parameters:
   - `mtp_palm_class` (boot only): -1 the recorded machines, 0 off, 1 every standard-report MTP pad
     (replaces the old draft 0001).
   - `mtp_palm_early` (runtime): -1 machine default (on for J716s), 0 off (the T6041/J616s rule), 1 on.
   - `mtp_palm_tool_min` (runtime): floor for a mid-touch reclassification, -1 = 1400.

All runtime parameters live under `/sys/module/hid_magicmouse/parameters/`, so one kernel can A/B every
setting without rebooting. On the command line: `hid_magicmouse.mtp_palm_early=0` etc.

Dropped: the old draft 0002 (rounded resolution). It would move the published resolution from 98 to 99 u/mm,
and that silently rescales `curves.lua` (`M.RES = 98`) and every custom-curve preset, for a 0.5 % size gain.

## Userspace

- `local-overrides.trackpad-kernel.quirks`: install with the trackpad kernel. Sets `AttrTouchSizeRange`
  150:130 → 40:30, so libinput stops ending touches the controller says are on the pad (the hover
  filter now does the hover gating). The palm threshold stays 1600 as a backstop until the attended test
  measures flat-finger and pressed-thumb maxima. Thumb size stays unset (thumbs and fingers overlap).
  Do not use it on a kernel without the hover filter: hovering hands would become touches.
- `local-overrides.quirks` (today's kernel): values unchanged. Measured data added to its header.
- Hyprland presets: no change. Nothing palm-related is exposed beyond `disable_while_typing`, which stays on.

## Test build

- Kernel `7.3.0-g43ee66d45725` (branch head 43ee66d45725), built with `build-next.sh` (`kbuild-trackpad`).
  Clean compile, no new warnings. checkpatch only flags the `Co-Authored-By:` trailer form.
- Self-reverting boot file (`m5.selftest=1`, aura j716s-fix3-nohostwait loader, fsck-v3 initramfs):
  `/Volumes/m5pro/bench/pr-verify/trackpad-test-20261117-878a633e.bin`,
  sha256 `878a633e936be7d76a4e41b7edd17aa924e8f2eee864032aa2b7b1946a1961c4`.
- Modules for that release: `/Volumes/m5pro/bench/pr-verify/kbuild-trackpad/modules-7.3.0-g43ee66d45725.tar.zst`.
  Trackpad, dockchannel and Wi-Fi are built in. The `j716s-wifi-open` change is already in `j716s-next6b`.

## What needs the owner

The test files are staged on the MacBook in `~/trackpad-test/` (attended-test.sh, tp-contacts.py,
local-overrides.trackpad-kernel.quirks). About 12 minutes:

1. Today's kernel: `cd ~/trackpad-test && sudo bash attended-test.sh part1`. Seven 10 s steps: fingers,
   light taps, flat finger and thumb press, thumb click at the bottom edge, typing, palm rest, palm + click.
   Each step prints PASS/FAIL/CHECK, and it ends with the sizes for the quirks.
2. Boot the test file above.
3. `sudo bash attended-test.sh part2`: checks `ABS_MT_TOOL_TYPE`, then palm rest with libinput watching
   (`tool-palm` count, and did the pointer move), the same with `mtp_palm_early=0`, then typing with the
   hover filter on and off. The parameters are put back at the end.
4. If part 2 passes: `cp /etc/libinput/local-overrides.quirks ~/trackpad-test/local-overrides.quirks.orig`,
   then `sudo install -m644 ~/trackpad-test/local-overrides.trackpad-kernel.quirks /etc/libinput/local-overrides.quirks`,
   then log out and back in and use the machine normally. To undo, install the `.orig` file the same way. The
   test boot reverts to the daily on the next reboot, so put the `.orig` back before then.

Send back the `results-*` folders. They pick `AttrPalmSizeThreshold`, confirm the `AttrTouchSizeRange`
low value, and confirm or kill the early rule.

## Risks

- The early rule rests on about 8 minutes of passive recordings of one person's hands. A fingertip classed
  >= 6 while hovering would freeze the pointer for that touch. Part 1 steps 1-4 check this, and
  `mtp_palm_early=0` turns the rule off live.
- The hover filter also applies to T6041/J616s/M1/M2 standard-report pads (as in Asahi). Untested there
  in this tree. `mtp_hover_filter=N` turns it off.
- Palm contacts still count toward the kernel's summed click pressure. Resting palms measured at 43 g or
  less, against a 120 g click threshold.
