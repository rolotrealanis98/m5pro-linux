#!/bin/sh
# Runs IN the eem-vm Debian guest as root (PLANNING PROTOTYPE, UNTESTED). Started once by
# `eem-vm.py --keep --netconsole` (proposed flag) with: sudo nohup sh netconsole-guest.sh &
#  - re-applies 10.55.0.1/24 (udc0) / 10.55.2.1/24 (udc2) every 0.5 s, so a gadget that
#    re-enumerates after an M5 reboot has an address before the M5's initramfs enables
#    netconsole (QEMU's usb-host vendorid/productid match re-attaches it on its own);
#  - receives netconsole on UDP 6666, keeps a copy in /var/log/m5-netconsole.log and forwards
#    every datagram to the Mac through QEMU user networking (10.0.2.2 = the host).
modprobe cdc_eem 2>/dev/null
command -v socat >/dev/null || apt-get install -y socat >/dev/null 2>&1
socat -u UDP4-RECV:6666,reuseaddr \
    SYSTEM:'tee -a /var/log/m5-netconsole.log | socat -u - UDP4-SENDTO:10.0.2.2:6666' &
while :; do
    for d in /sys/class/net/*; do
        n=${d##*/}
        [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = cdc_eem ] || continue
        case "$(cat "$d/device/../product" 2>/dev/null)" in
            *udc0*) ip=10.55.0.1 ;; *udc2*) ip=10.55.2.1 ;; *) continue ;;
        esac
        ip -4 addr show dev "$n" | grep -q "inet $ip/" || { ip link set "$n" up; ip addr add "$ip/24" dev "$n"; }
    done
    sleep 0.5
done
