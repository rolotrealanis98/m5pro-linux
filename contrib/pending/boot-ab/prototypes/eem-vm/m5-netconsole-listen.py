#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Mac side of the netconsole path (PLANNING PROTOTYPE, UNTESTED): the eem-vm guest forwards the
# M5's netconsole datagrams to the host's UDP 6666 (QEMU slirp maps 10.0.2.2 -> 127.0.0.1).
# Appends them, prefixed with the Mac's wall clock, to ~/Work/m5-logs/netconsole.log, which
# m5-deploy.sh slices per deploy. Run under launchd (KeepAlive) or tmux.
import os, socket, time
log = os.path.expanduser("~/Work/m5-logs/netconsole.log")
os.makedirs(os.path.dirname(log), exist_ok=True)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 6666))
with open(log, "a", buffering=1) as f:
    while True:
        data, _ = s.recvfrom(65535)
        ts = time.strftime("%Y%m%d-%H%M%S")
        for line in data.decode("utf-8", "replace").splitlines():
            f.write(f"{ts} {line}\n")
