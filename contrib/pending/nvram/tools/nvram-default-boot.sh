#!/bin/bash
# SPDX-License-Identifier: MIT
# nvram-default-boot.sh: change the DEFAULT startup volume (system:boot-volume) from Linux on the J716s.
#
#   nvram-default-boot.sh status
#   nvram-default-boot.sh set TARGET --test    every check, a backup, the plan and a simulated write + verify on a
#                                              copy; never arms the driver, never writes
#   nvram-default-boot.sh set TARGET [--yes]   the same, then one `asahi-bless --set-boot TARGET --yes` (no --next)
#
#   TARGET: a name or index from `asahi-bless --list-volumes`, or `macos` (the one volume group named Macintosh*)
#   or `omarchy` (the one whose name contains "omarchy", or $OMARCHY_VOLUME).
#
# What the write is (asahi-nvram 3df52c9, apple-nvram/src/v3.rs): the live boot-volume entry's state byte goes
# 0x7f -> 0x7c and a new entry is appended in the free space of the SAME bank; asahi-bless then programs the whole
# 64 KiB active bank in place. No erase, no other bank, same generation. If the update would not fit (bank rotation:
# erase of the next bank and a header-first program of a new generation) this refuses.
#
# Refuses unless: root; nvram-probe.sh marker; the pinned asahi-bless build; AC connected and battery >= $MIN_BATTERY %;
# no write fault logged; read_only=Y; flash ID/status and the partition byte-identical to the probe; no one-time
# target (alt-boot-volume) pending; v3-nvram.py plan-default passes (same bank for asahi-nvram and XNU, unique
# generation, byte-identical re-serialisation, one live boot-volume, in place, bit-clear only); the simulated write
# passes verify-default. Keeps a root-only backup of the partition ($STATE/default-backups, newest $KEEP).
# After the one armed call: read-back must pass verify-default (only boot-volume changed, the model's exact bytes,
# other banks byte-identical) and asahi-bless must report TARGET as both default and next boot. Run it attended.
set -u
SYS=${SYS:-/sys}
STATE=${STATE:-/var/lib/nvram-t6050}
ASAHI_BLESS=${ASAHI_BLESS:-asahi-bless}
EXPECT_BLESS_SHA256=${EXPECT_BLESS_SHA256:-61306393d1c82d2dfee9a1b5de6f1085952e589e6acabaa9625a3a74290d75ce}  # 3df52c9, aarch64
MIN_BATTERY=${MIN_BATTERY:-50}
KEEP=${KEEP:-5}
LOCK=${LOCK:-/run/nvram-t6050.lock}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
QSPI=$SYS/bus/platform/devices/505118000.spi
PARAM=$SYS/module/spi_apple_qspi/parameters/read_only
V3=$HERE/v3-nvram.py

