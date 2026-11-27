# Audio devices named without the board code (2026-11-27)
Tracker: https://github.com/rolotrealanis98/m4-m5-linux/issues/56     Kernel: 7.3.0-g0f96ca644485

## What broke
Cosmetic. The speakers and the microphone showed up as "MacBook Pro J716 speakers" and "MacBook Pro J716 Microphone",
and the Omarchy bar's sound panel also listed the speaker protection's internal devices ("MacBook Pro J716 speaker
amps (protected path only)", "... speaker sense (protection only)", the raw amplifier sink) next to the real ones.
Rolando wants only the clean names.

## Cause
- Microphone: the name is set by the asahi-audio mic-array config (`node.description`, `media.name` in
  `/usr/share/asahi-audio/j716/mic.json`).
- Speakers: speakerguardd v2's generator (`gen.py`) builds every node description from the device tree's model,
  "MacBook Pro J716".
- Internal devices: they are ordinary PipeWire sinks, sources and streams, so the shell lists them. Omarchy's shell
  already supports hiding a platform's audio plumbing through `/usr/share/omarchy-platform/audio.json`
  (`shell/Commons/AudioNodes.qml`, watched live), but this Mac had no such file.

## Fix
1. Microphone: `node.description` and `media.name` are "MacBook Pro Microphone" in the mic-array config
   (`contrib/validated/desktop/audio/mic-template/j716-mic.json` and its installed copy
   `contrib/omarchy-mac/mic-array/files/usr/share/asahi-audio/j716/mic.json`). Only that file was installed (backup
   `mic.json.pre-device-names`); `install-item.sh mic-array` was not re-run because it also rewrites a protected UCM file.
   `~/.config/omacom/monologue.conf` looks the mic up by name: `label=MacBook Pro Microphone` (backup
   `monologue.conf.pre-device-names`). Superwhisper looks it up by ID: no change.
2. Speakers: speakerguardd-v2 41.2 adds `0001-gen-name-the-speaker-sink-without-the-board-code.patch`, a
   `display_name()` helper that strips a trailing board code (`J\d{3}[a-z]?`) from the model for the speaker sink only;
   the protect, amp and sense nodes keep the full model. The patch also regenerates the per-machine configs upstream
   ships, so the package's "generated files are current" tests pass. Built with `makepkg --nodeps` in the Studio's
   Arch Linux ARM container (`spk-build`, rust 1.100): check() passed. Installed with `pacman -U`; the graph in
   `/run/speakerguardd-graph` was regenerated at the next boot.
3. Sound panel: `contrib/omarchy-mac/audio-panel-hints/` installs `/usr/share/omarchy-platform/audio.json`, which hides
   `alsa_output.platform-sound.RawSpeakers`, `sgv2.speaker.*`, `sgv2.sense.*`, `sgv2.protect.*.out`,
   `sgv2.voicing.*.out` and `audio_effect.*-mic` (the last one also stops the panel from counting the mic filter as a
   recording). The speakers (`sgv2.voicing.<board>`) and the microphone (`effect_output.<board>-mic`) stay listed.
   No shell restart needed.

Node names (`node.name`) did not change, so nothing that selects a device by ID is affected.

## Files changed
- `/usr/share/asahi-audio/j716/mic.json` (backup `.pre-device-names`)
- `~/.config/omacom/monologue.conf` (backup `.pre-device-names`)
- `pkg:speakerguardd-v2` 41.1 -> 41.2 (`contrib/distro/pkg/speakerguardd-v2/`)
- `/usr/share/omarchy-platform/audio.json` (new)

## Verified
After a reboot on the daily (7.3.0-g0f96ca644485): `pw-cli info` shows `sgv2.voicing.j716` = "MacBook Pro speakers"
(default output) and `effect_output.j716-mic` = "MacBook Pro Microphone" (default input); speakerguardd-v2 active,
0 failed units. Rolando confirmed the bar's sound panel lists only the clean names.

## Rollback
```bash
sudo cp -a /usr/share/asahi-audio/j716/mic.json.pre-device-names /usr/share/asahi-audio/j716/mic.json
cp -a ~/.config/omacom/monologue.conf.pre-device-names ~/.config/omacom/monologue.conf
sudo pacman -U <speakerguardd-v2 41.1 package>   # then reboot to regenerate the graph
sudo rm /usr/share/omarchy-platform/audio.json
```
