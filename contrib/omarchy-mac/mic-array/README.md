# mic-array: the built-in microphones in apps

Scope `t6050`. Status: installed 2026-11-17, takes effect when WirePlumber next starts (login, reboot, or
`systemctl --user restart wireplumber` as the desktop user while nothing is playing).

## Why the mics gave no signal

The kernel side works: on `7.3.0-gcee93f953357`, `arecord -D hw:AppleJ716HPAI,0 -f FLOAT_LE -c 3 -r 48000` gives
all three capsules (about -68 to -80 dBFS RMS in a quiet room, peaks -30 dBFS with sound, never zeros). The
userspace no longer matched the card:

- The t8152 AOP audio driver names the card `AppleJ716HPAI` ("MacBook Pro J716 High-Power Audio Interface").
  The 2026-11-07 files were written for the bring-up driver's `AppleJ716AOP`: UCM under `t8140-aop-audio/`
  and a WirePlumber rule on `hw:AppleJ716AOP,0`. Neither applied.
- WirePlumber's `node.software-dsp` is not in its default profile (asahi-audio turns it on; asahi-audio is not
  installed here), so the mic graph rule could not have run anyway.
- So PipeWire offered the raw card as "Built-in Audio Multichannel": three AUX channels at about -70 dBFS with no
  gain. Apps that downmix it to mono or stereo get silence or close to it.

## Files

| file | what |
|---|---|
| `files/usr/share/alsa/ucm2/conf.d/aop_audio/MacBook Pro J716 High-Power Audio Interface.conf` | UCM for the HPAI card, as upstream's J616 file |
| `files/usr/share/alsa/ucm2/conf.d/aop_audio/j716s/HiFi.conf` | the Mic device: upstream's `3chan/HiFi.conf` without `JackControl "Internal Mic Jack"`, which this card does not have |
| `files/usr/share/asahi-audio/j716/mic.json` | copy of `../../validated/desktop/audio/mic-template/j716-mic.json` (upstream J714 graph, equal mix; source named "MacBook Pro Microphone" since 2026-11-27) |
| `files/usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716-mic.conf` | rules on `hw:AppleJ716HPAI,0` (and card id + PCM 0, and the old name), `node.software-dsp = required` |

The only `node.software-dsp.rules` on the Mac are these (speakerguardd v2 builds the speaker graph itself), so
turning software-dsp on does not touch the speakers. The new source has priority 2005: below the Yamaha RUio16-D
(2100) and a plugged headset (2500, `99-asahi-j716-jack.conf`), above nothing else; a source the owner picks is
remembered (`node.restore-default-targets = true`).

Checked before install: `alsaucm -c hw:AppleJ716HPAI` resolves the HiFi verb and Mic device with these files
(fails with -2 without them); `spa-json-dump` parses the WirePlumber file; the mic graph run in a private
PipeWire filter-chain instance (lsp limiter loads) lifts the raw array by about 25-30 dB on room noise.

## Install / undo

`sudo contrib/omarchy-mac/install-item.sh mic-array` / `--remove mic-array` (restores the 2026-11-07 files).
Then restart WirePlumber (log out and in, reboot, or `systemctl --user restart wireplumber` with nothing playing).

## Owner test (2 minutes, after the next login or boot)

1. Unplug the Yamaha (or keep it and pick the Mac mic by hand in step 2). Open `wiremix` (Omarchy audio menu)
   or `pavucontrol`, Input Devices: "MacBook Pro Microphone" is there, "Built-in Audio Multichannel" and
   "Raw Mic Device" are not. Set it as default (check mark / Set as fallback).
2. Speak at normal distance: the level meter moves with the voice and falls back when you stop. If it barely
   moves, raise its volume to 100 % (the graph starts at 70 %) and say so in the report.
3. Voice memo: `pw-record --channels 1 /tmp/memo.wav`, talk 5 s, Ctrl+C. Headphones in (or speakers at low
   volume, owner present): `pw-play /tmp/memo.wav`. Expect your voice, clear, no hum, no clipping; then
   `rm /tmp/memo.wav`.
4. One app: Chrome `https://webcammictest.com/check-mic` or a Meet/Zoom test call: the browser's level bar moves.
   Discord: Settings > Voice & Video > Input "MacBook Pro Microphone", "Let's Check".
5. Report: source present yes/no, meter moves yes/no, memo sounds right yes/no (noisy, quiet, distorted?).
