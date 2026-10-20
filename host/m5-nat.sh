#!/bin/bash
# Studio side of the M5 USB network, from omarchy-m5 scripts/host-usbnet.sh
# minus the parts already done (udev addressing) or not needed (docker is off).
# Persistent: NetworkManager ignores cdc_eem; ufw route-allows 10.55.0.0/16.
# Until the Studio reboots: IPv4 forwarding and NAT for 10.55.0.0/16.
set -eu

cat > /etc/NetworkManager/conf.d/90-m5-gadget.conf <<'CONF'
# omarchy-m5: the M5's USB gadget (addressed by /etc/udev/rules.d/81-m5-gadget.rules)
[keyfile]
unmanaged-devices=driver:cdc_eem
CONF
nmcli general reload conf 2>/dev/null || true

sysctl -qw net.ipv4.ip_forward=1
nft delete table ip m5nat 2>/dev/null || true
nft add table ip m5nat
nft 'add chain ip m5nat post { type nat hook postrouting priority 100; }'
nft add rule ip m5nat post ip saddr 10.55.0.0/16 ip daddr != 10.55.0.0/16 masquerade
ufw route allow from 10.55.0.0/16 >/dev/null
echo "m5 NAT up: forwarding=$(sysctl -n net.ipv4.ip_forward), $(nft list table ip m5nat | grep -c masquerade) masquerade rule"
