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

## 11. B4 result and patch 0004 (the speaker link format)

### B4 data
B4 = `7.3.0-g7767a8193740` (Image.gz f9129ccd..., kept in `kbuild-tdm/b4-7767a8193740/`) + the defer DTB.
- **Idle:** 0 interrupts and 0 unhandled in 10 s with no stream. The pin reads `in hi`. The stuck-line idea in §10 is
  withdrawn.
- **Every tone:** `spkr: pwrd reached after 0 ms (1 reads)` (the firmware reports the requested state at once, so
  the read-back cannot time pwrd). The first fault comes 35 ms later, which is the unmute.
- **Fault volume:** 635-641 interrupts per 2 s tone, all handled (590-722 "callbacks suppressed"). That is all six
  amps, every ~3 ms, for the whole stream. It is the same with speakersafetyd stopped, and there is none after the
  stream.
- **No firmware stop:** no "the firmware stopped it" line, so the firmware stayed in pwrd all through.

**Conclusion:** a static mismatch between the clock the serializer produces and how the amps sample it. It is not a
start or stop edge, not the daemon, and not the firmware dropping the stream.

### Mechanism
- **What the J716s firmware runs.** The J716s ADT gives the speaker serializer as
  `/arm-io/iop-audio-controller/audio-speaker/audio-speaker`
  `reg = 01020000 0c100100 001bb700 fa000100 30000100 3f000000 ff0f0000 060c1810 00002010`. Decoded, that is:
  - a 12 MHz bit clock (0x00b71b00);
  - a 250-bit frame (0xfa) at 48 kHz (0x30);
  - six 32-bit playback slots (mask 0x3f, 6 ch, slot 0x20);
  - twelve 16-bit sense slots (mask 0xfff, 12 ch, slot 0x10).

  For comparison, the jack's `audio-codec-output` reg has a 64-bit frame (0x40), and the MCA loopback is again
  12 MHz/250.
- **The match.** That is the J616s/J713 speaker link. `macaudio.c` runs those with `secondary_bclk_ratio = 250` and
  I2S, inverted frame clock, normal bit clock (`NB_IF`). The J616s commit (1ace6c6d50e8) says "One serializer carries
  all six SN012776 amps in a 250-bit frame at 12 MHz ... the amps take I2S with an inverted frame clock and a normal
  bit clock".
- **What our J716 entry did instead.** 0011, like Ed's J714 entry, took macaudio's default `IB_IF` and 256.
  `tas2764_set_fmt` with IB sets `TDM_CFG1` RX_FALLING and `TDM_CFG4` TX_RISING. The amps then sample FSYNC and SDIN
  on the edge the serializer launches them on. The frame length they measure jitters, and they latch "bad TDM clock"
  continuously.
- **Why the J714c may get away with it.** The same mismatch could pass on the 14" by timing margin and fail on the
  16". Ed's sense oddities would fit an edge problem: the words one bit early (a97d98de3360) and LW1's current one
  sample late (83d711c3a909). That is an inference; we have no J714c ADT.
- **The 250 vs 256 ratio** only changes the amps' idle-slot mask trim and the front end's slot count. The amps detect
  the frame length themselves.

### Answers to the coordinator's questions
1. **TDM config against the serializer:**
   - `TDM_CFG2`: RX slot 32-bit. RX word 24-bit for S24 playback; the boot-time sense hw_params writes 16, and the
     playback hw_params then sets 24.
   - `TDM_CFG3` RX slot: 0x00 LW1, 0x11 RW1, 0x22 LW2, 0x33 RW2, 0x44 LT, 0x55 RT, matching ADT `rx_slot` 0-5.
   - Sense slots: I at 4n, V at 4n+2 (8-bit units), 24 bytes = 12 x 16 bit, matching the ADT.
   - Slot geometry matches. The mismatch is the bit-clock edge (and the nominal 256 vs 250).
   - `lpai channel masks`/`pdm0 config` are the microphone path, unrelated. The AOP driver sends no speaker format to
     the firmware: `dai_accept_fmt`/`dai_accept_bclk_ratio` are no-ops, and the firmware takes its geometry from the
     ADT.
