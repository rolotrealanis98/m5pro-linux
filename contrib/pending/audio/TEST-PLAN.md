# Test plan: J716s audio (stage A now, stage B later)
# (TEST-PLAN.md would be refused like REPORT.md; same content as .txt)

Do not start while another agent owns reboots. Everything runs from the Mac Studio over the SSH bridge, as in the
trackpad plan:

    B="/Users/rolo/Work/m1n1/.venv/bin/python /Users/rolo/Work/eem-vm/eem-vm.py --keep"

## Hard safety rules (all stages)
1. Never pass `snd_soc_macaudio.please_blow_up_my_speakers` before stage B2, never with a value >= 2, never in a
   payload that is left installed as the default boot.
2. Never let the speakers play without speakersafetyd running with apple/j716.conf. The kernel enforces this (volume
   clamped to -100 dB unless the daemon holds the lock); B2 tests that enforcement before anything plays.
3. Volume caps stay in place for this whole plan: amp gain 10 (patch 0030), unlocked ceiling -30 dB (0031) lowered to
   -40 dB on the command line, DSP graph -10 dB max, test signals at -40 dBFS or lower.
4. Headphone jack first (B1), then the sense path with no playback (B2), then one speaker at a time (B3), then all six
   through the DSP graph (B4). Do not skip a stage, do not combine stages.
5. Stop immediately (stop playback, then `systemctl stop speakersafetyd`, which relocks the volume) on: buzzing or
   distortion, any tas2764 over-current/over-temperature/clock-error message, a rising tas2764 or cs42l84 count in
   /proc/interrupts while idle, I2C timeouts, or a speakersafetyd panic. Then roll back.

## Rollback (any stage)
    $B 'cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin && sync && sha256sum /boot/m1n1/boot.bin && systemctl reboot'
If SSH does not come back, recover as in m5pro-linux docs/boot-and-recovery.md (tethered boot; boot.bin.prev on the
ESP holds the previous payload). Stage A changes only the DTB and config: the old payload is a complete rollback.

## Stage A: I2C devices, no sound (bootable today)

### A0. Build (Mac Studio)
- omarchy-m5: `git apply ~/Work/agents/audio/patches/omarchy-m5/0001-j716s-audio-stage-A-DTB-amps-and-jack-codec-on-I2C.patch`
  (if the USB agent's patch is applied too, merge the build-kernel.sh install list and DTB lines by hand).
- vendor/linux: apply ~/Work/agents/audio/patches/linux/0030-*.patch then 0031-*.patch.
- `scripts/build-kernel.sh` (its default KCONFIG now merges omarchy-audio.config). Check the result:
  `grep -E '^CONFIG_(PINCTRL_APPLE_GPIO|I2C_APPLE|SND_SOC|SND_SOC_TAS2764|SND_SOC_CS42L84|SND_SOC_APPLE_MACAUDIO|DYNAMIC_DEBUG)=y' vendor/linux/.config`
  must print 7 lines.
- DTB: vendor/linux/arch/arm64/boot/dts/apple/t6050-j716s-audio.dtb must equal build/t6050-j716s-audio.dtb
  (sha256 f3548a9176c95cd9f460c24ab510d9b6f22cbd9a432ffe9292ea54af6f745912) if built from the same base; a different
  hash is fine if the SMC/trackpad DT patches are also applied, but then diff the decompiled DTBs.
- Payload, with today's command line plus codec debug:

      scripts/mkpayload.sh --board j716s-audio --out build/payload-audio-a.bin --bootargs \
        "earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 idle=nop arm64.nowfxt snd_soc_cs42l84.dyndbg=+p"

  (no macaudio parameters in stage A). Record the payload sha256.

### A1. Deploy (temp file, verify, rename; same as the trackpad plan)
    $B 'uname -r; sha256sum /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev'
    $B 'cp /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev && sync && sha256sum /boot/m1n1/boot.bin.prev'
    $B --put build/payload-audio-a.bin /boot/m1n1/boot.bin.new 'sync; sha256sum /boot/m1n1/boot.bin.new'
    # continue only if the hash matches the payload
    $B 'mv /boot/m1n1/boot.bin.new /boot/m1n1/boot.bin && sync && systemctl reboot'

### A2. Checks
a) Right kernel and DTB, nothing else broke:
       $B 'uname -r; nproc; tr -d "\0" </proc/device-tree/model; echo; cat /proc/cmdline'
   Expect 18 CPUs and model "... (16-inch, M5 Pro, 2026), audio stage A". Keyboard, trackpad state, SSH as before.
   If the boot hangs or SSH is gone: roll back; the likely cause is PINCTRL_APPLE_GPIO=y (first time the Apple
   pinctrl driver binds on this machine), not the audio nodes.
