# J716s audio: root-side setup (Arch Linux ARM on nvme0n1p5, over SSH)

Order matters. Stage A (mic + jack, speakers held in hardware shutdown) is safe to do at once. Stage B (speakers) only after
section 4 passes. All commands as root on the M5 unless marked "Studio".

Files referenced below are in `~/Work/agents/audio-aurora/userspace/` on the Studio; copy that folder to the M5 first:
```
# Studio
scp -r ~/Work/agents/audio-aurora/userspace m5:/root/j716-audio
```

## 1. Firmware: nothing to install
- The AOP runs `mac17jaop`, which **iBoot loads before m1n1** (J716s ADT `/arm-io/aop/iop-aop-nub`: firmware-name `mac17jaop`,
  firmware-type `scrt`; `/arm-io/aop` segment-ranges filled in). `aop.rs` only takes the halted CPU out of reset and talks
  RTKit to it. The kernel requests no AOP firmware file on T6050.
- Do **not** extract `Firmware/AOP/aopfw-mac17jaop.RELEASE.im4p` or `AOP2/aop2fw-mac17jaop2.RELEASE.im4p`; no tool is needed.
- The only file the AOP driver can request is an ALS calibration named by an `als` child's `firmware-name`. Our DT has no
  such child and T6050's setup port has no ALS endpoint, so the driver logs nothing about it. (The trackpad's
  `apple/tpmtfw-j716s.bin` is unrelated and already on the root.)

## 2. Packages
Arch Linux ARM repos give PipeWire and WirePlumber. The Asahi speaker stack (asahi-audio, speakersafetyd, alsa-ucm-conf-asahi)
comes from the `[asahi-alarm]` repository, the same source omarchy-mac 0.2.4 names (`asahi-alarm-keyring`). Nothing in
`omacom/omarchy-mac-pkgs` packages a J716 profile, and installing `omarchy-mac` itself is not advised here
(`~/Work/agents/distro/DESIGN.md` section 7).

1. Check what is there:
   ```
   pacman -Q pipewire wireplumber pipewire-alsa pipewire-pulse alsa-utils asahi-audio speakersafetyd alsa-ucm-conf-asahi 2>&1
   grep -n 'asahi' /etc/pacman.conf
   ```
2. If `[asahi-alarm]` is missing, add it (asahi-alarm/asahi-alarm README):
   ```
   pacman-key --recv-keys 12CE6799A94A3F1B5DDFFE88F576553597FB8FEB
   pacman-key --lsign-key 12CE6799A94A3F1B5DDFFE88F576553597FB8FEB
   echo 'Server = https://github.com/asahi-alarm/asahi-alarm/releases/download/$arch' > /etc/pacman.d/mirrorlist.asahi-alarm
   printf '\n[asahi-alarm]\nInclude = /etc/pacman.d/mirrorlist.asahi-alarm\n' >> /etc/pacman.conf
   pacman -Sy asahi-alarm-keyring
   ```
   The section goes **after** `[core]`/`[extra]` (appended above), so a later `pacman -Syu` does not swap in Asahi's kernel,
   mesa or firmware packages. Install by name only.
3. Install:
   ```
   pacman -S --needed pipewire wireplumber pipewire-alsa pipewire-pulse rtkit alsa-utils \
                      asahi-audio speakersafetyd alsa-ucm-conf-asahi lsp-plugins-lv2
   pacman -Q pipewire wireplumber speakersafetyd    # need pipewire >= 1.0, wireplumber >= 0.5.2
   ```
   asahi-audio pulls bankstown, triforce and lsp-plugins-lv2. speakersafetyd ships its unit and udev rules but no J716
   profile. speakersafetyd reads the sense PCM as S16 (`io_i16`), which is the T6050 sense format.
