# J716 speaker profile: listening test

For Rolando, at the MacBook. About 30 minutes. The profile is staged and not active; this test turns it on, compares
it with the bring-up graph, and decides what stays.

Safety stays where it is for the whole test: the kernel ceiling (`Speaker volume ceiling -30 dB`), speakersafetyd
running, and every graph ending in a limiter. Nothing here lifts the ceiling.

## 0. Setup (root shell over SSH, or a terminal on the machine with `sudo -i`)

```
dmesg | grep -E 'Speaker volume ceiling|Speaker volumes unlocked'   # -30 dB, unlocked
systemctl is-active speakersafetyd                                   # active
j716-audio-ab status                                                 # graph: bringup, safety: bringup
```

Second root shell, keep it open the whole time (the stop rules below read it):

```
journalctl -u speakersafetyd -f -o short-monotonic & dmesg -w | grep -E 'tas2764|spkr|macaudio'
```

For the daemon's per-speaker power (one line per speaker every 85 ms), run it verbose for this session only:

```
mkdir -p /etc/systemd/system/speakersafetyd.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/speakersafetyd -c /usr/share/speakersafetyd/ -m 7 -v\n' \
  > /etc/systemd/system/speakersafetyd.service.d/listen-debug.conf
systemctl daemon-reload && systemctl restart speakersafetyd
```

Test signals, as `rolo` (a terminal in the desktop session):

```
sh /usr/share/asahi-audio/j716/profile/make-test-signals.sh      # writes ~/j716-listen/, all at -20 dBFS
```

Add two or three music tracks you know well to `~/j716-listen/`: one with deep bass, one acoustic or vocal, one
dense mix.

## 1. Baseline: the bring-up graph

The default sink should read "MacBook Pro J716 Speakers (bring-up)". As `rolo`:

```
wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0         # bring-up tops out at -10 dB in the graph, -30 dB in the kernel
cd ~/j716-listen; pw-play t1k.wav; pw-play pink.wav; pw-play <music>
```

Note how loud the 1 kHz is and how the music sounds. Bring-up has no bass under about 180 Hz and no EQ.

## 2. Switch to the profile

Root: `j716-audio-ab profile` (restarts your PipeWire session; the desktop's sound menu reconnects after a second).
`j716-audio-ab status` should now show `graph: profile` and the default sink "MacBook Pro J716 Speakers"
(`audio_effect.j716-convolver`). Omarchy's sound panel shows it under that name and hides the DSP internals.

Volume steps, as `rolo`, quietest first. The slider is cubic; the graph is capped at -10 dB at 1.00 until this test
is passed.

| wpctl volume | graph volume | note |
|---|---|---|
| 0.55 | -35 dB | start here |
| 0.70 | -26.5 dB | the default for a new session |
| 0.85 | -18 dB | |
| 1.00 | -10 dB | the cap; about the bring-up's level at 1.00 (woofers +5.5 dB, tweeters -5 dB on pink noise) |

At each step, `wpctl set-volume @DEFAULT_AUDIO_SINK@ <v>` then:

```
pw-play t1k.wav                      # same tone as the baseline
pw-play b60.wav b100.wav b150.wav b200.wav b300.wav b500.wav
pw-play h2000.wav h5000.wav h10000.wav
pw-play pinkL.wav pinkR.wav pinkC.wav
pw-play sweep.wav                    # 40 Hz to 20 kHz in 20 s
pw-play pink.wav; pw-play <music>    # then switch back and forth (section 3)
```

What to listen for:

- **Bass tones and sweep 60-300 Hz:** buzz, rattle, chuffing or a distorted edge. The woofer filter boosts about
  +12 dB at 150-200 Hz (the J616s tuning) and rolls off hard under 80 Hz: 60 Hz should be faint, 100 Hz audible,
  150-200 Hz the fullest. Any rattle there is the first thing to report.
- **Sweep through 1-3 kHz:** the woofer/tweeter handover. A dip, a hole or a sudden jump in loudness is a crossover
  problem.
- **High tones and sweep top:** harshness or whistle. 10 kHz should be clear, not piercing.
- **pinkL / pinkR / pinkC:** left only from the left side, right only from the right, centre from the middle.
- **Balance on music:** voices thin, bright or dull? The tweeters run 6 dB down, as chosen by ear on the J616s (same
  drivers and same macOS tuning). If voices are dull, try 0.7; if sibilant, 0.35 (section 4).
- **Starts, stops, pause and seek in a player:** no pop or click. A pop on seek would mean `node.pause-on-idle` did not
  take.
- Nothing should keep playing after a file ends.

## 3. A/B

Root: `j716-audio-ab bringup` and `j716-audio-ab profile` switch in about two seconds. Use the same music and the
same wpctl volume (1.00 on both is roughly level-matched on the woofers). Note which you prefer and why.

## 4. Adjustments (optional, root)

Tweeter level: edit the two `"gain": 0.5` lines of `convLT` and `convRT` in
`/usr/share/asahi-audio/j716/profile/graph.json`, then `j716-audio-ab profile` again. 0.35 is -3 dB from now, 0.7 +3 dB.

## 5. Safety profile (optional; changes nothing audible at -30 dB)

```
j716-audio-ab safety aid41       # the AID41-calibrated speakersafetyd profile
```

The log must show `Max temperature: 140.0`, `Max power: 1.74 W` (woofers) / `1.77 W` (tweeters), `Min gain` about
-12.3 / -11.5 dB, and the kernel must print `Speaker volumes unlocked` again. Play `pink.wav` and one track.
`j716-audio-ab safety bringup` goes back.

## Stop rules (any one: `amixer -c AppleJ716 cset name='Speaker Switch' off`, stop pw-play, report)

- any `tas2764 ... fault` line in dmesg;
- speakersafetyd: a panic, restart, `gain limited`, negative power, or any speaker above 0.10 W (at the -30 dB
  ceiling the most it reads is about 0.04 W);
- distortion, buzz, crackle, sound from the wrong side, or sound that does not stop;
- anything else unexpected (smell, heat, a loud pop): hold the power button.

## Clean up (root)

```
rm /etc/systemd/system/speakersafetyd.service.d/listen-debug.conf; systemctl daemon-reload; systemctl restart speakersafetyd
j716-audio-ab status
```

Leave the graph on whichever you chose. `j716-audio-ab bringup` restores the exact bring-up files.

## Record

| check | bring-up | profile | notes |
|---|---|---|---|
| 1 kHz level at 1.00 | | | |
| bass 60 / 100 / 150 / 200 Hz clean? | | | |
| sweep: rattles, holes | | | |
| highs 5 / 10 kHz | | | |
| left / right / centre | | | |
| music: preference, why | | | |
| pops on pause / seek | | | |
| daemon peak power, faults | | | |
| tweeter gain chosen | | | |

## After this test (not part of it)

- Lift the graph cap: `"max": -10.0` to `0.0` in both `capture.volumes` entries (the offline render shows no clipping
  at 0 dB).
- Before lifting the **kernel** ceiling: settle the sensed-power reading (the daemon reads about 4x the electrical
  power on all six amps, which points at a one-bit sense slot offset under the NB_IF link; see the header of
  `speakersafetyd/j716.conf.aid41`), and install the AID41 safety profile.
- bankstown: `j716-audio-ab profile-bankstown` once `bankstown-lv2` is built and installed (the J616s graph's bass
  enhancer; the switch refuses while the plugin is missing).
