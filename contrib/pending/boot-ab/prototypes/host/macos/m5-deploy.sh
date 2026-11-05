#!/bin/bash
# SPDX-License-Identifier: MIT
# m5-deploy.sh - put a stage-2 payload (m1n1 + kernel + DTB + initramfs) on the M5's ESP, reboot
# into it, verify it, and roll back on its own when it does not come back.
#
# PLANNING PROTOTYPE 2026-11-05, UNTESTED, never run against the Mac.
#
#   host/macos/m5-deploy.sh PAYLOAD.bin [--expect KREL] [--check 'CMD'] [--timeout SECS]
#                                       [--no-rotate] [--keep-failed] [--dry-run]
#
# Flow (FRICTION.md P4):
#   1. hash, size and kernel-release of PAYLOAD (the release string is read out of the gzip'd
#      Image inside it, so the post-boot check needs no manual input)
#   2. over the eem-vm bridge: refuse unless the M5 runs a known payload; upload to
#      /boot/m1n1/boot.bin.new, re-hash on the M5, rotate boot.bin -> boot.bin.prev (only when
#      the running boot came from the primary slot, so boot.bin.prev stays a payload that has
#      booted), rename .new -> boot.bin, sync, log to /boot/m1n1/DEPLOY.log
#   3. clean `systemctl reboot` (macsmc-reboot writes boot_stage = 0: not a failed boot)
#   4. wait for SSH; verify uname -r, chosen/m5pro,boot-slot == primary, nproc, --check
#   5. no SSH in SECS: if the m1n1 proxy enumerated (stage-2 fell back), save its console
#      replay; then `macvdmtool reboot`. The hard reset leaves boot_stage != 0, iBoot counts a
#      boot error, and stage-1 (m1n1 patch 0016) boots chainload.fallback = boot.bin.prev.
#   6. back on the fallback slot: collect evidence (pstore, journal of the failed boot if any,
#      the netconsole log), demote boot.bin -> boot.bin.failed-<ts>, copy boot.bin.prev ->
#      boot.bin, exit 1. m1n1/TRIAL marks the payload as on trial until step 4 passes (the
#      root's m5-boot-slot.service uses it to demote on its own when no Studio is attached).
#      Still nothing: exit 3 and print what Rolando has to do.
#
# Needs: ~/Work/eem-vm/eem-vm.py (with --put), passwordless `sudo macvdmtool reboot`
# (sudoers-m5pro), host/macos/m5.sh for the m1n1 console capture. Auto-rollback after a hang
# needs the A/B stage-1 (detected from /proc/device-tree/chosen/m5pro,boot-slot); without it
# the script stops at step 5 and asks for the manual macOS-side copy.
set -uo pipefail

EEM=${EEM_VM:-$HOME/Work/eem-vm/eem-vm.py}
M5SH=${M5SH:-$(cd "$(dirname "$0")" && pwd)/m5.sh}
VDM=${MACVDMTOOL:-$HOME/Work/macvdmtool/macvdmtool}
NETCON_LOG=${NETCON_LOG:-$HOME/Work/m5-logs/netconsole.log}
D=/boot/m1n1
TIMEOUT=300; EXPECT=""; CHECK=""; ROTATE=1; KEEP_FAILED=0; DRY=0

PAYLOAD=${1:-}; shift || true
while [ $# -gt 0 ]; do case "$1" in
    --expect) EXPECT=$2; shift 2 ;;
    --check) CHECK=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --no-rotate) ROTATE=0; shift ;;
    --keep-failed) KEEP_FAILED=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac; done
[ -f "$PAYLOAD" ] || { echo "usage: $0 PAYLOAD.bin [options]" >&2; exit 2; }

TS=$(date +%Y%m%d-%H%M%S); OUT=$HOME/Work/m5-logs/deploy-$TS; mkdir -p "$OUT"
log() { echo "[deploy $(date +%T)] $*" | tee -a "$OUT/deploy.log" >&2; }
m5() { "$EEM" --keep -q "$1"; }                      # run on the M5 as root; rc 2 = unreachable
m5_up() { "$EEM" --keep -q 'true' >/dev/null 2>&1; }
run() { if [ $DRY = 1 ]; then log "DRY: $1"; else m5 "$1"; fi; }

