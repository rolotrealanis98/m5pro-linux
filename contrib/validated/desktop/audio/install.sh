#!/bin/sh
# Install the J716 jack / Bluetooth / UCM userspace on the M5 Pro's Arch root.
# Run as root from this directory. Replaced files are kept as .orig (first time only).
# Nothing here restarts a service; WirePlumber and the UCM profile pick the files up
# the next time WirePlumber starts (login or reboot).
set -eu
U=/usr/share/alsa/ucm2/conf.d/macaudio
W=/usr/share/wireplumber/wireplumber.conf.d
[ -e "$U/MacBook Pro J716.conf" ] && [ ! -e "$U/MacBook Pro J716.conf.orig" ] &&
    cp -a "$U/MacBook Pro J716.conf" "$U/MacBook Pro J716.conf.orig"
install -Dm0644 ucm/j716/HiFi.conf "$U/j716/HiFi.conf"
install -Dm0644 ucm/j716/Headphones.conf "$U/j716/Headphones.conf"
install -Dm0644 "ucm/MacBook Pro J716.conf" "$U/MacBook Pro J716.conf"
install -Dm0644 wireplumber/99-asahi-j716-jack.conf "$W/99-asahi-j716-jack.conf"
install -Dm0644 wireplumber/99-asahi-j716-bluetooth.conf "$W/99-asahi-j716-bluetooth.conf"
alsaucm -c hw:AppleJ716 list _devices/HiFi
