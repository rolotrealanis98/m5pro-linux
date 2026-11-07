#!/bin/sh
# netconsole-recv.sh [PORT] - receive the J716s netconsole on the Studio; one timestamped line per
# kernel line, appended to ~/Work/agents/n1-wifi/logs/netconsole-<start>.log and echoed. Stdlib perl
# (no socat/ts needed). Stop with Ctrl-C. macOS firewall: allow perl for incoming UDP if asked.
P=${1:-6666}; L=$HOME/Work/agents/n1-wifi/logs; mkdir -p "$L"
perl -MIO::Socket::INET -MPOSIX=strftime -e '$|=1; $s=IO::Socket::INET->new(LocalPort=>shift, Proto=>"udp", ReuseAddr=>1) or die "bind: $!\n"; while (defined $s->recv($m, 65535)) { print strftime("%Y-%m-%dT%H:%M:%S ", localtime), $_, "\n" for split /\n/, $m }' "$P" | tee -a "$L/netconsole-$(date +%Y%m%d-%H%M%S).log"