b) Pinctrl bound, PMGR sync_state no longer waiting on it:
       $B 'ls /sys/bus/platform/drivers/apple-gpio-pinctrl/; dmesg | grep -iE "pinctrl|sync_state" | tail -20'
   Expect 29c000000.pinctrl (and 2881e4000/290824000) bound; no "sync_state() pending due to ...pinctrl".
   Any domain powered off at sync_state that took a device with it (USB tether, NVMe, MTP) = fail, roll back.
c) I2C controllers and clients:
       $B 'dmesg | grep -iE "i2c|pasemi" | tail -20; for d in /sys/bus/i2c/devices/*-00*; do echo "$d $(cat $d/name) $(basename $(readlink -f $d/driver) 2>/dev/null)"; done'
   Expect seven clients: *-0038, *-0039, *-003a, *-003b, *-003c, *-003d bound to tas2764, *-004b bound to cs42l84.
d) Jack codec answered:
       $B 'dmesg | grep -i cs42l84'
   Pass: "Cirrus Logic CS42L84, Revision: NN". Fail modes: "Failed to read device ID" (reset polarity/GPIO 139 or bus
   wiring wrong; harmless, report it), "Device ID ... Expected" (wrong chip at 0x4b).
e) Amps held in shutdown (the key safety check):
       $B 'grep -B2 -A1 -i shutdown /sys/kernel/debug/gpio'
   Pass: the 29c000000.pinctrl line labelled "shutdown" (AP 107) is "out lo". If it is "out hi": STOP, roll back,
   report (should be impossible without a sound card). Only the first amp owns the line; the other five probe
   without it (same as J316/J516).
f) No sound card exists:
       $B 'cat /proc/asound/cards; ls /dev/snd 2>/dev/null'
   Expect "--- no soundcards ---".
g) Jack plug detection (needs a person at the machine; use headphones lying on the desk, not on ears):
       $B 'dmesg -C'   # then plug in, wait 2 s, unplug
       $B 'dmesg | grep -iE "cs42l84|plug"; grep -i cs42l84 /proc/interrupts'
   Pass: "Plug event" then "Unplug event" debug lines and the cs42l84 interrupt count went up by a few, not
   thousands. A count rising continuously with nothing plugged = IRQ polarity wrong (AP 134 level-low): roll back.
h) Speaker variant pins (optional). First look without requesting anything:
       $B 'gpiodetect; gpioinfo -c $(gpiodetect | grep 29c000000 | cut -d" " -f1) 136 137'
   Only if both show "input": `gpioget -c <that chip> 136 137` (requesting an input as input changes nothing).
   Record the values: they identify the speaker vendor (ADT valid-speaker-ids 0 and 3) for the AID41 profile. If
   either line is an output, do not touch it; report.
Gate A passed = a-h pass. Stage A can stay installed (it never powers an amp); otherwise roll back.

## Stage B: needs the AOP stream transport (not written yet; see REPORT.txt section 5)
Prerequisites: AOP up under Linux, the T6050 AOP audio driver (Aurora aop_spkr port), evolved ADMAC, a J716 macaudio
entry with enable_speakers=false / amp gain 10 / max_vol -30, and the stage B DT. Re-run all of A2 first.

