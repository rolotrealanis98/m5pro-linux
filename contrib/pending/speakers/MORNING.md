# Morning: hear the J716s speakers (about 20 minutes)

Nobody has listened to these speakers yet. This is the short, safe version of `LISTENING-TEST.md` part A. Rules for the whole
session: you are in front of the machine, the lid open, one hand on the keyboard; start at the lowest level and go up one step
at a time; the kernel's -30 dB ceiling stays on (nothing here lifts it); any wrong sound means stop first, think second.

## Before you start (one look)

The machine must be on the `speakers` kernel (the one with the ramp-down fix; `uname -r` and the request's result say which)
and speakerguardd v2 must be running. In a root shell:

```
/root/audio-j716/speakerguardd-v2/sgv2-silent-check.sh verify 2>&1 | grep -E 'RESULT (supervisor|ceiling|amp-gain|ucm|graph|speakersafetyd)|FAIL|STEP'
```

Good: `supervisor PASS`, `ceiling PASS`, `ucm PASS`, `graph-voicing PASS`, `speakersafetyd PASS`, `0 FAIL`. If anything says FAIL,
or `speakerguardd-v2` is not active, do not play anything: the speakers are silent and safe; the reason is in
`journalctl -u 'speakerguardd-v2*' -u aurora-speaker-upgrade -b` and in `/root/speakers-silent/results.txt`. A refusal by v2 (macOS 27.3
tuning not matching its reference, no speaker id) is the safe outcome, not a fault; there is no way to force it and there must not be.

## Stop pad (do this first, leave it open)

Open a second terminal, become root, and type this line but do not press Enter:

```
pkill -x pw-play; systemctl stop speakerguardd-v2
```

Enter on that line ends any sound: `pw-play` dies, and the supervisor stops renewing the 50 ms lease, so the kernel puts the amps at
their floor within a few tens of milliseconds. Hold the power button for anything worse (smell, heat, a loud pop).

Third terminal, root, the log (watch it, the stop rules read it):

```
journalctl -k -f | grep -iE 'tas2764|sn012776|macaudio|speaker|fault|over-?(current|temp)'
```

## 1. Silent setup (as your desktop user, in the desktop session)

```
ID=$(pw-dump | python3 -c 'import json,sys;print(next(o["id"] for o in json.load(sys.stdin) if o.get("info",{}).get("props",{}).get("node.name")=="sgv2.voicing.j716"))')
echo "voicing sink id: $ID"
wpctl set-default $ID; wpctl set-mute $ID 1; wpctl set-volume $ID 0
wpctl get-volume $ID                       # Volume: 0.00 [MUTED]
sh /usr/share/asahi-audio/j716/profile/make-test-signals.sh   # ~/j716-listen/, every file at -20 dBFS (needs sox)
```

No `ID`: the sink is missing, stop here (see "Before you start").

## 2. First sound: 1 kHz at 5 %

Unmute, set 5 %, play 3 seconds to that sink only. Sit 30 cm from the keyboard, ears at the keys.

```
wpctl set-mute $ID 0; wpctl set-volume $ID 0.05
timeout 5 pw-play --target sgv2.voicing.j716 ~/j716-listen/t1k.wav
```

5 % is nearly silent by design: macOS's volume law at 5 % of the slider, 30 dB under the amps' full gain. Hear nothing? Go to
10 %, 15 %, 20 %, 30 %, one 3 s tone each (`wpctl set-volume $ID 0.10` and the same `pw-play`). Do not go over 30 % in this
first run; if 30 % is still too faint to judge, say so, that is a result.

During one tone (in the background with `&`, then the telemetry read), record what v2 reads:

```
timeout 5 pw-play --target sgv2.voicing.j716 ~/j716-listen/t1k.wav &
sleep 0.5; sudo sgv2-telemetry --watch 4 --log /root/sgv2-watch.log
```

Read the `RESULT` lines (what they mean: `/Volumes/m5pro/bench/requests/speakers-5.md`). `sense-alive`, `model-fed`, `health`
and `finite` must PASS before going higher. On this Mac's unit (spp3) `P_meas` is always 0 and the unit-wide meters are absent
(not a fault), and `V2`/`I2` are the 43.9 Hz pilot-bin powers: below 30 mW of drive per channel they sit at the sense noise floor
(about 1e-9 / 1e-10), which proves the sense arrives; exactly 0 while playing means it does not. If `P_mod` reads far above what
a quiet 1 kHz tone should be (microwatts at 5 %, a few milliwatts per woofer at 20-30 %), note it, do not go higher.

## 3. What to listen for, quietest first (20 % or the lowest level you can hear; 3 s each)

```
for f in b60 b100 b150 b200 b300 b500 h2000 h5000 h10000; do echo $f; timeout 5 pw-play --target sgv2.voicing.j716 ~/j716-listen/$f.wav; done
for f in pinkL pinkR pinkC; do echo $f; timeout 8 pw-play --target sgv2.voicing.j716 ~/j716-listen/$f.wav; done
```

- Bass (b60 to b200): a clean low tone, or rattle, buzz, or nothing at all (60 Hz is below what these woofers do quietly; that is normal).
- b300 to b500 and h2000: no hole or jump at the woofer-to-tweeter handover (about 1-3 kHz).
- h5000, h10000: clean, not harsh, not hissy.
- pinkL, pinkR, pinkC: left from the left, right from the right, centre in the middle; no sound from the wrong side.
- Music you know, last: `pw-play --target sgv2.voicing.j716 <file>` at 10-30 %; pause and seek once and listen for pops. Compare with macOS if you can.

## Stop immediately (Enter on the stop pad, then write down what you heard) if

- any tas2764 / sn012776 / fault / over-temperature line appears in the log terminal;
- distortion, buzz, crackle, a pop, sound from the wrong side, sound that does not stop at the end of the file;
- speakerguardd-v2 restarts or the gate says another stack;
- `sgv2-telemetry --watch` prints any `RESULT ... FAIL`, a NaN in a channel's P_mod, coil or gain, or a coil temperature that
  keeps rising (the "global: absent" line is normal on spp3).

## Put it back to quiet

```
wpctl set-volume $ID 0.05; wpctl set-mute $ID 1
```

To leave the speakers at the kernel floor entirely: `systemctl disable aurora-speaker-upgrade; aurora-speaker-upgrade --revert`
(speakersafetyd stays held off, so the speakers stay silent).

## Record (paste into the PR or the vault)

| check | result |
|---|---|
| `verify` result lines | |
| lowest slider level you could hear 1 kHz | |
| telemetry at that level: RESULT lines, P_mod, V2, I2, coil | |
| bass / handover / highs | |
| left, right, centre | |
| pops on pause and seek | |
| anything in the kernel log | |
