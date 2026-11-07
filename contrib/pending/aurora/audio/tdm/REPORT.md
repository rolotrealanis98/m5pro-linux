# J716s speakers: `bad TDM clock` at stream stop, and the reboot after it (2026-11-07)

Studio only; nothing run on the MacBook, nothing posted or pushed. (Saved by the coordinator from the agent's hand-back.)
Base `j716s-series-audio` @ `32512dab5b4e` (the R3-AUDIO-B2 kernel). Worktree `/Volumes/linux-cs/wt-audio-tdm`, branch
`j716s-audio-tdm`: `fa23c99a6b49` (Ed's 83d711c3a909 carried), `030e2113e26b` (ours, the stop-order fix, = B3),
`7767a8193740` (ours, 0003: pwrd read-back before the unmute + stop-time state check; see section 10).
edimoldovan `t6050-j714c` tip `4f8b07f31d66`.

## 1. Bottom line
- None of Ed's commits fixes the stop-time fault: his tip stops the serializer in the same order as our port. The only Ed
  speaker commit we lacked is 83d711c3a909 (Left Woofer 1 sense alignment, speakersafetyd accuracy, unrelated to the clock).
- Cause: the AOP driver sends `pw0` to the speaker service from the work queued by the back-end's trigger STOP, which stops
  the serializer and the TDM clock at once. ASoC mutes the amps only later, in the back-end's hw_free (`soc_pcm_hw_clean`,
  `sound/soc/soc-pcm.c:1128`). tas2764 cannot mute on trigger (its mute sleeps on I2C; the trigger is atomic). For a few ms
  all six amps are unmuted without a clock and latch INT_LTCH0 bit 2. The 20 lines are a rate-limited burst of two call
  sites. The burst at `Speaker Switch` off is most likely the same latch again when DAPM rewrites PWR_CTRL
  (aurora-silicon/linux#663 saw it on J713).
- Fix (patch 0002): the service outlives STOP until the back-end's hw_free, which ASoC calls after muting the codecs, and
  `pw0` is sent there (capped at 100 ms; PAUSE_PUSH likewise; SUSPEND stops at once because `snd_soc_suspend` mutes first).
  Plus `apple,deferred-shutdown;` on the six amps so tas2764 treats a clock-only latch after the mute as expected.
- Harm: cosmetic for the hardware (section 6).
- Reboot hang: not caused by an audio reboot-time hook (there are none); the 30 s gap is the watchdog (section 7).

## 2. Mechanism at the end of `aplay -D plughw:AppleJ716,1`
1. Drain finishes, ALSA triggers STOP: `spkr_dai_trigger` clears `spkr_want_run`, queues `spkr_start_work` (`aop_t8140.rs`).
2. `spkr_go` sees the service running without `want_run` -> `spkr_retire` -> `pw0`: MCA serializer (BCLK/FSYNC) and sense
   drain stop.
3. aplay closes; BE hw_free -> `snd_soc_dai_digital_mute(codec, 1)` -> `tas2764_mute(1)`: MUTE, 6 ms ramp, software shutdown.
Between 2 and 3 the amps are ACTIVE with no clock: fault latched, shared level-low IRQ (AP GPIO 106). Our tas2764
suppresses a clock-only latch only while `stream_stopped` is set, which needs `apple,deferred-shutdown` (our DT lacked it).
Ed's TDM commits cover three other cases already in our port: 7818011b2ba8 (=0005), a97d98de3360 (=0006), 369cac02ce47
(=0010). None covers the stop. No issue/PR/comment anywhere mentions this fault; #663 is the opposite order on J713.

## 3. Ed's tip vs ours
- `t8140_aop_audio.rs`/`aop_t8140.rs`: speaker, sense and mic code identical (our 0004-0010 are his commits); only gap
  83d711c3a909 (`HwConfig.sense_late_current`). Rest of the diff is tree structure.
- `aop_audio.rs`: ours has the t6050 entry (0004). `aop_spkr.rs`: ours only (T6041), unused on T6050.
- `macaudio.c`: ours much newer; f21e1ea10bbd (J714 at gain 15, no ceiling) left out on purpose: J716 stays at -30 dB and
  level 10 until AID41 is measured. Neither tree touches the stop order.
- `tas2764.c`: Ed's is the older driver (no deferred-shutdown, no clock-fault suppression); ours is a superset. Neither
  mutes on trigger or has an I2C `.shutdown`.

## 4. Ported (`patches/`, format-patch 32512dab5b4e..j716s-audio-tdm)
- 0001 (ed, 83d711c3a909) unchanged; Co-Authored-By removed, port note and our Signed-off-by. `HW_T6050` is SoC-wide, so
  the J716 also takes "pair 0 current one frame late": check speakersafetyd LW1 vs LW2 power within a few % at 4-8 kHz.
- 0002 (Rolando Trevino): STOP/PAUSE_PUSH set `spkr_stop_grace`; `spkr_go` waits (without `spkr_lock`) up to
  `SPKR_STOP_GRACE_MS` = 100 ms for `spkr_release` (set by `flush_spkr_start` from hw_free, prepare or shutdown) or a new
  START, then retires. New speaker DAI `hw_free` op (playback, MCA stream only) flushes the work and retires under the lock
  after ASoC muted the codecs. Sense drain runs until `pw0`. T8140/LEAP unchanged.
- No assistant trailers in either patch. (The base series' 11 carried patches still have Ed's Co-Authored-By and
  `Assisted-by` on 0002/0011: strip when re-exported.)
- Left out: f21e1ea10bbd; J714c DT/config/USB commits; xrun recovery (stop + prepare without hw_free still retires and
  restarts under unmuted amps: one fault per xrun recovery remains possible); no tas2764 change.
- DT change needed: `dt/j716s-audio-spk-defer-notun-edp.dts` = spk DTS + `apple,deferred-shutdown;` on codec@38/39/3a
  (i2c@505014000) and codec@3b/3c/3d (i2c@50501c000). Order becomes: mute with clock running; `stream_stopped`, software
  shutdown 150 ms later; hw_free then `pw0`; clock-only latch cleared silently until the next unmute. Jack-only DTB unchanged.

## 5. Build
`build-tdm-container.sh` (Fedora 43 container, clang 21.1.8, rustc 1.99.1, aurora-bindgen, kbuild2's config seed), output
`~/Work/agents/audio-aurora/kbuild-tdm/`, exit 0, 0 warnings, `7.3.0-g030e2113e26b`; RUST, APPLE_AOP,
SND_SOC_APPLE_AOP_AUDIO, MACAUDIO, TAS2764 all =y.
| file | sha256 |
|---|---|
| Image.gz | bb553695ff0482a5f58a2aa4c92827862ac2905d73cae6dad475edaca1bd3aa9 |
| t6050-j716s-audio-spk-defer-notun-edp.dtb (use this) | 9783ccb640c8a2ecb5623f1b171861bd5c50f83259470122aa1003fe371cbceb |
| t6050-j716s-audio-spk-notun-edp.dtb (old B2 DTB) | 9dce1b4fca95107d64841871c09fa539c9a27797012ab5a9f6a234c425c58772 |
| t6050-j716s-audio-notun-edp.dtb (mic only, unchanged) | d69345c1d7b0f3c4ce5edd32b254bb6e9985a637b6a8951de49d18feaa2c97f3 |
| t6050-j716s.dtb (in-tree) | 8c4df67ac743a08b633f7e5233004180e5b18d9f82c56b9261ec76eb77458e6e |
The two unchanged audio DTBs rebuild to the recipe's hashes.

## 6. Can the fault damage the amps?
No. On a lost SBCLK/FSYNC the TAS2764/SN012776 stops its class-D output and latches the interrupt; it does not drive the
last sample or DC. Costs: an unramped click at real levels (nothing at -80 dB); garbage V/I sense at stream end (daemon
over-estimates, the safe direction); log noise hiding a real mid-stream clock fault; I2C IRQ traffic (re-latch about
every 10 ms on J713). Over-temperature/over-current (bits 0/1) are real; B2 logged only bit 2.

## 7. The reboot after B2
- No reboot-time audio code: tas2764 has no I2C `.shutdown` (component `.remove` only); macaudio, admac, cs42l84 `.remove`
  only; Rust AOP drivers unbind only, the Rust platform adapter has no shutdown callback; Ed's tree has none either.
- AOP EPIC calls time out after 5 s. `apple_wdt` sets a 30 s bite at probe; watchdogd pings every 15 s.
- Clean path: macsmc-reboot writes MBSE then `boot_stage = 0` (`macsmc-reboot.c:148-156`) before `device_shutdown()`.
  Boot-error count 1 means that step never completed.
- Timing: 361 s + 30 s + about 20 s to network = the 52 s observed: a whole-machine stall after SIGTERM and before or inside
  restart-prepare (CPU stuck on MMIO to a gated block, or a lock everyone waits on). If PID 1 owns the watchdog
  (`RuntimeWatchdogSec`), a userspace stall also fits: check `systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec`
  and `wdctl`. journald dies at SIGTERM, so the journal cannot place the hang. Audio state then: service retired, drain
  off, amps in software shutdown, speakersafetyd already stopped (lease timeout 359.8 s). Link to the fault unproven.
- Needed: tas2764 `callbacks suppressed` lines in the saved dmesg and `/proc/interrupts` twice 10 s apart after a tone; a
  screen photo/video through the reboot with `printk.devkmsg=on ignore_loglevel`; reboots (a) no tone, (b) tone, (c) tone
  then speakersafetyd stopped. Only after that: a defensive tas2764 I2C `.shutdown` and an AOP shutdown sending `pw0`.

## 8. Next test (B3 = B2 recipe with the new kernel and the defer DTB)
1. Gates: speakersafetyd running, then "Speaker volumes unlocked" and "ceiling -40 dB"; Amp Gain max 10; Mux = Secondary,
   Speaker Switch on.
2. `dmesg -w` in a second session, then the 2 s 1 kHz -40 dBFS six-channel tone through `plughw:AppleJ716,1`.
3. Expect no `bad TDM clock` at the end of the stream; `Speaker Switch` off should also stay quiet.
4. A/B: new kernel with the old spk DTB; faults that remain there are the post-shutdown re-latch.
5. If faults remain: timestamped dmesg; trace `tas2764_mute` and `spkr_dai_hw_free`.
6. Optional: LW1 vs LW2 sensed power at 4 and 8 kHz (for 0001). 7. The section-7 reboot test before calling it clean.

## 10. B3 result and the start-time burst (update 2026-11-07, after the B3 run)

B3 = kernel `7.3.0-g030e2113e26b` (Image.gz bb553695..., kept in `kbuild-tdm/b3-030e2113e26b/`) + the defer DTB.
- **Fixed:** no fault at the stream end (~154.9 s), none at `Speaker Switch` off. The switch-off fix is
  `apple,deferred-shutdown`. Whether there ever was a stop-time fault is in doubt after the B2 re-timing (see
  "Corrections" below).
- **Clean reboot:** a plain `systemctl reboot` after the tone was clean (23 s, boot-error count 0, primary slot). The B2
  stall did not reproduce with this kernel; the section-7 capture advice stands in case it comes back.
- **New:** a burst of `bad TDM clock` mid-stream: seven reports at 153.152-153.171, on both buses.

### Timeline, rebuilt from the code and the B3 numbers
- **pwrd sent, about 152.82 s.** speakersafetyd opened the sense PCM at its own start (1.88 s,
  `helpers::open_pcm`) and blocks in `readi` for 4096-frame blocks (85.3 ms). Sense data only flows once `spkr_start`
  has armed the drain and sent `pwrd`, at the back-end prepare. Its "Sample rate: 48000" line follows its first
  block. So `pwrd` went out at about 152.907 - 0.085 = 152.82 s.
- **Unmute and first TX DMA, about 152.84 s.** ASoC unmutes the six amps right after that prepare (pwrd + EPIC
  round trip + the fixed 20 ms). Trigger START, the first TX DMA, follows within milliseconds: aplay fills its buffer
  and starts.
- **Stream end, about 154.85 s.** That fits the coordinator's ~154.9 s.
- **Faults, 153.152-153.171 s.** That is about 0.31 s after the unmute, in the middle of the stream.
  - It is **not at the unmute**. An amp unmuted under a clock that is not running latches within about 10 ms.
  - It is **all six at once** on both I2C buses. The 20 ms spread is the threaded handlers reading six latch
    registers each over I2C. That points at the shared TDM clock from the AOP's serializer, not at a register write
    to one amp.

### Corrections from the coordinator (before B4), and what they change
- **B2 re-timed:** the first B2 fault is at 303.516 s, 0.1 s after speakersafetyd's "Sample rate" line (303.4 s).
  So **B2 had the same start burst**, and its "stop-time" reading was wrong: the rate limit hid the order.
  - The B2 `Speaker Switch`-off burst (358.6 s) was real. B3 had none: that one is removed by
    `apple,deferred-shutdown` (`stream_stopped` stays set after the stream).
  - Whether 0002 removed a real stop-time fault is unproven. B3 had rate-limit room left at the stream end (5 of 10
    lines used) and logged none. 0002's order (mute, then stop the clock) is still the right one.
- **The interrupt count is 25611, not 1032:** 1032 was CPU0's column; the row total is 25611 after about 160 s of
  uptime and one tone, about 160/s. The "clock lost for the rest of the stream" estimate (about 1020) is withdrawn.
- **New reading of the count:** about 160/s is roughly how fast the six threaded handlers can scan. Each interrupt
  costs six I2C latch reads per amp, about 36 reads, a few ms per cycle. So the line looks **held low continuously
  since the IRQ was requested at boot**, re-firing as soon as the oneshot thread unmasks it.
  - No fault line was logged before the tone, so every handler saw LTCH0 = 0 and returned IRQ_NONE. Nothing is
    latched in the only unmasked register: `INT_MASK0` = 0x00, `INT_MASK1-4` = 0xff, as in mainline (dd50f0e38563).
  - So this is most likely a **stuck-low or floating IRQ line**, not amp faults. That could be pin bias or a missing
    pull-up on AP GPIO 106, or an amp holding IRQZ low with nothing in LTCH0.
- **Consequences:**
  - The kernel's spurious-IRQ detector disables the line ("irq N: nobody cared", "Disabling IRQ #N") after about
    100k mostly-unhandled interrupts, about 10 min at this rate. After that the amps' fault reporting is off for the
    rest of the boot.
  - Until then the storm costs a CPU thread and about 5800 I2C reads/s on the two amp buses, even at idle. That
    matters for the WFI soak's idle and power numbers if the soak runs a speaker-DT kernel.
  - It is a plausible contributor to the B2 shutdown stall (I2C and IRQ-thread load through shutdown), not proven.
    B3's reboot at about 160 s was clean.
- **The start burst itself is unchanged.** It is a real LTCH0 clock latch on all six amps, 0.1-0.3 s after the sense
  data starts, and reproducible (B2, B3). 0003's two log lines remain the test for it: the pwrd read-back time, and
  the firmware state at stop.

### Patch 0003 (`patches/0003-ASoC-apple-aop_t8140-unmute-the-T6050-speakers-only-.patch`, commit 7767a8193740)
- **Start:** the `pwrd` request (property 202) returns before the firmware carries it out, and nothing checked it.
  `spkr_start` now reads the power state back (property 200, as `pw0` is already confirmed) every 2 ms until it reads
  `pwrd`, for at most 500 ms, and then keeps the 20 ms settle before ASoC unmutes. It logs
  `spkr: pwrd reached after N ms (M reads)`. If the state is unreadable or the wait times out, it falls back to the
  old fixed lead with a warning.
- **Stop:** before `pw0`, `spkr_check_still_pwrd` reads the state once more and warns
  `spkr: power state 0x... at the end of the stream, not pwrd: the firmware stopped it` if the firmware left `pwrd`
  on its own.
- **What the two log lines decide:**
  - pwrd takes about 300 ms: the amps were unmuted under a serializer that was not running yet, and 0003 is the fix.
  - pwrd is quick but the stop line fires: the firmware dropped the stream mid-run. The cause is then upstream of
    the amps (the sense drain or the TX side), and the fix is a 0004 once the data is in.
- **Scope:** MCA stream only (T6050); T8140/LEAP is unchanged. No change to tas2764, macaudio or the DT.
- **Build:** exit 0, 0 warnings, `7.3.0-g7767a8193740`.
  - Image.gz `f9129ccd7bfa29bb4a80772a7f05ca265d6b740fe65d19f6d489345441718908`.
  - DTBs unchanged: use the defer DTB `9783ccb6...`.
  - format-patch now numbers the series 1/3..3/3, so the 0001/0002 file hashes changed. Their content is identical.

### B4 additions after the corrections (all read-only)
- **Handled against unhandled:** `N=$(awk '/tas2764/{sub(":","",$1);print $1}' /proc/interrupts)`, then
  `cat /proc/irq/$N/spurious` together with the `/proc/interrupts` row total.
  - Take it at the same three points as the coordinator's deltas: before the tone, after it, and after 10 s idle.
  - count minus unhandled is the number of real latches. If unhandled is about the count, the line is stuck low with
    nothing latched.
- **Line level and bias:** `grep -i -A1 'gpio-106\b' /sys/kernel/debug/gpio` and
  `grep -E '^pin 106 ' /sys/kernel/debug/pinctrl/*/pinconf-pins /sys/kernel/debug/pinctrl/*/pins 2>/dev/null`.
  A level that reads low at idle confirms a stuck line.
- **Latch registers, live:**
  `for a in 0-0038 0-0039 0-003a 2-003b 2-003c 2-003d; do echo $a; grep -E '^(49|4a|4b|4f|50|51|5c):' /sys/kernel/debug/regmap/$a/registers; done`.
  - The latch and IRQ registers are volatile, so this reads the hardware. Caveat: reading may clear a latch.
  - It shows whether any amp holds something latched at idle. 0x5c bits 1:0 are the IRQZ pin mode.
- **Spurious-IRQ shutdown:** `dmesg | grep -E 'nobody cared|Disabling IRQ'`. Check the WFI-soak boot too, if it ran a
  speaker-DT kernel: the line should be disabled about 10 min in.
- Item 6 below: drop the "near 6000" expectation. With a storm the IRQ delta does not measure the clock; use the
  handled count from `spurious` instead.

### Next run (B4: kernel f9129ccd..., defer DTB, the B2/B3 recipe)
1. **Gates as before.** Then read `grep -i gpio /proc/interrupts` (the tas2764 line) **before and after** one 2 s
   -40 dBFS tone, and save the delta.
2. **The tone as before**, `time aplay -D plughw:AppleJ716,1 /tmp/t.wav 2>&1` (keep aplay's stderr, for "underrun"),
   with `dmesg -w` running.
3. **Collect** the `spkr: pwrd reached after` line, any `spkr: power state ... the firmware stopped it` line, and
   every tas2764 line with timestamps. Add `journalctl -u speakersafetyd` for the stream window: are there blocks after
   +0.3 s, any "Expected 4096 samples, got" or "Skipping" lines?
4. **Three tones, 5 s apart:** a burst at a fixed offset every time, or only on the first stream after boot?
5. **One tone with speakersafetyd stopped:** the volumes stay locked, so it is silent and safe. If the burst stays, the
   daemon's kcontrol writes and sense reads are not the trigger.
6. **Optional, one 10 s tone:** a single burst at +0.3 s with the IRQ delta near 6000 means the clock was lost for the
   whole stream; bursts every 0.68 s would mean something per drain-ring wrap.
7. **Reboot check:** the B3 boot after the clean reboot lost its network (coordinator investigating). 0003 adds nothing
   to the boot path: it acts only in the speaker back-end's prepare and stop.

## 9. For edimoldovan (after our run confirms 0002)
His stop path has the same order, so the J714c amps should fault at every stream end (ask whether PipeWire's idle suspend
hides it). 0002 applies to his tree with `aop_t8140.rs` renamed to `t8140_aop_audio.rs`; the deferred-shutdown half
needs #663's tas2764 commits, which his tree lacks. Ask whether LW1's late current is SoC-wide.
