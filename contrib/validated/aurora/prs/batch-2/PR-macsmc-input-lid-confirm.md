Input: macsmc-input - confirm a lid-open report during system sleep

[Note for Rolando, delete before sending: HOLD per your call. The hold-back path (the spurious report) has not fired on hardware yet: the only run with the patch had no spurious event. Consider waiting for one lid sleep that logs "ignored" or "no wakeup" before sending.]

On the J716s (MacBook Pro 16-inch, M5 Pro) closing the lid starts an s2idle suspend through logind, and the system was awake again 0.7 s later. The SMC itself emits the lid-open event (`SMC HID Event: 03 00 01`, notification 0x72030001, the same bytes as a real opening) about 230 ms after the close while the lid stays shut; macsmc-input reports it as a hard wakeup, the suspend aborts and logind reads "Lid opened". With no suspend configured, close and open (`03 01 00` / `03 00 01`) track the lid faithfully, so the false report only comes on the sleep path.

During system sleep (between `.prepare` and `.complete`) this patch confirms a lid-open report against the SMC's `MSLD` key (the one probe reads the initial state from) and ignores one that comes within `lid_wake_settle_ms` (default 2000 ms, 0 restores today's behaviour) of the sleep's start, measured with CLOCK_BOOTTIME. A held-back report leaves SW_LID closed and `.complete` resynchronises it from `MSLD`. Every decision is logged with the event, the time into the sleep and `MSLD`.

**Tested on:** J716s, kernel = integration/aurora + the T6050 series + this patch, logind `HandleLidSwitch=suspend`, `SuspendState=mem` (s2idle). Lid closed for 30 s: `PM: suspend entry` -> `Timekeeping suspended for 39.477 seconds` -> `macsmc-input: lid open 72030001 at +40069 ms in sleep, MSLD=0: wakeup` -> resume -> `Lid opened.`, `suspend_stats` success 1 / fail 0, USB and Ethernet back. That run had no spurious report, so the confirm path was exercised and the hold-back path was not. It is now in our daily kernel. `drivers/input/misc/macsmc-input.o` builds with `W=1` (LLVM, arm64) on `integration/aurora` 4114f761f469; checkpatch `--strict` clean.

**Dependencies:** none.

**Open questions:**
- Linux never tells the SMC that the system is going to sleep (no PM callbacks in macsmc.c, no sleep key written), and the false lid-open looks like the SMC reacting to the AP's sleep path without that notice. Does Aurora know an SMC sleep-notify key (what macOS writes on sleep entry and exit)? That would be the real fix, and this filter could then go.
- Is a module parameter the right knob for the settle time, or would you prefer a fixed value?
