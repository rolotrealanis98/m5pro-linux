# J716 speaker profile (staged, not active)

asahi-audio-style speaker profile for the MacBook Pro 16" M5 Pro/Max (J716s, acoustic ID 41), an A/B switch against
the bring-up graph, and an AID41-calibrated speakersafetyd profile. Staged on the MacBook under
`/usr/share/asahi-audio/j716/profile/` and `/usr/local/bin/j716-audio-ab` by `stage.sh`; nothing active changes until
`j716-audio-ab` is run. Listening procedure: `LISTENING-TEST.md`.

## Why the J616s graph

macOS 27.2 ships AID41's speaker tuning byte-identical to AID35 (J616s, M4 Pro 16") and AID29 (J516, M3 Pro 16"): the
same `builtin_speaker_out_general*.austrip` strips, the same SpeakerProtect (spp3) parameters, the same DSP graphs.
asahi-audio drives the J516 and Aurora drives the J616s with the J316 FIRs, so the J716 profile is Aurora's J616s graph
(aurora-silicon/asahi-audio `firs/j616/graph.json` @ faf7719) with these changes:

| change | why |
|---|---|
| node names `audio_effect.j716-convolver` / `effect_output.j716-convolver`, sink "MacBook Pro J716 Speakers" | asahi-audio naming; Omarchy's `audio.json` hides `effect_output.jNNN-convolver` and `RawSpeakers` |
| FIR paths `/usr/share/asahi-audio/j716/profile/` | asahi-audio is not installed on this root; the eight J316 FIRs are copied here unchanged |
| `capture.volumes` max -10 dB (asahi: 0 dB) | the bring-up graph's cap, kept until the listening check |
| rates 48000/44100 | the AOP speaker serializer runs at 48 kHz only |
| `graph.json` has no bankstown node; `graph-bankstown.json` is the full J616s chain | bankstown-lv2 is not built for this root; bankstown adds harmonics on top of the dry signal, so removing it changes no frequency content the woofers get |

Kept from the J616s graph: output order LW1 RW1 LW2 RW2 LT RT (the J716s ADT speaker order and TDM rx slots 0-5),
tweeter convolvers at 0.5, LSP loudness compensation as the volume, the woofer band compressor and limiter, true-peak
limiters at -1 dBFS on every output, `node.pause-on-idle` false.

## Files

| file | staged as |
|---|---|
| `graph.json`, `graph-bankstown.json`, `firs/*.wav` | `/usr/share/asahi-audio/j716/profile/` |
| `wireplumber/99-asahi-j716.conf.{bringup,profile,profile-bankstown}` | `.../profile/wireplumber/`; `j716-audio-ab` installs one as `/usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716.conf` |
| `speakersafetyd/j716.conf.{bringup,aid41}` | `.../profile/speakersafetyd/`; `j716-audio-ab safety` installs one as `/usr/share/speakersafetyd/apple/j716.conf` |
| `j716-audio-ab` | `/usr/local/bin/` |
| `tests/render-check.py` | `.../profile/render-check.py`: offline render in a private PipeWire daemon with no ALSA (channel map, crossover, clipping, levels) |
| `make-test-signals.sh` | test tones for the listening check |

The `.bringup` variants are byte-identical to the files active today (`contrib/pending/audio/aurora/userspace/`).
UCM needs no change: the UCM Speaker device opens `hw:AppleJ716,1` (6 ch), which the fragment renames to `RawSpeakers`
as asahi-audio does on every Mac.

## Provenance and licences

- J316 FIRs: AsahiLinux/asahi-audio `firs/j316/` (GPL-2.0-or-later), identical in aurora-silicon/asahi-audio.
- Graph: aurora-silicon/asahi-audio J616s graph, derived from asahi-audio's J316 graph.
- speakersafetyd values: macOS AID41 tuning, read with speakersafetyd's `docs/audump.py` field mapping; every source and
  every inferred number is listed in the header of `speakersafetyd/j716.conf.aid41`.
