#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Test signals for the J716 listening check (LISTENING-TEST.md). Run as the
# desktop user; writes ~/j716-listen/. Needs sox. Every file is at or below
# -20 dBFS except the music you add yourself.
set -eu
D=${1:-$HOME/j716-listen}
mkdir -p "$D"
cd "$D"
s() { sox -n -r 48000 -c 2 -b 16 "$@"; }
s t1k.wav synth 3 sine 1000 gain -20 fade 0.02 3 0.02
for f in 60 100 150 200 300 500; do s "b$f.wav" synth 3 sine "$f" gain -20 fade 0.02 3 0.02; done
for f in 2000 5000 10000; do s "h$f.wav" synth 3 sine "$f" gain -20 fade 0.02 3 0.02; done
s sweep.wav synth 20 sine 40:20000 gain -20 fade 0.05 20 0.05
s pink.wav synth 10 pinknoise gain -20 fade 0.05 10 0.05
sox -n -r 48000 -c 1 -b 16 pinkm.wav synth 6 pinknoise gain -20 fade 0.05 6 0.05
sox pinkm.wav pinkL.wav remix 1 0
sox pinkm.wav pinkR.wav remix 0 1
sox pinkm.wav pinkC.wav remix 1 1
rm pinkm.wav
ls -1 "$D"
