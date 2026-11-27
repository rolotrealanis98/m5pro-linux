# audio-panel-hints

Keeps the J716s speaker protection and microphone plumbing out of the Omarchy shell's sound panel, so it lists only
"MacBook Pro speakers", "MacBook Pro Microphone" and real devices (headphones, Bluetooth, USB).

The Omarchy shell reads `/usr/share/omarchy-platform/audio.json` (`shell/Commons/AudioNodes.qml`, watched, no restart)
and hides every node whose whole `node.name` matches a `hidden` pattern: it is never listed as an output, an input or an
app stream, and never counts as a recording. Omarchy itself ships no such file; a platform package is meant to.

Hidden here:

| Node | What it is |
|---|---|
| `alsa_output.platform-sound.RawSpeakers` | the raw amplifier sink (bypasses protection) |
| `sgv2.speaker.<board>`, `sgv2.sense.<board>` | speakerguardd v2's amp sink and I/V sense source |
| `sgv2.protect.<board>.out`, `sgv2.voicing.<board>.out` | speakerguardd's internal output streams |
| `audio_effect.<board>-mic` | the mic-array filter's capture stream (otherwise the panel shows the mic as always recording) |

Not hidden: `sgv2.voicing.<board>` (the speakers) and `effect_output.<board>-mic` (the microphone).

Install: `sudo install -Dm644 files/usr/share/omarchy-platform/audio.json /usr/share/omarchy-platform/audio.json`.
Undo: remove the file. Scope: any Mac running speakerguardd v2 and the asahi-audio mic array (patterns are board-agnostic).
Upstream: omacom/omarchy-mac-pkgs (the Mac platform package should own `/usr/share/omarchy-platform/audio.json`).
