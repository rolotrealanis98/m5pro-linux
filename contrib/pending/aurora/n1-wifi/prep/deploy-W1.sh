#!/usr/bin/env bash
# deploy w1-n1train-20261107-3c0a1eff.bin: steps 0-2 of mk-daily.py --deploy-plan plus guard 0b. Does NOT reboot.
# usage: HOST=root@<macbook-ip> bash deploy-W1.sh
set -eu
# ---- deploy plan for w1-n1train-20261107-3c0a1eff.bin (PRINTED ONLY, nothing was run) ----
# Policy: ESP-POLICY.md. a failed test reverts itself: if the root mounts but the network is not up 90 s after network-online, boot.bin.prev is copied over boot.bin and the machine reboots; a payload that never mounts the root is NOT covered (macOS: r1-deploy.sh restore prev).
HOST=${HOST:?set HOST=root@<macbook-ip>}   # the running Linux root, over ssh
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
PAYLOAD=$HOME/Work/agents/aurora-kernel/payloads/w1-n1train-20261107-3c0a1eff.bin
SHA=3c0a1eff5525cf20495e61f33481f2b9aec2d7d38a6b1322ae5d52468183e97b

# 0. preflight on the machine: ESP mounted, room for two copies, at most four payloads at rest,
#    stale transients removed
ssh "${SSHO[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -eu
mountpoint -q /boot || mount /dev/nvme0n1p4 /boot
cd /boot/m1n1
rm -f boot.bin.new boot.bin.prev.new
ls -l boot.bin*; sha256sum boot.bin*
free=$(df -Pm /boot | awk 'NR==2{print $4}')
[ "$free" -ge 94 ] || { echo "ESP has $free MB free, need 94: prune first (ESP-POLICY.md)"; exit 1; }
n=$(ls boot.bin* | wc -l)
[ "$n" -le 4 ] || { echo "$n payloads on the ESP, at most four: prune first"; exit 1; }
echo "preflight ok: $free MB free, $n payloads"
REMOTE

# 0b. GUARD (added by prep): boot.bin.prev must end up as the daily 275d84ec. The stock plan copies whatever boot.bin is
#     onto prev when the RUNNING payload is not a test; after an A/B stage-1 fallback boot.bin is still the failed test
#     while the machine runs the daily, and the stock plan would then overwrite prev with the failed test.
ssh "${SSHO[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -eu
cd /boot/m1n1
D=275d84ecfee87a2441e9cbd3f550129101dc82680e38abdb01c37c159af8d030
bs=$(sha256sum boot.bin | cut -d' ' -f1); ps=$(sha256sum boot.bin.prev | cut -d' ' -f1)
if grep -q 'm5.selftest=1' /proc/cmdline; then
    [ "$ps" = "$D" ] || { echo "ABORT: running a test and boot.bin.prev is not the daily ($ps)"; exit 1; }
    echo "guard ok: test boot running, prev is the daily"
elif [ "$bs" = "$D" ]; then
    echo "guard ok: boot.bin is the daily (the plan will make prev = daily)"
elif [ "$ps" = "$D" ]; then
    echo "boot.bin is a leftover failed test and the machine runs the daily: restoring boot.bin from prev"
    cp boot.bin.prev boot.bin.restore && sync
    [ "$(sha256sum boot.bin.restore | cut -d' ' -f1)" = "$D" ] || { rm -f boot.bin.restore; echo ABORT; exit 1; }
    mv -f boot.bin.restore boot.bin && sync && echo "boot.bin = daily again"
else
    echo "ABORT: neither boot.bin nor boot.bin.prev is the daily: stop and ask Rolando"; exit 1
fi
REMOTE

# 1. copy to boot.bin.new (boot.bin is untouched until step 2)
scp "${SSHO[@]}" "$PAYLOAD" "$HOST:/boot/m1n1/boot.bin.new"

# 2. verify the sha, keep boot.bin.prev = the last known-good, then move into place
ssh "${SSHO[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -eu
cd /boot/m1n1
SHA=3c0a1eff5525cf20495e61f33481f2b9aec2d7d38a6b1322ae5d52468183e97b
sync
got=$(sha256sum boot.bin.new | cut -d' ' -f1)
[ "$got" = "$SHA" ] || { echo "boot.bin.new is $got, expected $SHA: boot.bin untouched"; rm -f boot.bin.new; exit 1; }
echo "boot.bin.new verified"
# boot.bin.prev must be a payload known to reach the network. The running boot.bin is one (you are
# logged in over ssh), unless it is itself a test (m5.selftest=1): then prev stays the older daily.
if grep -q 'm5.selftest=1' /proc/cmdline; then
    echo "running payload is a test (m5.selftest=1): boot.bin.prev stays as is"
elif [ "$(sha256sum boot.bin | cut -d' ' -f1)" = "$SHA" ]; then
    echo "boot.bin already is this payload: boot.bin.prev stays as is"
else
    cur=$(sha256sum boot.bin | cut -d' ' -f1)
    cp boot.bin boot.bin.prev.new && sync
    [ "$(sha256sum boot.bin.prev.new | cut -d' ' -f1)" = "$cur" ] || { echo "prev copy mismatch: nothing replaced"; rm -f boot.bin.prev.new boot.bin.new; exit 1; }
    mv -f boot.bin.prev.new boot.bin.prev
    echo "boot.bin.prev = $cur (the payload running now)"
fi
mv -f boot.bin.new boot.bin
sync
[ "$(sha256sum boot.bin | cut -d' ' -f1)" = "$SHA" ] || { echo "boot.bin hash wrong after the move: restore prev by hand"; exit 1; }
echo "boot.bin = w1-n1train-20261107-3c0a1eff.bin"
ls -l boot.bin*
REMOTE

