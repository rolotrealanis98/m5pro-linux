# j716-listen

Curses TUI for the J716s speaker listening test (`../LISTENING-TEST.md`). Python 3, stdlib only; needs `pw-play`,
`wpctl`, `journalctl`, `dmesg`, `amixer` on the MacBook. It makes its own test signals (no sox), plays them,
steps the sink volume, watches speakersafetyd and dmesg for the stop rules, and logs every play to
`~/j716-listen/results.md`.

## Install (root, once)

```
install -m 0755 j716-listen /usr/local/bin/
```

`j716-audio-ab` must already be in `/usr/local/bin/` (`stage.sh`), and speakersafetyd must run verbose for this
session (LISTENING-TEST.md section 0): the power/temperature pane and the 0.10 W stop rule read its per-speaker lines.

## Start (terminal on the MacBook, as `rolo`, not root)

```
j716-listen --check        # environment, safety state; exits non-zero if something is not ready
j716-listen                # the TUI
```

At start it runs `sudo -v` once if dmesg or the speakersafetyd journal is not readable as `rolo`; enter your
password. It then follows `journalctl -u speakersafetyd -f` and `dmesg -W` (through `sudo -n` if needed). It refuses to
play while either is not live, while the kernel ceiling is not -30 dB, or while wpctl is above 1.00.

## Test flow

1. `speakersafetyd` verbose, `j716-audio-ab status`, then `j716-listen`; `b` switches bring-up/profile (asks first, sudo).
2. Baseline on bring-up: `-`/`+` to 1.00 (steps 0.55 0.70 0.85 1.00), `space` on 1000 Hz, `p` pink, `s` sweep, `m` music.
3. `b` to profile; start at 0.55 and per step play the bass tones (arrows: 60 100 150 200 300 500 Hz), highs (2000 5000 10000), `p` then `l` `r` `c`, `s`.
4. After each play press `1` clean, `2` quiet, `3` dull/thin, `4` harsh, `5` buzz/rattle/distortion; `n` for a note; the row is saved at the next play, `Enter` or `q`.
5. Music A/B with `b` at the same volume; on a STOP banner press `o` (speakers off), then report; `x` clears the banner, `O` turns speakers back on.

Keys: `space` play/stop, `<-`/`->` tone frequency, `f` type a frequency, `t` sine, `d` tone length, `p` pink,
`s` sweep, `l`/`r`/`c` left/right/centre (plays the current signal on that channel), `m` music (`M` next file),
`a`/`z` amplitude +3/-3 dB (-40..-12 dBFS, default -20; peak, pink noise is about 10 dB lower in RMS), `+`/`-` volume,
`b` graph switch, `o`/`O` Speaker Switch off/on, `x` reset STOP, `?` help, `q` quit. Music goes in `~/j716-listen/music/`.

## Stop rules (automatic: pw-play killed, sink muted, STOP banner)

Any `tas2764 ... fault` line in dmesg; speakersafetyd panic, restart/stop, `gain limited` (or a Gain below -0.05 dB),
negative power, any speaker above 0.10 W; no speaker line for 4 s during a play. Faults already in dmesg at start only
warn. `o` runs `amixer -c AppleJ716 cset name='Speaker Switch' off` (plain first, then sudo).

## Needs root

`sudo -v` at start (dmesg, journal) unless `rolo` can read both; `sudo j716-audio-ab` for `b`; `sudo amixer` for
`o`/`O` only if plain amixer is refused. Nothing else.

## Testing without the MacBook

`j716-listen --selftest` (generates and validates every signal, plays nothing); `J716_LISTEN_FAKE=1 j716-listen`
runs the TUI against a simulator (`J716_LISTEN_FAKE_TRIP=power|fault|restart|gain|stale` forces a stop rule).
`J716_LISTEN_DIR` or `--dir` overrides `~/j716-listen`.
