# J716s speaker profile (2026-11-07) — built, checked offline, staged, not active

Main finding: the Studio's macOS 27.2 ships `/System/Library/Audio/Tunings/AID41`, Apple's speaker tuning for the
J716s, byte-identical to the J616s (M4 Pro 16") and J516 (M3 Pro 16") tunings: same speaker strips, protection
parameters and DSP graphs. So the J716 has the J616s speakers; Aurora's J616s graph with the J316 FIRs is the right
base and the speakersafetyd thermal values come from AID41 instead of guesses. Apple's tuning files are not in the
repo. No audio was played; active files unchanged (`99-asahi-j716.conf` sha 8859a9ea…, `speakersafetyd/apple/j716.conf`
10f5c061…).

Delivered (staged to `/usr/share/asahi-audio/j716/profile/` + `/usr/local/bin/j716-audio-ab`):
- `graph.json`: the J616s graph adapted (outputs in ADT slot order LW1 RW1 LW2 RW2 LT RT, tweeters at 0.5 = -6 dB,
  true-peak limiters -1 dBFS on every output, pause-on-idle false); graph volume capped at -10 dB until the listening
  check; kernel -30 dB ceiling stays. bankstown left out (bankstown-lv2 not packaged on this root); `graph-bankstown.json`
  is the full chain for later.
- Sink naming matches asahi-audio (`audio_effect.j716-convolver` "MacBook Pro J716 Speakers", `effect_output.j716-convolver`,
  `RawSpeakers`), so Omarchy hides/shows them as on other Macs; UCM unchanged.
- `j716-audio-ab status | bringup | profile | profile-bankstown | safety bringup|aid41`: backups, restarts the user's
  PipeWire session, refuses profile-bankstown while the plugin is missing; bring-up variants byte-identical to today's.
- `tests/render-check.py`: renders the graphs in a private PipeWire daemon with no ALSA (nothing reaches the speakers);
  on the MacBook: ok; channel map correct; 200 Hz 44 dB louder on woofers than tweeters, 5 kHz 16 dB louder on tweeters;
  no clipping even at 0 dB; vs the bring-up graph at full volume woofers +5.6 dB, tweeters -5.2 dB.
- `LISTENING-TEST.md` + `make-test-signals.sh` (signals <= -20 dBFS): volume steps 0.55-1.00, bass tones, crossover
  sweep, L/R/centre, A/B on music, tweeter gain adjustment, stop rules, results table.

speakersafetyd `j716.conf.aid41` (staged, not active) vs the active bring-up file: t_limit 140 (120), woofer
tr_coil/tr_magnet/tau_coil/tau_magnet 26.06/25.55/5.53/197.25 (28.75/50/5.6/197.25), tweeter 26.91/23.93/1.55/73.26
(56.25/62.5/1.3/73.26), z_nominal 2.70/3.20 (3.60; the ADT gives this unit's coils 3.29-3.39 ohm, Apple's lower
values kept as the conservative choice), is_scale/vs_scale 3.75/14 on all six, max power woofer/tweeter 1.74/1.77 W
(0.89/0.59). Flagged: no right-side halving on the J716s (the B6 log reads symmetric power and temperature shifts, so
the J714c's halved right-side scales do not apply); sensed power reads ~4x the expected on every amp (8-12 mW expected
at the ceiling, 30-40 mW read; voltage and current each ~2x; guess: a one-bit sense slot offset under the new link
format, unverified, errs safe) — must be settled before the kernel ceiling is lifted; woofer 1 vs 2 within a side
inferred; macOS runs amp level 15 (18.5 dBV) vs our DT 10 (16 dBV), the daemon reads the actual control.

Next: Rolando runs LISTENING-TEST.md (~30 min, ceiling kept); raise the graph cap to 0 dB and settle the tweeter gain;
explain/fix the 2x sense reading, then `j716-audio-ab safety aid41`; build bankstown-lv2 for profile-bankstown.
