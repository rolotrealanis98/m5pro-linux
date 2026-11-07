#!/usr/bin/env bash
# W1-POST-ROOT.sh - run on the MacBook (root) ONLY AFTER a W boot showed wlan0 and/or hci0.
# Writes the iwd/networkd config of ROOT-SETUP.md section 2, then START (not enable) iwd and bluetooth for this boot only.
# Nothing persists across a reboot except the two config files; no passphrase is handled here (connecting needs the human).
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }
install -d -m 0755 /etc/iwd
[ -e /etc/iwd/main.conf ] || cat > /etc/iwd/main.conf <<'CONF'
[General]
EnableNetworkConfiguration=false

[Network]
NameResolvingService=systemd
CONF
[ -e /etc/systemd/network/25-wireless.network ] || cat > /etc/systemd/network/25-wireless.network <<'CONF'
[Match]
Name=wlan* wlp*

[Network]
DHCP=yes
IgnoreCarrierLoss=3s

[DHCPv4]
RouteMetric=600
CONF
systemctl disable --now wpa_supplicant.service 2>/dev/null || true
rfkill unblock all || true
systemctl restart systemd-networkd
systemctl start iwd.service bluetooth.service
sleep 3
ip -br link; iw dev 2>&1 || true; rfkill list 2>&1 || true
iwctl station list 2>&1 || true
iwctl station wlan0 scan 2>&1 || true; sleep 4
echo "--- scan result (SSIDs of nearby networks; present = radio works)"
iwctl station wlan0 get-networks 2>&1 | head -20 || true
echo "--- bluetooth"
btmgmt info 2>&1 | head -12 || true
timeout 8 bluetoothctl --timeout 6 scan on 2>&1 | head -12 || true
echo "--- undo this boot's state: systemctl stop iwd bluetooth   (config files stay; rollback: ROOT-SETUP.md)"
