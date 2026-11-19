#!/bin/bash
# Install the USB-C port controller re-probe at boot. Run as root from this folder:  bash install.sh [--uninstall]
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = --uninstall ]; then
    systemctl disable m5pro-usbpd-rebind.service 2>/dev/null || true
    rm -f /etc/systemd/system/m5pro-usbpd-rebind.service /usr/local/bin/m5pro-usbpd-rebind
    systemctl daemon-reload; echo removed; exit 0
fi
install -m755 files/usr/local/bin/m5pro-usbpd-rebind /usr/local/bin/m5pro-usbpd-rebind
install -m644 files/etc/systemd/system/m5pro-usbpd-rebind.service /etc/systemd/system/m5pro-usbpd-rebind.service
systemctl daemon-reload
systemctl enable m5pro-usbpd-rebind.service
echo installed