die() { echo "REFUSED: $*" >&2; exit 1; }
cmd=${1:-}; [ $# -gt 0 ] && shift
target='' yes=0 test=0
[ "$cmd" = set ] && { target=${1:-}; [ $# -gt 0 ] && shift; }
while [ $# -gt 0 ]; do
    case $1 in
        --yes) yes=1 ;;
        --test) test=1 ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done
[ -z "${NVRAM_PROBE_NOROOT:-}" ] && [ "$(id -u)" != 0 ] && die "run as root"
[ -r "$STATE/probe.pass" ] || die "no read-only test marker: run nvram-probe.sh first"
mark() { sed -n "s/^$1=//p" "$STATE/probe.pass" | head -n1; }
dev=$(mark dev); dump_sha256=$(mark dump_sha256); flash_status=$(mark flash_status)
[ -n "$dev" ] && [ -n "$dump_sha256" ] && [ -n "$flash_status" ] || die "$STATE/probe.pass is incomplete: rerun nvram-probe.sh"
umask 077
exec 8>"$LOCK" && flock -w 30 8 || die "another NVRAM change is running"
tmp=$(mktemp -d "$STATE/run-XXXXXX")

bless() { "$ASAHI_BLESS" -d "$dev" "$@"; }

power() {  # power ok|report: AC online and battery capacity >= MIN_BATTERY
    local ac=0 bat='' s t
    for s in "$SYS"/class/power_supply/*; do
        [ -e "$s/type" ] || continue
        t=$(cat "$s/type")
        case $t in
            Mains|USB|USB_C|USB_PD) [ "$(cat "$s/online" 2>/dev/null)" = 1 ] && ac=1 ;;
            Battery) [ "$(cat "$s/scope" 2>/dev/null)" = Device ] || bat=$(cat "$s/capacity" 2>/dev/null) ;;
        esac
    done
    if [ "$1" = report ]; then echo "power: AC $([ $ac = 1 ] && echo connected || echo NOT connected), battery ${bat:-unknown} %"; return 0; fi
    [ "$ac" = 1 ] || die "connect the charger first (no online Mains/USB power supply in $SYS/class/power_supply)"
    [ -n "$bat" ] && [ "$bat" -ge "$MIN_BATTERY" ] 2>/dev/null || die "battery ${bat:-unreadable} %: needs at least $MIN_BATTERY % on AC"
}

faults() { dmesg 2>/dev/null | grep -E 'NVRAM (denied|write fault)'; }

pre() {
    local b
    b=$(command -v "$ASAHI_BLESS") || die "asahi-bless not found"
    [ "$(sha256sum "$b" | cut -d' ' -f1)" = "$EXPECT_BLESS_SHA256" ] || die "$b is not the audited asahi-bless build (3df52c9): the plan models that code only"
    power ok
    faults | grep -q 'write fault' && die "the driver logged a write fault this boot: reboot before any NVRAM change"
    [ "$(cat "$PARAM" 2>/dev/null)" = Y ] || die "read_only is not Y before we start"
    [ "$(cat "$QSPI/flash_status" 2>/dev/null)" = "$flash_status" ] || die "flash ID or status changed since the probe"
    dd if="$dev" of="$tmp/before.bin" bs=64k status=none || die "cannot read $dev"
    [ "$(sha256sum "$tmp/before.bin" | cut -d' ' -f1)" = "$dump_sha256" ] || die "the NVRAM changed since the probe (macOS or iBoot wrote it): rerun nvram-probe.sh"
}

pending() { python3 -I "$V3" names "$1" | grep -qx alt-boot-volume; }

resolve() {  # resolve TARGET -> sets tname (system volume name), tidx, cur (current default name)
    local spec=$1 lc n m
    bless --list-volumes > "$tmp/volumes.txt" 2>&1 || die "asahi-bless --list-volumes failed: $(tail -n1 "$tmp/volumes.txt")"
    sed -n 's/^\([* ]\)\([0-9][0-9]*\)) \(.*\)$/\1\t\2\t\3/p' "$tmp/volumes.txt" > "$tmp/vols.tsv"
    [ -s "$tmp/vols.tsv" ] || die "no volumes listed"
    cur=$(awk -F'\t' '$1 == "*" {print $3}' "$tmp/vols.tsv")
    [ "$(awk -F'\t' '$1 == "*"' "$tmp/vols.tsv" | wc -l)" -eq 1 ] || die "asahi-bless does not show exactly one current default"
    lc=$(printf '%s' "$spec" | tr '[:upper:]' '[:lower:]')
    case $lc in
        macos) m=$(awk -F'\t' 'index($3, "Macintosh") == 1' "$tmp/vols.tsv") ;;
        omarchy) if [ -n "${OMARCHY_VOLUME:-}" ]; then m=$(awk -F'\t' -v n="$OMARCHY_VOLUME" '$3 == n' "$tmp/vols.tsv")
                 else m=$(awk -F'\t' 'index(tolower($3), "omarchy")' "$tmp/vols.tsv"); fi ;;
        *[!0-9]*|'') m=$(awk -F'\t' -v n="$lc" 'tolower($3) == n' "$tmp/vols.tsv") ;;
        *) m=$(awk -F'\t' -v n="$lc" '$2 == n' "$tmp/vols.tsv") ;;
    esac
    n=$(printf '%s' "$m" | grep -c .)
    [ "$n" -eq 1 ] || { sed 's/^/  /' "$tmp/volumes.txt" >&2; die "'$spec' matches $n volume groups (needs exactly one; use a name from the list)"; }
    tidx=$(printf '%s' "$m" | cut -f2); tname=$(printf '%s' "$m" | cut -f3)
    [ "$(awk -F'\t' -v n="$tname" 'tolower($3) == tolower(n)' "$tmp/vols.tsv" | wc -l)" -eq 1 ] || die "two volume groups are named '$tname'; asahi-bless would take the first"
    case $tname in *[!0-9]*) ;; *) die "volume name '$tname' is a number; asahi-bless would read it as an index" ;; esac
}

backup() {
    local d; d=$STATE/default-backups/$(date +%Y%m%d-%H%M%S)
    mkdir -p "$d" && chmod 700 "$STATE/default-backups" "$d" || die "cannot create $d"
    cp "$tmp/before.bin" "$d/nvram-before.bin" && sha256sum "$tmp/before.bin" | cut -d' ' -f1 > "$d/nvram-before.sha256" || die "backup failed"
    cp "$tmp/volumes.txt" "$d/volumes.txt"
    { echo "time=$(date -u +%FT%TZ)"; echo "kernel=$(uname -r)"; echo "dev=$dev"; echo "from=$cur"; echo "to=$tname"; echo "test=$test"; } > "$d/info.txt"
    ls -1dt "$STATE"/default-backups/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf --
    bdir=$d
    echo "backup: $d (root only; holds NVRAM values: never copy it off this Mac)"
}

arm_and_run() {  # arm_and_run asahi-bless-args...
    trap 'echo Y > "$PARAM" 2>/dev/null' EXIT INT TERM HUP
    echo N > "$PARAM" || die "driver refused to arm (module not ready, or a write fault is latched)"
    bless "$@"; rc=$?
    echo Y > "$PARAM"
    trap - EXIT INT TERM HUP
    [ "$(cat "$PARAM")" = Y ] || echo "WARNING: read_only is not Y again; reboot before anything else"
    faults | tail -n 5 | sed 's/^/  dmesg: /'
    return $rc
}

recovery() {
    cat <<EOF
RECOVERY (do not run anything else that writes NVRAM; keep $tmp and $bdir):
  1. If Linux still runs: nvram-default-boot.sh status. If the bank still parses and only boot-volume is wrong,
     a later 'set' to the old default ($cur) appends a fresh entry the same way (after a new probe).
  2. Otherwise, at the Mac: shut down, hold the power button until "Loading startup options", select the volume,
     hold Option and click "Always Use" (iBoot writes boot-volume itself). Or boot macOS and use
     System Settings > General > Startup Disk.
  3. If the picker does not appear: Recovery (1TR) is in the same hold-power path (Options); from there Startup Disk.
  4. Last resort: DFU revive from the Studio (Apple Configurator), which rewrites the NOR and NVRAM.
EOF
}

case $cmd in
    status)
        echo "probe: $(mark time) on $(mark kernel)"
        power report
        dd if="$dev" of="$tmp/now.bin" bs=64k status=none || die "cannot read $dev"
        echo "default: $(bless --get-boot 2>&1)"
        echo "next:    $(bless --get-boot --next 2>&1)"
        if pending "$tmp/now.bin"; then echo "one-time target: SET (alt-boot-volume)"; else echo "one-time target: none"; fi
        python3 -I "$V3" plan-default "$tmp/now.bin" | sed 's/^/  plan: /'
        rm -rf "$tmp" ;;
    set)
        [ -n "$target" ] || die "usage: $0 set NAME_OR_INDEX|macos|omarchy [--test] [--yes]"
        pre
        pending "$tmp/before.bin" && die "a one-time boot target (alt-boot-volume) is pending: clear it first (nvram-next-boot.sh clear-next), then probe again"
        resolve "$target"
        echo "default now: $cur"
        echo "new default: $tname (list index $tidx)"
        if [ "$tname" = "$cur" ]; then echo "already the default: nothing to write"; rm -rf "$tmp"; exit 0; fi
        backup
        python3 -I "$V3" plan-default "$tmp/before.bin" > "$tmp/plan.txt"; prc=$?
        sed 's/^/  plan: /' "$tmp/plan.txt"
        [ "$prc" -eq 0 ] && grep -qx 'PLAN OK: in place, bit-clear only, no erase' "$tmp/plan.txt" || die "the plan does not meet the rules (see FAIL above); nothing armed"
        python3 -I "$V3" simulate-default "$tmp/before.bin" "$tmp/sim.bin" >/dev/null || die "simulation failed"
        python3 -I "$V3" verify-default "$tmp/before.bin" "$tmp/sim.bin" > "$tmp/simverify.txt" || { sed 's/^/  sim: /' "$tmp/simverify.txt"; die "the verifier rejects the simulated write"; }
        echo "  sim: a simulated write of this update passes verify-default ($(grep -c '^PASS' "$tmp/simverify.txt") checks)"
        rm -f "$tmp/sim.bin"
        if [ "$test" -eq 1 ]; then
            echo "TEST MODE PASSED: would now arm the driver for: $ASAHI_BLESS -d $dev --set-boot '$tname' --yes"
            echo "nothing was armed or written; $tmp kept (root only)"
            exit 0
        fi
        if [ "$yes" -ne 1 ]; then printf 'Type WRITE to make "%s" the default startup volume: ' "$tname"; read -r a; [ "$a" = WRITE ] || die "not confirmed"; fi
        # the prompt may have waited: everything again, right before arming
        mv "$tmp/before.bin" "$tmp/before0.bin"; pre
        cmp -s "$tmp/before0.bin" "$tmp/before.bin" || die "the NVRAM changed while waiting"
        rm -f "$tmp/before0.bin"
        if ! arm_and_run --set-boot "$tname" --yes; then
            echo "asahi-bless failed (rc $rc). Reading back:"
            dd if="$dev" of="$tmp/after.bin" bs=64k status=none
            if cmp -s "$tmp/before.bin" "$tmp/after.bin"; then echo "nothing was written; the default is unchanged"; exit 1; fi
            python3 -I "$V3" verify-default "$tmp/before.bin" "$tmp/after.bin" | sed 's/^/  /'
            recovery; exit 1
        fi
        dd if="$dev" of="$tmp/after.bin" bs=64k status=none || { echo "cannot read back $dev"; recovery; exit 1; }
        if cmp -s "$tmp/before.bin" "$tmp/after.bin"; then echo "the partition is byte-identical to before: nothing was written"; exit 1; fi
        python3 -I "$V3" verify-default "$tmp/before.bin" "$tmp/after.bin" > "$tmp/verify.txt"; vrc=$?
        sed 's/^/  verify: /' "$tmp/verify.txt"
        cp "$tmp/after.bin" "$bdir/nvram-after.bin"
        now=$(bless --get-boot 2>&1); nxt=$(bless --get-boot --next 2>&1)
        echo "default: $now"; echo "next:    $nxt"
        if [ "$vrc" -ne 0 ] || [ "$now" != "$tname" ] || [ "$nxt" != "$tname" ]; then
            echo "UNEXPECTED RESULT. Do not reboot yet."; recovery; exit 1
        fi
        echo "OK: \"$tname\" is the default startup volume (was \"$cur\"). Reboot attended to confirm." ;;
    *) die "usage: $0 status | set NAME_OR_INDEX|macos|omarchy [--test] [--yes]" ;;
esac