2. **4 vs 6 channels:** the J714c also has six amps (Ed's DT lists six codecs on dai-link@1). Neither config assumes 4.
   The frame the amps see is fixed by the firmware's ADT config whatever the PCM carries.
3. **A 2- or 4-channel stream is not a useful discriminator:** the bit clock, frame clock and slot layout the amps
   see stay the same, and the front end may refuse anything but 6 channels.

### Patch 0004 (`patches/0004-ASoC-apple-macaudio-run-the-J716-speakers-in-the-J61.patch`, commit e5a4712a3f0d)
- **What:** the J716 entry gets `.speaker_dai_fmt = I2S | CBC_CFC | GATED | NB_IF` and `.secondary_bclk_ratio =
  250`.
- **Speaker-only:** the new `speaker_dai_fmt` field applies to the speaker back-end only. On the J716 the jack shares
  the card, on a different 64-bit serializer whose format is unverified, so it keeps the default. Other machines are
  unchanged.
- **Effect on the amps:** `TDM_CFG1` bit0 goes 1 to 0 (RX on rising) and `TDM_CFG4` bit0 goes 0 to 1 (TX on
  falling). FRAME_START and the RX offset are unchanged.
- **Build:** exit 0, 0 warnings, `7.3.0-ge5a4712a3f0d`.
  - Image.gz `4be565d628f9d73c448af5a35488d3568eedb1a2cb2b3fd023743a127406f70a`.
  - DTBs unchanged: use the defer DTB `9783ccb6...`.
  - Patch sha256: 0001 5bfb01e8..., 0002 b48b3968..., 0003 1a2e28af..., 0004 4ed00341... (renumbered 1/4..4/4).
- **Risk:** the sense alignment (0006's one-bit re-slice, 0001's LW1 frame delay) was measured by Ed under IB. With
  NB it may shift.
  - If it is wrong, speakersafetyd reads negative power and panics. The volumes then lock, so the failure is silent
    and safe.
  - If that happens, the next step is to adjust the re-slice for the J716, not to revert 0004.

### Registers to read (B4 kernel now, B5 with 0004)
Read during a tone and at idle with
`for a in 0-0038 0-0039 0-003a 2-003b 2-003c 2-003d; do echo $a; grep -E '^(02|03|08|09|0a|0c|0d|0e|0f|49|4a|4b|4f|50|51|5c):' /sys/kernel/debug/regmap/$a/registers; done`.
Non-volatile registers come from the cache (what the driver wrote); 49-51 and 5c are read live.

| reg | what | B4 (IB_IF) expected | B5 (0004) expected |
|---|---|---|---|
| 08 | TDM_CFG0 (rate, FRAME_START) | 0x08 | 0x08 |
| 09 | TDM_CFG1 (RX offset bits 5:1, RX edge bit0) | 0x03 | **0x02** |
| 0a | TDM_CFG2 (RX word bits 3:2, RX slot bits 1:0) | RXW 24, RXS 32 | same |
| 0c | TDM_CFG3 (RX slot) | 0x00/0x11/0x22/0x33/0x44/0x55 | same |
| 0d | TDM_CFG4 (TX edge bit0, TX offset) | bit0 = 0 | **bit0 = 1** |
| 0e/0f | TDM_CFG5/6 (V/I sense slot, enable bit6) | V = 4n+2, I = 4n | same |
| 02/03 | PWR_CTRL / CHNL_0 (amp level) | | |
| 49-51, 5c | latches, IRQZ mode | LTCH0 bit2 during a tone | 0 during a tone |

### Next test (B5: kernel 4be565d6..., defer DTB, B4 recipe)
1. Gates as before. Take `/proc/irq/$N/spurious` and the row total before the tone.
2. The same 2 s -40 dBFS tone through `plughw:AppleJ716,1`, with `dmesg -w`.
3. **Pass:**
   - the IRQ delta near 0 (at most a handful in the stop window);
   - no `bad TDM clock`;
   - speakersafetyd stays active with no panic;
   - the register table shows 09 = 0x02 and 0d bit0 = 1.
4. **V/I sanity:** a 1 kHz tone on one speaker at a time. speakersafetyd should not panic, and the group gain stays
   nominal at -40 dB.
5. **If faults remain:** first confirm the edge changed in the table. The next suspects are then FRAME_START and the
   RX offset (TDM_CFG0 bit0, TDM_CFG1 bits 5:1).

**Optional discriminator on the B4 kernel, no new boot.** This is a hardware register write behind the driver; skip
it if hand-writing amp registers is not acceptable.
1. During a tone, flip one amp's edges.
2. First check the page: `i2cget -f -y 0 0x38 0x00` must print 0x00.
3. Then `i2cset -f -y 0 0x38 0x09 0x02` and `i2cset -f -y 0 0x38 0x0d $(( $(i2cget -f -y 0 0x38 0x0d) | 1 ))`.
4. 0-0038 should then be the one amp missing from the fault lines of the next tone.
5. To undo, write back 0x03 and the old 0x0d value, or reboot.

## 12. B5 passed; registers; the B6 audible plan; PipeWire; the audio kernel candidate

### B5 result
B5 = `7.3.0-ge5a4712a3f0d` + defer DTB.
- **Faults:** 0 `bad TDM clock` in three tones (one with the daemon stopped) and a switch-off.
- **Interrupts:** amp IRQ +11/+20/+15/+13 per tone (B4 about +638), idle +0.
- **Daemon:** speakersafetyd up.

### (1) Residual interrupts and the registers
- **The 11-20 interrupts per tone** are the expected stream-end latches (the aurora-silicon/linux#663 behaviour).
  - With 0013 the amps mute first (6 ms ramp), the back-end's hw_free then sends pw0, and the clock stops under muted
    amps.
  - A muted amp re-latches the clock-only fault about every 10 ms until its deferred shutdown (150 ms), and once more
    after it. With `apple,deferred-shutdown` `stream_stopped` is set, so the handler clears each latch silently
    (IRQ_HANDLED, nothing logged).
  - One shared-line interrupt serves every amp latched at that moment, hence about 10-20 rather than 6 x 15.
  - Harmless; it costs a few I2C reads per stream end. The idle +0 confirms nothing fires between streams.
- **0x4a (INT_LTCH1) = 0x02, bit 1:** I cannot name this bit from the material I have; the driver and headers define
  no bits for LTCH1. TI's TAS2764 datasheet register map is needed to name it. What is certain:
  - `INT_MASK1` = 0xff, so this register can never pull IRQZ or reach the handler.
  - It reads 0x02 on all six amps in every run (B2's fault contexts `02,19,00,00,04` already had it), with and without
    the clock faults, so it does not follow the TDM state. In contrast, 0x4b went from 0x19/0x39 during the faults to
    0x00 now.
  - So it is a static status of the amp's supply or mode configuration. A VBAT-side indication is plausible, since the
    driver's quirk set runs the SN012776 in its PVDD-derived VBAT mode (`TAS2764_CONV_VBAT_PVDD_MODE`). That is a
    guess, unverified.
  - The amps play and their sense is used, so it does not block anything. Action: name it from the datasheet before
    any fault-handling change.
- **0x5c (INT_CLK_CFG) = 0x19:** the power-on default (`tas2764_reg_defaults` `{ TAS2764_INT_CLK_CFG, 0x19 }`). Bit 2
  (IRQZ_CLR) self-clears and reads 0, which shows the clears land. Nothing abnormal.
- **The other registers confirm 0015 took effect:**
  - `0x09` = 0x02: RX on the rising edge, RX offset 1 (I2S).
  - `0x0d` = 0x13: bit0 = 1 is TX on the falling edge; bits 3:1 = 001 is TX offset 1, Ed's "reset TX offset"; bit4 is
    the reset default.
  - `0x0a` = 0x1a: RX word 24 bits, RX slot 32 bits, ASI1 source "Left".
  - `0x0c`: RX slots 0x00/0x22/0x44 (LW1/LW2/LT) and 0x11/0x33/0x55 (RW1/RW2/RT), exactly the ADT `rx_slot` 0-5.
  - `0x08` = 0x08: 48 kHz, FRAME_START 0.

### (2) B6: audible test at `snd_soc_macaudio.speaker_max_db=-30` (payload audio-b6-20261107; Rolando listening)
**Why it is safe:** amp level 10 is 16 dBV, about 6.3 Vrms at digital full scale. The kernel ceiling of -30 dB caps
every digital level at about 0.2 Vrms, about 10 mW into 3.4-4.5 ohm. speakersafetyd's limits are 0.89 W per woofer and
0.59 W per tweeter, so even 0 dBFS stays near 2% of the tweeter limit. Use 1 kHz everywhere: no low frequencies into the
tweeters on the raw device.

**Channel map** (FE channel n = TDM slot n, confirmed by `0x0c`): 0 LW1, 1 RW1, 2 LW2, 3 RW2, 4 LT, 5 RT.

**Before sound (root):**
```
dmesg | grep -E 'Speaker volume ceiling|Speaker volumes (un)?locked'    # ceiling -30 dB, unlocked after the daemon
systemctl is-active speakersafetyd
amixer -c AppleJ716 sget 'Left Woofer 1 Amp Gain Volume' | tail -1      # max 10
# debug output (per-speaker power and temperatures every 85 ms):
mkdir -p /etc/systemd/system/speakersafetyd.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/speakersafetyd -c /usr/share/speakersafetyd/ -m 7 -v\n' \
  > /etc/systemd/system/speakersafetyd.service.d/b6-debug.conf
systemctl daemon-reload && systemctl restart speakersafetyd
dmesg | tail -3                                   # "Speaker volumes unlocked" again after the restart
N=$(awk '/tas2764/{sub(":","",$1);print $1}' /proc/interrupts); cat /proc/irq/$N/spurious
systemctl --user -M rolo@ stop wireplumber pipewire pipewire-pulse 2>/dev/null || true   # free the PCM
amixer -c AppleJ716 cset name='Speaker Playback Mux' Secondary; amixer -c AppleJ716 cset name='Speaker Switch' on
cd /tmp
for l in 30 20 12 6 0; do sox -n -r 48000 -c 6 -b 16 t$l.wav synth 2 sine 1000 gain -$l; done
sox -n -r 48000 -c 1 -b 16 m.wav synth 2 sine 1000 gain -12
for n in 0 1 2 3 4 5; do m=""; for i in 0 1 2 3 4 5; do [ $i = $n ] && m="$m 1" || m="$m 0"; done; sox m.wav ch$n.wav remix $m; done
sox -n -r 48000 -c 1 -b 16 m0.wav synth 10 sine 1000 gain 0
sox m0.wav left.wav remix 1 0 1 0 1 0; sox m0.wav right.wav remix 0 1 0 1 0 1
```
In a second SSH session, keep running:
`journalctl -u speakersafetyd -f -o short-monotonic | grep -vE 'SKIP'` and `dmesg -w | grep -E 'tas2764|spkr|macaudio'`.

**Steps, in order, 5 s apart.** After each, note the IRQ delta, the fault lines and what Rolando hears.
1. **Six channels at -30, -20, -12, -6, then 0 dBFS:** `aplay -D plughw:AppleJ716,1 t30.wav` and so on. Expect a faint
   1 kHz at -30 rising to quiet-but-clear at 0 dBFS, from both sides, with no buzz or crackle.
   - The daemon prints each speaker's line with Power below 0.02 W, the coil within a few tenths of a degree of its
     start (50 C cold boot), and no "gain limited".
2. **Channel identification at -12 dBFS:** `aplay -D plughw:AppleJ716,1 ch$n.wav` for n = 0..5. Rolando names
   left/right and woofer/tweeter for each; expect LW1 RW1 LW2 RW2 LT RT in that order. Tweeters are smaller and
   brighter, but 1 kHz reaches both kinds.
3. **Left against right sensed power (ROOT-SETUP §5 is_scale/vs_scale):** play `left.wav` (10 s, 0 dBFS, LW1+LW2+LT),
   wait 30 s, then `right.wav`.
   - From the daemon's debug lines take each speaker's **Power** during the tone and the **Coil** temperature rise
     (end minus start). At about 10 mW the Power column reads 0.01; the coil rise (about 0.1-0.3 C) separates 4x
     cleanly.
   - Compare RW1 with LW1, RW2 with LW2, RT with LT.
   - **Right reads about 4x left** (power about 4x, coil rise about 4x): the J714c i2c3 doubling. Set
     `is_scale = 1.875` and `vs_scale = 7` in the three `[Speaker/Right ...]` sections of
     `/usr/share/speakersafetyd/apple/j716.conf`, `systemctl restart speakersafetyd`, and repeat step 3; expect equal.
   - **Equal within about 30%:** leave the file.
   - **Left reads about 4x right:** report; change nothing.
   - **LW1 against LW2** (the 0012 check): within about 30%. A large gap means the late-current correction is wrong for
     the J716 under the new edge.
4. **Clean up:** `rm /etc/systemd/system/speakersafetyd.service.d/b6-debug.conf; systemctl daemon-reload; systemctl
   restart speakersafetyd`.

**Stop rules (any one: `amixer -c AppleJ716 cset name='Speaker Switch' off`, Ctrl-C the aplay, report):**
- **Amp faults:** any `tas2764 ... fault:` line, or an amp IRQ delta above about 50 for one tone.
- **Daemon:** a speakersafetyd panic, restart, `Panic!`, `gain limited` (impossible at these powers unless the sense is
  wrong), a negative Power, or any Power above 0.05 W.
- **Sound:** distortion, buzz, crackle, sound that continues after the tone, a driver silent in the six-channel tone,
  or sound from the wrong place in step 2.
- **Anything else unexpected (smell, heat, a loud pop):** hold the power button.

### (2b) PipeWire with the protective graph for user `rolo`
- **The UCM failure.** The test name was most likely wrong. `alsaucm -c AppleJ716` passes the card id. alsa-lib
  matches a plain name against the card *name* ("MacBook Pro J716"), not the id, then falls back to a legacy file
  `ucm2/AppleJ716/AppleJ716.conf`, hence -2 (ENOENT). PipeWire opens UCM as `hw:N`, which resolves through the card's
  driver and long name to `ucm2/conf.d/macaudio/MacBook Pro J716.conf`.
- **Check as root:**
  ```
  pacman -Q alsa-lib alsa-ucm-conf alsa-ucm-conf-asahi pipewire wireplumber lsp-plugins-lv2
  ls /usr/share/alsa/ucm2/ucm.conf "/usr/share/alsa/ucm2/conf.d/macaudio/MacBook Pro J716.conf" \
     /usr/share/alsa/ucm2/conf.d/macaudio/laptops/HiFi.conf /usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf
  alsaucm -c hw:AppleJ716 list _verbs                       # HiFi
  alsaucm -c hw:AppleJ716 set _verb HiFi list _devices      # Speaker, Headphones, Headset
  alsaucm -c "hw:AppleJ716AOP" list _verbs                  # the AOP mic card (t8140-aop-audio/... file)
  ```
  The `set _verb` only sets the two playback muxes.
- **If `hw:` still fails:** run `strace -f -e trace=openat alsaucm -c hw:AppleJ716 list _verbs 2>&1 | grep ucm2` to see
  the path alsa-lib looks for.
  - `ucm.conf` missing: alsa-ucm-conf-asahi ships only `conf.d/`, so `pacman -S alsa-ucm-conf`.
  - A different directory or name: install our file under the name it asks for. The card driver is `macaudio` and the
    long name "MacBook Pro J716".
- **The WirePlumber fragment had two gaps.** It relied on asahi-audio's `99-asahi.conf`, which is not installed: that
  file renames `hw:AppleJ716,1` to `alsa_output.platform-sound.RawSpeakers`, the node our `graph.json` targets, and
  enables WirePlumber's `node.software-dsp`.
  - The fragment is now self-contained: rename (48 kHz only), software-dsp rule, `wireplumber.profiles` main
    `node.software-dsp = required`.
  - Install the new `userspace/asahi-audio/99-asahi-j716.conf` (also in `~/Work/agents/audio-aurora/userspace/`) to
    `/usr/share/wireplumber/wireplumber.conf.d/`.
  - The graph uses `lsp-plugins-lv2` (compressor_stereo).
- **As rolo** (a logged-in session, or `loginctl enable-linger rolo` first for an SSH-only test):
  ```
  systemctl --user restart pipewire pipewire-pulse wireplumber
  wpctl status | sed -n '/Sinks:/,/Sources:/p'     # "MacBook Pro J716 Speakers (bring-up)"; no Raw Speaker Device
  journalctl --user -u wireplumber -b --no-pager | grep -iE 'j716|software-dsp|filter|lv2|error' | tail -20
  pw-dump | grep -E '"api.alsa.path"|RawSpeakers' | sort -u    # hw:AppleJ716,1 must be there (UCM Speaker device)
  ```
- **Root checks while PipeWire runs:**
  - `dmesg | tail` should show no faults.
  - speakersafetyd should still be active. udev's `ACP_IGNORE` keeps PipeWire off the sense PCM, D2c.
  - `amixer -c AppleJ716 sget 'Speaker Switch'` should be on: UCM's Speaker device enable sets it.
- **First pw-play (as rolo), quiet first:**
  ```
  wpctl set-default $(wpctl status | awk '/J716 Speakers/{gsub(/[^0-9]/,"",$2); print $2; exit}')
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.30
  sox -n -r 48000 -c 2 -b 16 /tmp/st.wav synth 3 sine 440 gain -20 ; pw-play /tmp/st.wav
  sox -n -r 48000 -c 2 -b 16 /tmp/pn.wav synth 5 pinknoise gain -25 ; pw-play /tmp/pn.wav
  ```
  - Expect the 440 Hz mostly from the woofers (the graph high-passes the tweeters at 2 kHz). Pink noise should come
    from all six drivers.
  - Everything is quieter than the raw test: graph -10 dB, the -30 dB kernel ceiling, and the sink at 30%.
  - Then a music file at the same volume, while watching dmesg and the daemon.
  - Same stop rules as B6.
  - If the sink is missing, send the wireplumber journal and the `pw-dump` paths.

### (3) The audio kernel candidate
- **Branch:** `j716s-series-audio` (worktree `/Volumes/linux-cs/wt-aurora-audio2`) was rebuilt as 15 commits on
  `j716s-series` `4f630b11270d`: the 11-patch port plus tdm 0001-0004. The old tip is kept as branch
  `j716s-series-audio-pre-tdm` (`32512dab5b4e`).
- **Trailers:** every message ends with `Signed-off-by: Rolando Trevino <rolotrealanis@gmail.com>`. All Co-Authored-By
  and Assisted-by lines were removed, including the "Assisted-by: LLM" inside 0003's port note. Ed keeps authorship of
  his ten commits; ours are authored by Rolando Trevino.
- **Corrected messages:**
  - 0013 (stop order) no longer claims B2's faults were stream-end faults.
  - 0014 (renamed "check the T6050 speaker service's power state") drops the withdrawn 0.3 s and 1032-interrupt
    reading and states that pwrd reads back at once.
  - 0015 adds the B5 result.
- **Tree:** identical to B5's `e5a4712a3f0d`; code is unchanged.
  - HEAD `c963af7d14b9`; `7.3.0-gc963af7d14b9`, built with `build-candidate-container.sh` into
    `~/Work/agents/audio-aurora/kbuild-cand/`, 0 warnings.
  - Image.gz `8bd74699a6773e75877123842bf54a85842c48696f4df88105a7ffa43bea826d`.
- **DTBs:**
  - `mk-audio-dtb.py` adds `apple,deferred-shutdown` to the spk variant. The regenerated
    `t6050-j716s-audio-spk-notun-edp.dtb` = `9783ccb6...`, byte-identical to the B5 defer DTB.
  - A = `d69345c1...`, in-tree `t6050-j716s.dtb` = `8c4df67a...`.
- **Patches:**
  - The candidate series `patches/candidate/0001-0015`; the tdm subset as `patches/0001-0004` (0003 renamed to
    `check-the-T6050-speaker-service`).
  - Mirrored to `contrib/pending/audio/aurora/patches/kernel-audio/` (with `SHA256SUMS`) and `tdm/patches/`.
- **Repo docs updated:**
  - `ANALYSIS.md` §0 (the post-B5 state).
  - `FIXES.md` (hardware-run fixes).
  - `R3-AUDIO-RECIPE.md` §0, the 0012-0015 rows, the spk DTB hash and the failure rows.
  - Also `mk-audio-dtb.py`, `dt/j716s-audio-spk-notun-edp.{dts,dtb}` and `userspace/asahi-audio/99-asahi-j716.conf`.
  - Nothing is committed.
- **Not changed:** `mk-r3audio.py` still pins the old kbuild kernel. Payloads are built with the coordinator's own
  tooling now.

## 9. For edimoldovan (after our run confirms 0002)
- The J716s faults came from the speaker link format: his J714 entry has the same `IB_IF`/256 defaults. If the J714c
  ADT shows the same `fa00` 250-bit frame, 0004's format may also explain his one-bit sense shift and the LW1 delay.
  Ask him to read `/arm-io/iop-audio-controller/audio-speaker/audio-speaker` `reg`.

His stop path has the same order, so the J714c amps should fault at every stream end (ask whether PipeWire's idle suspend
hides it). 0002 applies to his tree with `aop_t8140.rs` renamed to `t8140_aop_audio.rs`; the deferred-shutdown half
needs #663's tas2764 commits, which his tree lacks. Ask whether LW1's late current is SoC-wide.
