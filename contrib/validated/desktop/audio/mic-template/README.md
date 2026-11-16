# J716 microphone and AOP UCM: templates, not validated

The validated audio profile (`../j716-profile/`, `../ucm/`) has speakers and jack only. These are the microphone array
(the AOP card `AppleJ716AOP`, PCM 0, three capsules, float32 at 48 kHz) as templates. The same files exist in
`contrib/pending/audio/aurora/userspace/` from the R3-AUDIO stage A; nothing here was listened to or measured on this
machine's microphones beyond that stage's recording check. Do not move them to validated until a recording has been judged.

## Sources

| Source | Repo | Pin |
|---|---|---|
| `firs/j714/mic.json` (the J714 array graph: equal mix, +36 dB, 120 Hz high-pass, limiter -1 dBFS) | aurora-silicon/asahi-audio (edimoldovan, asahi-audio#20) | `4bf4b852da57c7503f5a3a1db7c2afbf774c9974`; file sha256 `59e78a0d3ff2195c654a847328e997da63fd30813c65dc1957a233702d0dd154` |
| `MacBook Pro J714.conf` (macaudio UCM) | aurora-silicon/alsa-ucm-conf-asahi | `bd2aa844821c5bcc616162fe5191eae7886e1bdc`; sha256 `64a7594002f84d15a1fd9a0735ace44df4f9bca341112950850371a6f28213f0` |
| `t8140-aop-audio/MacBook Pro J714 AOP Audio.conf`, the WirePlumber mic rules | alsa-ucm-conf-asahi `96b3206`; betizzel/omarchy-m5 `omarchy-aurora-firmware/wireplumber-j714-mic.conf` (`18e7d51`, MIT) | |

## Files

| file | derived from | change | install as |
|---|---|---|---|
| `j716-mic.json` | `firs/j714/mic.json` | `j714`/`J714` -> `j716`/`J716` in node names and descriptions; capsule 3 gain 0.22 -> 0.333333333 (the J714 file carries a J714c-measured -3.6 dB trim on capsule 3, which does not apply here: equal mix) | `/usr/share/asahi-audio/j716/mic.json` |
| `99-asahi-j716-mic.conf` | omarchy-m5 `wireplumber-j714-mic.conf` | `AppleJ714AOP` -> `AppleJ716AOP`, filter path | `/usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716-mic.conf` |
| `MacBook Pro J716 AOP Audio.conf` | `MacBook Pro J714 AOP Audio.conf` | none beyond the name | `/usr/share/alsa/ucm2/conf.d/t8140-aop-audio/` |

`j716-mic.json` is identical (as JSON) to the one in `pending/audio/aurora/userspace/asahi-audio/j716/mic.json`.

The graph needs `lsp-plug.in` (limiter_mono) and WirePlumber's software DSP. The AOP UCM names
`/conf.d/aop_audio/3chan/HiFi.conf`, which only exists in alsa-ucm-conf-asahi builds with the `aop_audio` tree
(`ls /usr/share/alsa/ucm2/conf.d/aop_audio/3chan/HiFi.conf`); without it skip the UCM file, PipeWire then opens the mic
as a plain ALSA device.

## The speaker UCM: nothing to add

`MacBook Pro J714.conf` at `bd2aa844` is `Syntax 6`, a HiFi use case with `JackCodec cs42l84`, six channels, jack on
device 0, speakers on device 1 and `File "/conf.d/macaudio/laptops/HiFi.conf"`. Our `../ucm/MacBook Pro J716.conf` is the
same layout with our own `j716/HiFi.conf` instead of `laptops/HiFi.conf` (the Headset control name differs on the
CS42L84 here), so the J714 file adds nothing. The one upstream change that matters is the speakerguardd v2 condition in
`laptops/HiFi.conf` (`96b3206`), now in `../ucm/j716/HiFi.conf` (`../speakerguardd-v2/README.md`).
