# J716s speakers: `bad TDM clock` at stream stop, and the reboot after it (2026-11-07)

Studio only; nothing run on the MacBook, nothing posted or pushed. (Saved by the coordinator from the agent's hand-back.)
Base `j716s-series-audio` @ `32512dab5b4e` (the R3-AUDIO-B2 kernel). Worktree `/Volumes/linux-cs/wt-audio-tdm`, branch
`j716s-audio-tdm`: `fa23c99a6b49` (Ed's 83d711c3a909 carried), `030e2113e26b` (ours, the stop-order fix).
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

## 9. For edimoldovan (after our run confirms 0002)
His stop path has the same order, so the J714c amps should fault at every stream end (ask whether PipeWire's idle suspend
hides it). 0002 applies to his tree with `aop_t8140.rs` renamed to `t8140_aop_audio.rs`; the deferred-shutdown half
needs #663's tas2764 commits, which his tree lacks. Ask whether LW1's late current is SoC-wide.
