#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Stage the J716 speaker profile on the M5 Pro's root without activating it.
# Run as root from this directory. Writes only:
#   /usr/share/asahi-audio/j716/profile/   graphs, FIRs, fragment and daemon variants
#   /usr/local/bin/j716-audio-ab           the A/B switch
# The active files (wireplumber.conf.d/99-asahi-j716.conf, asahi-audio/j716/graph.json,
# speakersafetyd/apple/j716.conf) are not touched; `j716-audio-ab` swaps them later.
set -eu
D=/usr/share/asahi-audio/j716/profile
install -dm0755 "$D" "$D/wireplumber" "$D/speakersafetyd"
install -m0644 graph.json graph-bankstown.json "$D/"
install -m0644 firs/woofers-44.wav firs/woofers-48.wav firs/woofers-96.wav firs/woofers-192.wav \
	firs/tweeters-44.wav firs/tweeters-48.wav firs/tweeters-96.wav firs/tweeters-192.wav "$D/"
install -m0644 wireplumber/99-asahi-j716.conf.bringup wireplumber/99-asahi-j716.conf.profile \
	wireplumber/99-asahi-j716.conf.profile-bankstown "$D/wireplumber/"
install -m0644 speakersafetyd/j716.conf.bringup speakersafetyd/j716.conf.aid41 "$D/speakersafetyd/"
install -m0644 tests/render-check.py make-test-signals.sh "$D/"
install -m0755 j716-audio-ab /usr/local/bin/j716-audio-ab
cd "$D" && sha256sum graph.json graph-bankstown.json ./*.wav wireplumber/* speakersafetyd/* render-check.py make-test-signals.sh
/usr/local/bin/j716-audio-ab status
