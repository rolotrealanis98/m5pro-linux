#!/bin/bash
# usb4-check.sh: USB4/Thunderbolt state and a Thunderbolt-networking throughput run on the J716s. Run as root.
#   usb4-check.sh            state only (Type-C ports, routers, domains, links, thunderbolt0)
#   usb4-check.sh net [PEER] + ping and iperf3 over thunderbolt0 to the peer's iperf3 server (iperf3 -s on the Studio).
#                            PEER: an address on the peer's Thunderbolt Bridge; default: the first IPv6 link-local
#                            neighbour that answers on thunderbolt0 (no address needs to be set on either machine).
# Changes nothing on the machine: no addresses, routes or connection profiles; every step bounded by timeout.
# Output: /root/usb4-check-<date>/ and a summary on stdout. The folder holds router UIDs and addresses: keep it local.
set -u
O=/root/usb4-check-$(date +%Y%m%d-%H%M%S); mkdir -p "$O"; cd "$O" || exit 1
T() { local f=$1 s=$2; shift 2; echo "== $*" >> "$f"; timeout "$s" "$@" >> "$f" 2>&1; echo "rc=$?" >> "$f"; }
S() { echo "$*" | tee -a summary.txt; }
TBD=/sys/bus/thunderbolt/devices
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

T state.txt 5 uname -r
T state.txt 5 cat /proc/cmdline
for p in /sys/class/typec/port?; do
  [ -e "$p" ] || continue
  T state.txt 5 sh -c "echo $p \$(readlink -f $p/device); cat $p/data_role $p/power_role $p/orientation 2>/dev/null; ls -d $p-partner $p-cable 2>/dev/null || echo no-partner"
  for a in $p-partner/$(basename $p)-partner.*; do [ -e "$a" ] && T state.txt 5 sh -c "echo $a svid=\$(cat $a/svid) vdo=\$(cat $a/vdo 2>/dev/null) active=\$(cat $a/active 2>/dev/null)"; done
  [ -e $p-partner/identity ] && T state.txt 5 grep -r . $p-partner/identity
  [ -e $p-cable/identity ] && T state.txt 5 grep -r . $p-cable/identity $p-cable/type $p-cable/plug_type
done
T state.txt 5 sh -c 'for d in /sys/bus/platform/devices/*.acio /sys/bus/platform/devices/*.nhi; do [ -e "$d" ] && echo "$(basename $d) -> $(basename "$(readlink -f $d/driver 2>/dev/null)")"; done'
T state.txt 5 ls -l $TBD/
for d in $TBD/*; do
  [ -e "$d" ] || continue
  T state.txt 5 sh -c "cd $d; echo \$(basename $d) \$(readlink -f $d | sed 's|.*/devices/||'); for f in device_name vendor_name generation security authorized rx_speed rx_lanes tx_speed tx_lanes; do [ -r \$f ] && echo \"  \$f=\$(cat \$f)\"; done"
done
T state.txt 5 sh -c 'lsusb -t; ip -br link; ip -br addr'
T state.txt 5 sh -c 'ip -d link show thunderbolt0 2>/dev/null || echo "no thunderbolt0"'
dmesg > dmesg.txt
grep -E "router off|partner gone|TBT cable|USB4 cable|Lane init|RT Broadcast|entered CL0|new host|new device|host disconnected|thunderbolt0|DROM|NHI|Invalid cable|failed|assert|SError" dmesg.txt \
  | grep -iE "acio|nhi|thunderbolt|tbnet|tipd|SError" > dmesg-usb4.txt

S "kernel $(uname -r)"
for p in /sys/class/typec/port?; do
  [ -e "$p" ] || continue
  S "$(basename $p) $(basename "$(readlink -f $p/device)") data=$(cat $p/data_role) partner=$([ -e $p-partner ] && echo yes || echo no) altmodes=$(cat $p-partner/*/svid 2>/dev/null | tr '\n' ' ')"
done
S "routers bound: $(ls /sys/bus/platform/drivers/thunderbolt-apple-acio 2>/dev/null | grep -c acio), NHIs up: $(ls /sys/bus/platform/drivers/thunderbolt-apple-nhi 2>/dev/null | grep -c nhi)"
n=0
for d in $TBD/*; do
  [ -e "$d" ] || continue; b=$(basename $d)
  case $b in domain*) S "$b security=$(cat $d/security 2>/dev/null)"; n=$((n+1)); continue;; esac
  [ -r $d/device_name ] || continue
  S "$b $(cat $d/vendor_name 2>/dev/null) $(cat $d/device_name 2>/dev/null) gen=$(cat $d/generation 2>/dev/null) rx=$(cat $d/rx_speed 2>/dev/null)x$(cat $d/rx_lanes 2>/dev/null) tx=$(cat $d/tx_speed 2>/dev/null)x$(cat $d/tx_lanes 2>/dev/null) $( [ -r $d/authorized ] && echo authorized=$(cat $d/authorized))"
done
[ $n -eq 0 ] && S "no USB4 domain: no USB4/Thunderbolt partner on any router port (see dmesg-usb4.txt: 'router off until ...')"
S "dmesg: $(grep -c . dmesg-usb4.txt) USB4 lines; errors: $(grep -ciE 'fail|assert|SError|Invalid cable' dmesg-usb4.txt)"

[ "${1:-}" = net ] || { echo "folder $O"; exit 0; }
ip link show thunderbolt0 >/dev/null 2>&1 || { S "net: no thunderbolt0 (thunderbolt_net not bound: is an XDomain host listed above?)"; echo "folder $O"; exit 1; }
PEER=${2:-}
if [ -z "$PEER" ]; then
  timeout 8 ping -6 -c 3 -I thunderbolt0 ff02::1 > ping-all.txt 2>&1
  mine=$(ip -6 -br addr show thunderbolt0 | grep -o 'fe80::[0-9a-f:]*' | head -1)
  PEER=$(grep -o 'from fe80::[0-9a-f:]*' ping-all.txt | awk '{print $2}' | grep -vx "$mine" | head -1)
  [ -n "$PEER" ] && PEER="$PEER%thunderbolt0"
fi
[ -n "$PEER" ] || { S "net: no peer answered on thunderbolt0 (is the Studio's Thunderbolt Bridge active? pass PEER)"; echo "folder $O"; exit 1; }
S "net: peer found on thunderbolt0, mtu $(cat /sys/class/net/thunderbolt0/mtu)"
T net.txt 15 ping -c 5 -i 0.2 "$PEER"
S "ping: $(grep -E 'packet loss|rtt' net.txt | tr '\n' ' ')"
for args in "-t 10" "-t 10 -R" "-t 10 -P 4" "-t 10 -P 4 -R"; do
  T net.txt 30 iperf3 -c "$PEER" $args
  S "iperf3 $args: $(sed -n "/iperf3 -c .* $args\$/,/rc=/p" net.txt | grep -E 'receiver' | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')"
done
dmesg | tail -n +$(($(wc -l < dmesg.txt)+1)) > dmesg-during-net.txt
S "dmesg during net: $(grep -ciE 'fail|assert|SError|disconnected|timeout' dmesg-during-net.txt) error-like lines"
echo "folder $O"