# 1. local checks ------------------------------------------------------------------------------
SHA=$(shasum -a 256 "$PAYLOAD" | cut -d' ' -f1); SIZE=$(stat -f %z "$PAYLOAD")
[ "$SIZE" -gt 4000000 ] && [ "$SIZE" -lt 200000000 ] || { log "implausible size $SIZE"; exit 2; }
KREL=$(python3 -I - "$PAYLOAD" <<'PY'
import re, sys, zlib
b = open(sys.argv[1], "rb").read()
for m in re.finditer(rb"\x1f\x8b\x08", b):
    try:
        d = zlib.decompressobj(31).decompress(b[m.start():], 64 << 20)
    except zlib.error:
        continue
    if d[0x38:0x3c] == b"ARMd":                      # arm64 Image header magic
        v = re.search(rb"Linux version (\S+)", d)
        print(v.group(1).decode() if v else ""); break
PY
)
EXPECT=${EXPECT:-$KREL}
log "payload $PAYLOAD: $SIZE bytes, sha256 ${SHA:0:16}..., kernel ${KREL:-unknown}"
[ -n "$EXPECT" ] || log "WARNING: no kernel release found; only the slot and SSH will be checked"

# 2. upload and rotate ---------------------------------------------------------------------------
m5_up || { log "M5 not reachable over the bridge; nothing changed"; exit 2; }
STATE=$(m5 "cat /proc/device-tree/chosen/m5pro,boot-slot 2>/dev/null | tr -d '\0'; echo; uname -r; \
  mountpoint -q /boot || ls /boot/m1n1 >/dev/null; df -k /boot | awk 'NR==2{print \$4}'; \
  [ -s $D/TRIAL ] && echo trial-pending || echo no-trial; \
  sha256sum $D/boot.bin $D/boot.bin.prev 2>/dev/null | cut -c1-16")
SLOT=$(sed -n 1p <<<"$STATE"); FREE=$(sed -n 3p <<<"$STATE"); TRIAL=$(sed -n 4p <<<"$STATE")
log "M5 now: slot=${SLOT:-no-AB-stage1} kernel=$(sed -n 2p <<<"$STATE") esp-free=${FREE}K"
AB=1; [ -z "$SLOT" ] && AB=0
[ "${FREE:-0}" -gt $(( SIZE / 1024 * 2 + 1024 )) ] || { log "ESP too full for .new + rotation"; exit 2; }
if [ $DRY = 0 ]; then
    "$EEM" --keep -q --put "$PAYLOAD" "$D/boot.bin.new" || { log "upload failed"; exit 2; }
fi
REMOTE=$(run "sha256sum $D/boot.bin.new | cut -d' ' -f1")
[ $DRY = 1 ] || [ "$REMOTE" = "$SHA" ] || { log "hash mismatch on the M5 ($REMOTE)"; run "rm -f $D/boot.bin.new"; exit 2; }
if [ "$TRIAL" = trial-pending ]; then
    log "boot.bin is still on trial (never confirmed): not rotating it into boot.bin.prev"
elif [ $ROTATE = 1 ] && { [ "${SLOT%%-*}" = primary ] || [ $AB = 0 ]; }; then
    # the running boot came from boot.bin, so boot.bin is a payload that boots: keep it as prev
    run "cp $D/boot.bin $D/boot.bin.prev.tmp && sync && mv $D/boot.bin.prev.tmp $D/boot.bin.prev"
else
    log "running from the fallback slot (or --no-rotate): boot.bin.prev left as is"
fi
run "mv $D/boot.bin.new $D/boot.bin && echo $SHA > $D/TRIAL && sync && echo '$TS ${SHA:0:16} ${KREL:-?} deployed' >> $D/DEPLOY.log && sync"

# 3. reboot ------------------------------------------------------------------------------------
log "clean reboot"
run "systemctl reboot" >/dev/null 2>&1
[ $DRY = 1 ] && { log "dry run ends here"; exit 0; }
t0=$(date +%s); while m5_up && [ $(( $(date +%s) - t0 )) -lt 90 ]; do sleep 3; done

