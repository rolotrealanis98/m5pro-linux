# J716 audio userspace (bring-up)

Nothing here does anything until the kernel has a CPU-side DAI for T6050
(stage B, not written yet). Until then the macaudio card does not exist and
speakersafetyd never starts. Install these files only on the Arch root of the
M5 Pro, never on another Mac.

| File here | Installs to (Arch root) | Owner package / notes |
|---|---|---|
| `speakersafetyd/apple/j716.conf` | `/usr/share/speakersafetyd/apple/j716.conf` | speakersafetyd (asahi-alarm). Conservative bring-up profile, see header. |
| `udev/96-speakersafetyd-j716.rules` | `/usr/lib/udev/rules.d/96-speakersafetyd-j716.rules` | Starts speakersafetyd.service on `AppleJ716` sense PCM (upstream rules have no J716 line). |
| `asahi-audio/j716/graph.json` | `/usr/share/asahi-audio/j716/graph.json` | asahi-audio. Bring-up DSP: -10 dB, 4th-order HPF (woofers 180 Hz, tweeters 2 kHz), -12 dBFS limiters, no FIR EQ, no bass enhancement, no loudness compensation. Output order LW1 RW1 LW2 RW2 LT RT (ADT order, matches the DT slots and j716.conf). |
| `asahi-audio/99-asahi-j716.conf` | `/usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716.conf` | Needs asahi-audio's `99-asahi.conf` (RawSpeakers rename, uclamp). No mic rule. |
| `alsa-ucm/ucm2/conf.d/macaudio/MacBook Pro J716.conf` | `/usr/share/alsa/ucm2/conf.d/macaudio/MacBook Pro J716.conf` | alsa-ucm-conf-asahi. Same as J516 (uses `laptops/HiFi.conf`, `cs42l84/Headphones.conf` from that package). |

Install (as root on the M5, after stage B lands):

```sh
install -Dm0644 speakersafetyd/apple/j716.conf /usr/share/speakersafetyd/apple/j716.conf
install -Dm0644 udev/96-speakersafetyd-j716.rules /usr/lib/udev/rules.d/96-speakersafetyd-j716.rules
install -Dm0644 asahi-audio/j716/graph.json /usr/share/asahi-audio/j716/graph.json
install -Dm0644 asahi-audio/99-asahi-j716.conf /usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716.conf
install -Dm0644 "alsa-ucm/ucm2/conf.d/macaudio/MacBook Pro J716.conf" \
    "/usr/share/alsa/ucm2/conf.d/macaudio/MacBook Pro J716.conf"
udevadm control --reload
```

Required packages: speakersafetyd, asahi-audio (pulls bankstown, triforce,
lsp-plugins-lv2; the J716 graph only uses lsp `compressor_stereo` and
PipeWire builtins), alsa-ucm-conf-asahi, pipewire >= 1.0,
wireplumber >= 0.5.2.

Kernel side (built-in macaudio, so these go on the kernel command line, not
in modprobe.d):

- `snd_soc_macaudio.please_blow_up_my_speakers=1` is REQUIRED for the
  speakers to exist at all on J716 (patch 0030 ships them disabled).
  Never set it before TEST-PLAN stage B2.
- `snd_soc_macaudio.speaker_max_db=-40` (optional, patch 0031) lowers the
  unlocked ceiling below the built-in -30 dB.

Card / device names: card id `AppleJ716`, jack PCM `hw:AppleJ716,0`,
speakers `hw:AppleJ716,1`, V/I sense `hw:AppleJ716,2` (12 ch).

Numbers copied from J316/J516 and why: see the header of `j716.conf` and
REPORT.md section 3.
