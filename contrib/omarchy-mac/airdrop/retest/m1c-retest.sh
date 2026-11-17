#!/bin/bash
# SPDX-License-Identifier: MIT
# airdrop M1c retest, run from the Studio: start the N1 firmware's AWDL with all nine blocks, watch for
# AWDL frames from a nearby iPhone, and if the firmware halts, save its crash log before anything else.
#
#   MBP="ssh -i ... root@HOST" m1c-retest.sh [--seq 149|6+149|default] [--no-ext] [--release REL]
#   MBP=... m1c-retest.sh --collect STAMP      after a halt/reboot: fetch the Mac's copy and decode it
#
# Needs the M1c kernel on the MacBook and contrib/omarchy-mac/airdrop/{aci-probe.py,n1-crashlog.py}.
# Owner present, iPhone near the Mac with AirDrop on "Everyone for 10 minutes" BEFORE this starts.
#
# Safety: a transient root unit, airdrop-m1c-watchdog, reboots the Mac if for 90 s in a row neither
# Wi-Fi (carrier + association + default gateway answering) nor the wired link (enu1u2u2 with carrier
# and an IPv4 address) works. With the travel router's cable in, a firmware halt does not reboot: the
# run continues over the wire. A second unit, airdrop-m1c-mirror, copies the event and frame logs every
# 2 s to /root/airdrop-m1c-<stamp>/ and, the moment the kernel reports a halt, saves the crash log
# there (it survives the reboot). This script also copies them to the Studio every step.
set -uo pipefail

SEQ=149 EXT="" REL="" COLLECT="" HERE=$(cd "$(dirname "$0")/.." && pwd)
while (($#)); do
  case "$1" in
  --collect) COLLECT="$2"; shift 2 ;;   # after a reboot: fetch /root/airdrop-m1c-STAMP and decode
  --seq) SEQ="$2"; shift 2 ;;
  --no-ext) EXT="--no-ext"; shift ;;
  --release) REL="$2"; shift 2 ;;
  *) echo "usage: $0 [--seq 149|6+149|default] [--no-ext] [--release REL]" >&2; exit 2 ;;
  esac
done
: "${MBP:?set MBP to the ssh command for the MacBook (root)}"
STAMP=${COLLECT:-$(date +%Y%m%d-%H%M%S)}
LOCAL=${LOCAL_DIR:-/Volumes/m5pro/bench/airdrop/m1c-$STAMP}
REMOTE=/root/airdrop-m1c-$STAMP
mkdir -p "$LOCAL"
LOG=$LOCAL/run.log

mbp() { timeout 40 $MBP "$@"; }
say() { echo "### $(date +%FT%T) $*" | tee -a "$LOG"; }
pull() { mbp "cat $REMOTE/mirror.log 2>/dev/null | tail -3; tail -4 $REMOTE/aci_events.all 2>/dev/null; tail -3 $REMOTE/aci_frames.all 2>/dev/null" >> "$LOCAL/pulled.log" 2>&1 || true; }

# step LABEL CMD: run on the Mac under timeout 8, logged on both sides; stop at a failure.
step() {
  local label=$1; shift
  say "[$label] $*"
  mbp "cd /root; { echo '### [$label] $*'; timeout 8 $*; echo \"rc=\$?\"; } 2>&1 | tee -a $REMOTE/run.log" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  pull
  # A probe command must print its result line; no line means the tool did not run.
  if [[ $* == *aci-probe.py* && $* != *" frames"* ]] && ! tail -40 "$LOG" | sed -n "/\[$label\]/,\$p" | grep -q -E '^result |^start --full'; then
    say "[$label] no result line from aci-probe.py: stopping"
    finish
    exit 1
  fi
  if ((rc != 0)) || tail -4 "$LOG" | grep -q -E '^rc=[1-9]|result -[0-9]|firmware status [1-9]'; then
    say "[$label] FAILED (ssh rc=$rc): stopping. Saved state: $REMOTE (Mac), $LOCAL (Studio)"
    finish
    exit 1
  fi
}

finish() {
  say "[finish] collecting"
  mbp "python3 /root/aci-probe.py halt; python3 /root/aci-probe.py save $REMOTE/end; ls -la $REMOTE $REMOTE/halt 2>/dev/null" 2>&1 | tee -a "$LOG"
  mbp "tar -C /root -cf - airdrop-m1c-$STAMP" 2>/dev/null | tar -C "$LOCAL" -xf - 2>/dev/null
  if [[ -s $LOCAL/airdrop-m1c-$STAMP/halt/halt_info ]]; then
    say "[finish] firmware halt captured: decoding"
    python3 -I "$HERE/n1-crashlog.py" "$LOCAL/airdrop-m1c-$STAMP/halt" "${FTAB:-/Volumes/m5pro/bench/airdrop/fw/j716s-ftab.bin}" 2>&1 | tee -a "$LOG"
  fi
}

if [[ -n $COLLECT ]]; then finish; exit 0; fi
say "M1c retest: seq=$SEQ ext=${EXT:-on}; Mac dir $REMOTE; Studio dir $LOCAL"
mbp "uname -r; ip -br addr show enu1u2u2; ip -br link show wlan0" 2>&1 | tee -a "$LOG"
if [[ -n $REL ]] && ! mbp "uname -r" | grep -qx "$REL"; then say "not on $REL: stop"; exit 1; fi
# Upload by redirection and check the size: the 10:46 run piped them and the Mac got 0-byte files,
# so every probe step was a silent no-op (python3 on an empty file exits 0).
upload() {
  local src=$1 dst=$2 want got
  want=$(wc -c < "$src" | tr -d ' ')
  mbp "cat > $dst" < "$src"
  got=$(mbp "wc -c < $dst" < /dev/null | tr -d ' \r')
  if [[ $got != "$want" ]]; then say "upload of $dst: $got bytes, expected $want: stop"; exit 1; fi
  say "uploaded $dst ($got bytes)"
}
mbp "mkdir -p $REMOTE" < /dev/null
upload "$HERE/aci-probe.py" /root/aci-probe.py
upload "$HERE/n1-crashlog.py" /root/n1-crashlog.py
mbp "test -e /sys/kernel/debug/ieee80211/phy0/halt_check" || { say "kernel has no halt capture (not M1c): stop"; exit 1; }