4. Fallback if `[asahi-alarm]` is not reachable: build from source on the M5.
   ```
   pacman -S --needed base-devel rust alsa-lib git
   git clone https://github.com/AsahiLinux/speakersafetyd && cd speakersafetyd && make && make install DESTDIR=/ && cd ..
   git clone https://github.com/AsahiLinux/asahi-audio && make -C asahi-audio install
   git clone https://github.com/AsahiLinux/alsa-ucm-conf-asahi && cp -r alsa-ucm-conf-asahi/ucm2/* /usr/share/alsa/ucm2/
   ```
   (bankstown, triforce, lsp-plugins-lv2 then also from source or AUR; the J716 graphs here need only lsp-plugins-lv2 and
   PipeWire builtins.)

## 3. J716 files (both stages)
```
cd /root/j716-audio
install -Dm0644 speakersafetyd/apple/j716.conf          /usr/share/speakersafetyd/apple/j716.conf
install -Dm0644 udev/96-speakersafetyd-j716.rules       /usr/lib/udev/rules.d/96-speakersafetyd-j716.rules
install -Dm0644 asahi-audio/j716/graph.json             /usr/share/asahi-audio/j716/graph.json
install -Dm0644 asahi-audio/j716/mic.json               /usr/share/asahi-audio/j716/mic.json
install -Dm0644 asahi-audio/99-asahi-j716.conf          /usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716.conf
install -Dm0644 asahi-audio/99-asahi-j716-mic.conf      /usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716-mic.conf
install -Dm0644 "alsa-ucm/ucm2/conf.d/macaudio/MacBook Pro J716.conf" \
                "/usr/share/alsa/ucm2/conf.d/macaudio/MacBook Pro J716.conf"
install -Dm0644 "alsa-ucm/ucm2/conf.d/t8140-aop-audio/MacBook Pro J716 AOP Audio.conf" \
                "/usr/share/alsa/ucm2/conf.d/t8140-aop-audio/MacBook Pro J716 AOP Audio.conf"
udevadm control --reload
```
- `j716.conf`, the udev rule, `graph.json` and the macaudio UCM are our 11-04 files, unchanged apart from a comment.
- `mic.json` is edimoldovan's J714 mic graph (asahi-audio#20) with the J714c-measured -3.6 dB trim on capsule 3 removed:
  equal mix, +36 dB, 120 Hz high-pass, limiter at -1 dBFS.
- The AOP UCM file names `/conf.d/aop_audio/3chan/HiFi.conf`, which only exists in alsa-ucm-conf-asahi builds that have the
  `aop_audio` tree. Check: `ls /usr/share/alsa/ucm2/conf.d/aop_audio/3chan/HiFi.conf`. If missing, skip the AOP UCM file:
  PipeWire then opens the mic as a plain ALSA device, which also works.
- speakersafetyd derives `apple/j716.conf` and `hw:AppleJ716` from the first DT compatible `apple,j716s` and the card model
  "MacBook Pro J716". Its unit is started by the udev rule when `pcmC*D2c` of AppleJ716 appears, which only happens in stage B.
- Do **not** reuse the old README's `snd_soc_macaudio.please_blow_up_my_speakers=1`: this kernel ignores it.

Enable the user audio services (as the desktop user, once):
```
systemctl --user enable --now pipewire pipewire-pulse wireplumber
```

## 4. Stage A checks (R3-AUDIO-A booted: mic + jack, speakers off)
```
cat /proc/asound/cards                      # AppleJ716 (MacBook Pro J716) and AppleJ716AOP (MacBook Pro J716 AOP)
dmesg | grep -iE 'aop|macaudio|tas2764|cs42l84|admac' | head -80
arecord -D hw:AppleJ716AOP,0 -f FLOAT_LE -c 3 -r 48000 -d 5 /tmp/mic.wav   # speak during it
sox /tmp/mic.wav -n stat 2>&1 | grep -E 'RMS|Maximum amp'                  # if sox is installed
wpctl status | sed -n '/Sources/,/Filters/p'                               # "MacBook Pro J716 Microphone"
```
- Expect the raw level around -60 dBFS for speech (J714c: -62 dBFS). Flat zeros or a constant floor = see R3-AUDIO-RECIPE.md §4.
- Jack: with headphones plugged, `amixer -c AppleJ716 contents | grep -i jack` shows the jack switch; play through
  `pw-play` at low volume. The jack path on the AOP is in Ed's card but he did not report a headphone test: treat as unverified.
