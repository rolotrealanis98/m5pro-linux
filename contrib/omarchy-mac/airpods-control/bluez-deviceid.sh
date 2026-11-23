#!/usr/bin/env bash
# bluez-deviceid.sh - OPTIONAL, reversible: make BlueZ present Apple's Bluetooth vendor ID (DeviceID = bluetooth:004C:0000:0000).
#   sudo bluez-deviceid.sh status | enable [--restart] | disable [--restart]
# Not needed for noise control, battery, ear detection or conversation awareness (airpods-mode works without it).
# Upstream LibrePods only asks for it for hearing-aid, transparency tuning, renaming and multi-device handoff.
# Effects: BlueZ's SDP Device ID record (PnP) changes for EVERY device this Mac talks to, and AirPods cache the value
# at pairing (re-pair after changing it). `--restart` restarts bluetoothd: the AirPods and any Bluetooth audio drop for a few seconds.
set -euo pipefail
CONF=/etc/bluetooth/main.conf
LINE='DeviceID = bluetooth:004C:0000:0000'
TAG='# omarchy-mac airpods-control'
cmd=${1:-status}; restart=0; [ "${2:-}" = --restart ] && restart=1
[ "$cmd" = status ] || [ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$CONF" ] || { echo "$CONF not found" >&2; exit 1; }
present() { grep -qxF "$TAG" "$CONF"; }
case $cmd in
  status) if present; then echo "enabled: $(grep -A1 -xF "$TAG" "$CONF" | tail -1)"; else echo "disabled (stock). Active DeviceID lines:"; grep -n '^DeviceID' "$CONF" || echo "  none"; fi; exit 0;;
  enable)
    if grep -q '^DeviceID' "$CONF" && ! present; then echo "$CONF already has its own DeviceID line; not touching it" >&2; exit 1; fi
    if present; then echo "already enabled"; else
      [ -e "$CONF.before-omarchy-mac" ] || cp -p "$CONF" "$CONF.before-omarchy-mac"
      grep -q '^\[General\]' "$CONF" || { echo "no [General] section in $CONF" >&2; exit 1; }
      sed -i "/^\[General\]/a $TAG\n$LINE" "$CONF"; echo "enabled: $LINE"
    fi;;
  disable) if present; then sed -i "\|^$TAG\$|{N;d;}" "$CONF"; echo "disabled"; else echo "already disabled"; fi;;
  *) echo "usage: $0 status|enable|disable [--restart]" >&2; exit 2;;
esac
if [ $restart = 1 ]; then echo "restarting bluetooth (AirPods drop briefly)"; systemctl restart bluetooth
else echo "not applied until: sudo systemctl restart bluetooth  (drops Bluetooth audio for a few seconds; re-pair the AirPods after enabling)"; fi