# The watchdog and the mirror, as transient units (gone at the next boot).
mbp "cat > /root/m1c-watchdog.sh" <<'EOF'
#!/bin/bash
LOG=$1; GW=$(ip -4 route show default dev wlan0 | awk '{print $3; exit}')
echo "$(date -Is) watchdog armed" >> "$LOG"
last_ok=$(date +%s)
while true; do
  wifi=0 wired=0
  if [ "$(cat /sys/class/net/wlan0/carrier 2>/dev/null)" = 1 ] && iw dev wlan0 link 2>/dev/null | grep -q '^Connected' \
     && { ping -c1 -W2 -I wlan0 "$GW" >/dev/null 2>&1 || ping -c1 -W2 -I wlan0 "$GW" >/dev/null 2>&1; }; then wifi=1; fi
  if [ "$(cat /sys/class/net/enu1u2u2/carrier 2>/dev/null)" = 1 ] && ip -4 -br addr show enu1u2u2 | grep -q '[0-9]\.'; then wired=1; fi
  now=$(date +%s)
  if [ $wifi = 1 ] || [ $wired = 1 ]; then last_ok=$now
  elif [ $((now - last_ok)) -ge 90 ]; then
    echo "$(date -Is) watchdog: no Wi-Fi and no wired link for $((now - last_ok)) s, rebooting" >> "$LOG"; sync; systemctl reboot; exit 0
  fi
  sleep 5
done
EOF
mbp "cat > /root/m1c-mirror.sh" <<'EOF'
#!/bin/bash
D=$1; DBG=/sys/kernel/debug/ieee80211/phy0; mkdir -p "$D"; le=-1; lf=-1
while true; do
  st=$(cat $DBG/halt_check 2>/dev/null)     # reading it captures a halt
  echo "$(date +%T) $st" >> "$D/mirror.log"
  cat $DBG/aci_events 2>/dev/null | awk -v l=$le '$1>l' >> "$D/aci_events.all"
  cat $DBG/aci_frames 2>/dev/null | awk -v l=$lf '$1>l' >> "$D/aci_frames.all"
  le=$(tail -1 "$D/aci_events.all" 2>/dev/null | awk '{print $1+0}'); lf=$(tail -1 "$D/aci_frames.all" 2>/dev/null | awk '{print $1+0}')
  : "${le:=-1}" "${lf:=-1}"
  if echo "$st" | grep -q 'captured 1' && [ ! -s "$D/halt/halt_info" ]; then
    python3 /root/aci-probe.py save "$D/halt" >> "$D/mirror.log" 2>&1
    journalctl -k -b --no-pager | tail -60 > "$D/halt/kernel.log"
  fi
  sync -f "$D/mirror.log"
  sleep 2
done
EOF
mbp "cat > /root/m1c-peek.sh" <<'EOF'
#!/bin/sh
# m1c-peek.sh DIR watch|wlan0
case "$2" in
watch) sleep 5; tail -3 "$1/aci_frames.all" 2>/dev/null; tail -2 "$1/aci_events.all" 2>/dev/null
       cat /sys/kernel/debug/ieee80211/phy0/halt_check ;;
wlan0) iw dev wlan0 link | head -1; echo "carrier=$(cat /sys/class/net/wlan0/carrier)" ;;
esac
EOF
mbp "chmod +x /root/m1c-watchdog.sh /root/m1c-mirror.sh /root/m1c-peek.sh; touch $REMOTE/run.log
  systemctl stop airdrop-m1c-watchdog airdrop-m1c-mirror 2>/dev/null
  systemd-run --unit=airdrop-m1c-watchdog --description='airdrop M1c watchdog (reboot after 90 s without Wi-Fi and wire)' /root/m1c-watchdog.sh $REMOTE/watchdog.log
  python3 /root/aci-probe.py enable; echo aci_debug=\$(cat /sys/module/apple_centauri_t6050/parameters/aci_debug)
  systemd-run --unit=airdrop-m1c-mirror --description='airdrop M1c event/crash mirror' /root/m1c-mirror.sh $REMOTE
  sleep 3; systemctl is-active airdrop-m1c-watchdog airdrop-m1c-mirror" 2>&1 | tee -a "$LOG"

step version     python3 aci-probe.py version
step defaults    python3 aci-probe.py defaults awdl
step configure   python3 aci-probe.py configure 02:00:00:00:00:01
step start       python3 aci-probe.py start --full --seq "$SEQ" $EXT --mac 02:00:00:00:00:01
step ifstatus    python3 aci-probe.py ifstatus
step ifconfig    python3 aci-probe.py ifconfig
for i in 1 2 3 4 5 6; do
  step "watch-$i" /root/m1c-peek.sh "$REMOTE" watch
done
step links       python3 aci-probe.py send 1 0x50002
step wlan0       /root/m1c-peek.sh "$REMOTE" wlan0
step stop        python3 aci-probe.py stop
finish
mbp "python3 /root/aci-probe.py disable; systemctl stop airdrop-m1c-mirror airdrop-m1c-watchdog; systemctl is-active airdrop-m1c-watchdog" 2>&1 | tee -a "$LOG"
say "done: frames from interface 1 in $LOCAL/airdrop-m1c-$STAMP/aci_frames.all"