# 4. wait and verify ---------------------------------------------------------------------------
wait_ssh() { local t0; t0=$(date +%s); while [ $(( $(date +%s) - t0 )) -lt "$1" ]; do m5_up && return 0; sleep 5; done; return 1; }
verify() {
    local s; s=$(m5 "cat /proc/device-tree/chosen/m5pro,boot-slot 2>/dev/null | tr -d '\0'; echo; uname -r; nproc")
    SLOT=$(sed -n 1p <<<"$s"); NOW_K=$(sed -n 2p <<<"$s"); NCPU=$(sed -n 3p <<<"$s")
    log "back: slot=${SLOT:-?} kernel=$NOW_K cpus=$NCPU"
}
collect() {   # evidence of the failed boot, wherever it survived
    m5 "ls -la /sys/fs/pstore; for f in /sys/fs/pstore/*; do echo \"== \$f\"; cat \"\$f\"; done" > "$OUT/pstore.txt" 2>&1
    m5 "journalctl -b -1 -o short-monotonic --no-pager 2>/dev/null | tail -300" > "$OUT/journal-prev.txt" 2>&1
    m5 "dmesg" > "$OUT/dmesg-now.txt" 2>&1
    [ -f "$NETCON_LOG" ] && awk -v ts="$TS" '$0 >= ts' "$NETCON_LOG" > "$OUT/netconsole.txt" 2>/dev/null
    log "evidence in $OUT"
}
demote() {
    local keep="mv $D/boot.bin $D/boot.bin.failed-$TS"; [ $KEEP_FAILED = 1 ] || keep="rm -f $D/boot.bin"
    m5 "$keep && cp $D/boot.bin.prev $D/boot.bin && rm -f $D/TRIAL && sync && echo '$TS ${SHA:0:16} rolled back' >> $D/DEPLOY.log && sync"
    log "rolled back: boot.bin = boot.bin.prev"
}

if wait_ssh "$TIMEOUT"; then
    verify
    if [ "${SLOT#fallback}" != "$SLOT" ]; then
        log "FAIL: stage-1 booted the fallback slot, so the new payload's boot did not end cleanly"
        collect; demote; exit 1
    fi
    if [ -n "$EXPECT" ] && [ "$NOW_K" != "$EXPECT" ]; then
        log "FAIL: running $NOW_K, expected $EXPECT"; collect; exit 1
    fi
    [ "$NCPU" = 18 ] || log "WARNING: $NCPU CPUs (expected 18)"
    if [ -n "$CHECK" ]; then
        m5 "$CHECK" > "$OUT/check.txt" 2>&1 || { log "FAIL: --check failed (see check.txt)"; collect; exit 1; }
    fi
    m5 "dmesg" > "$OUT/dmesg.txt" 2>&1
    m5 "rm -f $D/TRIAL && sync"
    log "PASS: ${KREL:-payload} up on the primary slot"; exit 0
fi

# 5. no SSH: stage-2 proxy? hung kernel? ------------------------------------------------------
log "no SSH after ${TIMEOUT}s"
if ioreg -p IOUSB -l -w0 2>/dev/null | grep -q '"idProduct" = 12653'; then
    log "the m1n1 proxy is on USB: stage-2 did not boot a kernel; saving its console replay"
    "$M5SH" log 20 > "$OUT/m1n1-console.txt" 2>&1 || true
fi
if [ $AB = 0 ]; then
    log "this stage-1 has no A/B fallback. Rolando: boot macOS, 'sudo diskutil mount' the OMARCHY"
    log "partition, cp m1n1/boot.bin.prev m1n1/boot.bin, eject, boot the stub."; exit 3
fi
log "hard reset via macvdmtool (iBoot will count a boot error; stage-1 then boots boot.bin.prev)"
sudo -n "$VDM" reboot >> "$OUT/deploy.log" 2>&1 || log "macvdmtool reboot failed (cable? sudoers?)"
if wait_ssh "$TIMEOUT"; then
    verify
    if [ "${SLOT#fallback}" != "$SLOT" ]; then collect; demote; exit 1; fi
    log "back, but not on the fallback slot (slot=$SLOT): inspect by hand"; collect; exit 1
fi
log "still no SSH. Rolando: photograph the panel, then hold power, boot macOS and restore"
log "m1n1/boot.bin.prev on the OMARCHY partition (docs/boot-and-recovery.md, Recovery)."
exit 3