### B1. Headphone jack only (speakers absent)
- Command line: no macaudio parameters. Check the speakers are not there:
      $B 'cat /proc/asound/cards; amixer -c AppleJ716 controls | grep -c "Speaker Volume"'
  Expect card AppleJ716 (or the jack card) and 0 speaker controls.
- Headphones on the desk, not on ears: set "Jack DAC" low, play a 440 Hz sine at -30 dBFS for 3 s on the jack PCM
  (`sox -n -r 48000 -c 2 -b 32 /tmp/hp.wav synth 3 sine 440 gain -30; aplay -D hw:AppleJ716,0 /tmp/hp.wav`, card/PCM
  names as the driver registers them). Audible faintly from the cups = pass. Then on ears at low volume, then the
  headset mic (`cin `) capture.

### B2. Speaker controls and sense path, nothing plays
- Mask the daemon first: `systemctl mask --now speakersafetyd`. Stop PipeWire for raw access:
  `systemctl --user stop pipewire pipewire-pulse wireplumber`.
- Payload command line adds `snd_soc_macaudio.please_blow_up_my_speakers=1 snd_soc_macaudio.speaker_max_db=-40`.
  This payload is for this test only; boot.bin.prev stays the stage A payload.
- Locked state: every "<amp> Speaker Volume" must report max 1:
      $B 'amixer -c AppleJ716 cget name="Left Woofer 1 Speaker Volume"'
  If max is anything but 1: STOP, roll back (interlock broken).
- Start the daemon by hand in the foreground for 30 s, no playback:
      $B 'timeout 30 speakersafetyd -c /usr/share/speakersafetyd/ -m 7 -v'
  Expect per speaker "Max temperature: 120.0", "Amp gain: 16 dBV", and in dmesg "Speaker volumes unlocked" and
  "Speaker volume ceiling -40 dB"; after the timeout ends the daemon, "Speaker volumes locked" within ~250 ms.
- Interlock test: start it again in the background, `kill -STOP` it, confirm "Speaker volumes locked" in dmesg, then
  `kill -CONT` / kill it.

### B3. One speaker at a time, -40 dBFS, daemon running
- `systemctl unmask speakersafetyd && systemctl start speakersafetyd`; confirm it is running and unlocked.
- For each amp n in ADT order (0 LW1, 1 RW1, 2 LW2, 3 RW2, 4 LT, 5 RT): a 2 s sine, 1 kHz for woofers, 4 kHz for
  tweeters, at -40 dBFS on channel n only of the raw 6-channel PCM, while capturing the 12-channel sense PCM:
      sox -n -r 48000 -c 6 -b 32 /tmp/s.wav synth 2 sine 1000 gain -40 remix <ones-hot list, e.g. "1 0 0 0 0 0">
      arecord -D hw:AppleJ716,2 -c 12 -f S16_LE -r 48000 -d 3 /tmp/sense.wav & aplay -D hw:AppleJ716,1 /tmp/s.wav
      for c in $(seq 1 12); do sox /tmp/sense.wav -n remix $c stats 2>&1 | grep 'RMS lev dB'; done
- Pass per amp: the sound comes from that speaker's position, and only sense channels 2n and 2n+1 show signal.
  Anything else: STOP; fix the DT slots, j716.conf and the graph order together, then repeat B3 from amp 0.
- Watch `journalctl -u speakersafetyd -f`: no gain reduction is expected at this level.

### B4. All six through the DSP graph
- Install userspace/ (userspace/README.md), start PipeWire; the J716 sink appears, raw device hidden.
- Sink volume 10%, pink noise at -30 dBFS for 5 minutes. Watch speakersafetyd temperatures: stop if any modelled coil
  temperature passes 90 C or any reduction is logged. During playback repeat the `kill -STOP` interlock test; the
  output must go silent within ~250 ms.
- Gate B passed = B1-B4 pass. Raising amp gain to 15, the ceiling above -30 dB, t_limit, or loading a tuned graph is
  NOT part of this plan: it needs AID41 speaker data or measurements and a separate review.