- Speakers must be off here: `dmesg | grep 'passed no amp levels'` shows the line, and `amixer -c AppleJ716 controls | grep -c Woofer`
  prints 0.

## 5. Speaker safety order (before booting R3-AUDIO-B)
Do all of this while still on R3-AUDIO-A:
1. `pacman -Q speakersafetyd` and `test -f /usr/share/speakersafetyd/apple/j716.conf` succeed.
2. `systemctl cat speakersafetyd` shows the shipped unit (keep its `-m 7` max-reduction argument), `systemctl is-enabled speakersafetyd`
   is `static` or `enabled` (it is started by udev; do not mask it).
3. `grep -c AppleJ716 /usr/lib/udev/rules.d/96-speakersafetyd-j716.rules` prints 1, and `udevadm control --reload` ran.
4. Dry-run the profile parser: `speakersafetyd --help` runs, and `journalctl -b -u speakersafetyd` has no "Unexpected" errors from a
   previous boot.

Then boot **R3-AUDIO-B** (spk DTB, `snd_soc_macaudio.speaker_max_db=-40`). Before any sound:
```
dmesg | grep -E 'Speaker volume|passed no amp levels|tas2764|sn012776'
systemctl status speakersafetyd --no-pager                      # active (running)
journalctl -b -u speakersafetyd --no-pager | tail -40           # opened hw:AppleJ716,2, 12 channels, no panic
dmesg | grep -E 'Speaker volumes (un)?locked|Speaker volume ceiling'   # "unlocked", then "ceiling -40 dB"
amixer -c AppleJ716 sget 'Left Woofer 1 Speaker Volume'         # limit at the ceiling, not 0 dB
amixer -c AppleJ716 sget 'Left Woofer 1 Amp Gain Volume'        # max 10 (from apple,speaker-config)
```
Gates (all must hold, else stop and boot back to R3-AUDIO-A):
- speakersafetyd is running and the kernel printed "Speaker volumes unlocked" **after** it started. Without the daemon the volume
  stays locked at raw 1 (about -100 dB): silence is the safe failure.
- "Speaker volume ceiling -40 dB" is in dmesg.
- Amp Gain Volume max is 10.

First sound, quietest first, through the raw device so no DSP gain applies (the protective graph is next). The speaker
PCM takes S24_LE (24 bits in 32), so go through `plughw` and let alsa-lib convert; stop PipeWire's hold on the card first:
```
systemctl --user stop wireplumber pipewire pipewire-pulse     # as the desktop user
sox -n -r 48000 -c 6 -b 16 /tmp/t.wav synth 2 sine 1000 gain -40   # -40 dBFS, 2 s, all six channels
aplay -D plughw:AppleJ716,1 /tmp/t.wav
journalctl -b -u speakersafetyd -f        # in a second SSH session: per-speaker temperatures move, no panic
```
Then check the V/I scaling: play the same tone on one side only; speakersafetyd's power/temperature for the right speakers
should match the left. **If the right side reads about 4x the power** (edimoldovan found the i2c3 amps report V and I at twice
the left amps' on J714c), set `is_scale = 1.875` and `vs_scale = 7` in the three `[Speaker/Right ...]` sections of j716.conf
and restart speakersafetyd. Do not halve them before seeing it: unhalved, the daemon over-estimates right-side heating,
which is the safe direction.

Only after that: let WirePlumber use the protective graph (it already does; the sink is "MacBook Pro J716 Speakers"), and
later drop `speaker_max_db=-40` to get the kernel's built-in -30 dB ceiling. Lifting -30 dB or the amp level 10 needs a
kernel change and measured AID41 thermal data; not part of this bring-up.

## 6. Rollback
- Audio misbehaves but the system is fine: `systemctl --user stop wireplumber pipewire`, remove the two J716 WirePlumber
  fragments, boot R3-AUDIO-A again.
- Any speaker noise you did not ask for: power off (hold the power button), then boot R3-AUDIO-A or R3-R.
- The DTBs and kernel are separate payloads; R3-R's boot.bin stays the known-good fallback (restore `boot.bin.prev` as in
  R3-R-RECIPE.md).
