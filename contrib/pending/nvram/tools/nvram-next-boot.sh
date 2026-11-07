#!/bin/bash
# SPDX-License-Identifier: MIT
# nvram-next-boot.sh: set or clear the one-shot ("next boot only") boot target from Linux on the J716s.
#
#   nvram-next-boot.sh status
#   nvram-next-boot.sh to-macos [--volume NAME_OR_INDEX] [--yes]   write alt-boot-volume = macOS, once
#   nvram-next-boot.sh clear-next [--yes]                          remove alt-boot-volume
#
# Only alt-boot-volume (system partition) is ever written; boot-volume, the policies and every other variable
# are not touched. Refuses to do anything unless:
#   - nvram-probe.sh passed on this boot or an earlier one ($STATE/probe.pass),
#   - the partition still has exactly the contents it had at the probe (otherwise: rerun the probe),
#   - the flash ID and status are what the probe saw, and the driver is still read-only.
# It then clears spi_apple_qspi's read_only parameter for the one asahi-bless call, sets it back at once
# (also on error or interrupt), reads the partition again and requires that the only change is the one
# variable, as a bit-clearing program inside the active bank. Run it attended, with the Mac in reach.
set -u
SYS=${SYS:-/sys}
STATE=${STATE:-/var/lib/nvram-t6050}
ASAHI_BLESS=${ASAHI_BLESS:-asahi-bless}
HERE=$(cd "$(dirname "$0")" && pwd)
QSPI=$SYS/bus/platform/devices/505118000.spi
PARAM=$SYS/module/spi_apple_qspi/parameters/read_only
V3=$HERE/v3-nvram.py

die() { echo "REFUSED: $*" >&2; exit 1; }
cmd=${1:-}; [ $# -gt 0 ] && shift
yes=0 vol=
while [ $# -gt 0 ]; do
    case $1 in
        --yes) yes=1 ;;
        --volume) vol=${2:?--volume NAME_OR_INDEX}; shift ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done
[ -z "${NVRAM_PROBE_NOROOT:-}" ] && [ "$(id -u)" != 0 ] && die "run as root"
[ -r "$STATE/probe.pass" ] || die "no read-only test marker: run nvram-probe.sh first"
mark() { sed -n "s/^$1=//p" "$STATE/probe.pass" | head -n1; }
dev=$(mark dev); dump_sha256=$(mark dump_sha256); flash_status=$(mark flash_status)
[ -n "$dev" ] && [ -n "$dump_sha256" ] && [ -n "$flash_status" ] || die "$STATE/probe.pass is incomplete: rerun nvram-probe.sh"
tmp=$(mktemp -d "$STATE/run-XXXXXX")

pre() {
    [ "$(cat "$PARAM" 2>/dev/null)" = Y ] || die "read_only is not Y before we start"
    [ "$(cat "$QSPI/flash_status" 2>/dev/null)" = "$flash_status" ] || die "flash ID or status changed since the probe"
    dd if="$dev" of="$tmp/before.bin" bs=64k status=none || die "cannot read $dev"
    [ "$(sha256sum "$tmp/before.bin" | cut -d' ' -f1)" = "$dump_sha256" ] || die "the NVRAM changed since the probe (macOS or iBoot wrote it): rerun nvram-probe.sh"
}

report() { "$ASAHI_BLESS" -d "$dev" --get-boot | sed 's/^/  default: /'; "$ASAHI_BLESS" -d "$dev" --get-boot --next | sed 's/^/  next:    /'; }

arm_and_run() {  # arm_and_run asahi-bless-args...
    trap 'echo Y > "$PARAM" 2>/dev/null' EXIT INT TERM HUP
    echo N > "$PARAM" || die "driver refused to arm (module not ready, or a write fault is latched)"
    "$ASAHI_BLESS" -d "$dev" "$@"; rc=$?
    echo Y > "$PARAM"
    trap - EXIT INT TERM HUP
    [ "$(cat "$PARAM")" = Y ] || { echo "WARNING: read_only is not Y again; reboot before anything else"; }
    dmesg 2>/dev/null | grep -E 'NVRAM (denied|write fault)' | tail -n 5 | sed 's/^/  dmesg: /'
    return $rc
}

verify() {  # verify EXPECTED_LINE
    dd if="$dev" of="$tmp/after.bin" bs=64k status=none || die "cannot read back $dev"
    if cmp -s "$tmp/before.bin" "$tmp/after.bin"; then echo "  the partition is byte-identical to before: nothing was written"; return 1; fi
    python3 -I "$V3" compare "$tmp/before.bin" "$tmp/after.bin" | tee "$tmp/compare.txt" | sed 's/^/  /'
    if grep -q "^  $1\$" "$tmp/compare.txt" && [ "$(grep -c -E '^  (added|removed|changed) ' "$tmp/compare.txt")" -eq 1 ] \
        && grep -q 'bit-clear only True' "$tmp/compare.txt" && grep -q 'banks whose bytes changed: \[[0-9]*\]$' "$tmp/compare.txt"; then
        return 0
    fi
    echo "UNEXPECTED CHANGE (see above). Do not reboot into anything. Keep $tmp and the probe dumps."
    return 1
}

confirm() {
    [ "$yes" -eq 1 ] && return 0
    printf 'Type WRITE to program the NVRAM: '; read -r a; [ "$a" = WRITE ] || die "not confirmed"
}

case $cmd in
    status)
        echo "probe: $(mark time) on $(mark kernel) (jedec $(mark jedec))"
        dd if="$dev" of="$tmp/now.bin" bs=64k status=none || die "cannot read $dev"
        if python3 -I "$V3" names "$tmp/now.bin" | grep -q '^alt-boot-volume$'; then echo "alt-boot-volume is SET"; else echo "alt-boot-volume is not set"; fi
        report ;;
    to-macos)
        pre
        python3 -I "$V3" plan "$tmp/before.bin" "$(printf 'X%.0s' $(seq 110))" | tee "$tmp/plan.txt" | sed 's/^/  plan: /'
        if ! grep -q 'in place' "$tmp/plan.txt" || ! grep -q 'bit-clear only (no erase needed): True' "$tmp/plan.txt"; then
            die "the update would not be a plain in-place program; review by hand"
        fi
        echo "before:"; report
        "$ASAHI_BLESS" -d "$dev" --list-volumes | sed 's/^/  /'
        confirm
        if [ -n "$vol" ]; then arm_and_run --set-boot "$vol" --next --yes; else arm_and_run --set-boot-macos --next --yes; fi || { echo "asahi-bless failed (rc $?). Reading back to see what, if anything, changed:"; verify "added   system:alt-boot-volume" || exit 1; exit 1; }
        verify "added   system:alt-boot-volume" || exit 1
        echo "after:"; report
        echo "OK: the next boot goes to macOS once; boot-volume is unchanged. Reboot when attended." ;;
    clear-next)
        pre
        confirm
        arm_and_run --clear-next || { echo "asahi-bless failed (rc $?)"; exit 1; }
        verify "removed system:alt-boot-volume" || exit 1
        report; echo "OK: alt-boot-volume cleared." ;;
    *) die "usage: $0 status | to-macos [--volume NAME_OR_INDEX] [--yes] | clear-next [--yes]" ;;
esac
