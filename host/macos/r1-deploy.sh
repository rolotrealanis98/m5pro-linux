#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# r1-deploy.sh - run ON THE MACBOOK in macOS: deploy / check / restore the m1n1 payload on the Linux
# ESP (volume OMARCHY, FAT32) and pull the R1 logs back, with no Mac Studio involved.
#
#   r1-deploy.sh status                       sha256 + friendly name of every m1n1/boot.bin*
#   r1-deploy.sh deploy [--rotate] FILE       FILE must match the SHA256SUMS next to it
#   r1-deploy.sh restore [prev|b2|p3|known-good]
#   r1-deploy.sh logs                         copy OMARCHY:/r1-logs to ~/Work/m5-logs/r1-logs
#
# Run it as yourself (not with sudo): it calls `sudo diskutil mount/unmount` itself.
# Rules: it never deletes anything on the ESP. The only files it ever replaces are
# m1n1/boot.bin (deploy, restore), m1n1/boot.bin.prev (deploy --rotate only) and r1-local.sh.
# boot.bin.prev stays untouched unless --rotate is given, because it must stay a payload that
# is known to boot. It mounts the ESP only if it is not mounted, and unmounts it (after `sync`)
# only if it mounted it. Safe to re-run.
#
# Environment (for tests and odd disk numbering):
#   ESP_DIR   mount point                (default /Volumes/OMARCHY)
#   ESP_DEV   ESP partition              (default disk0s4; checked to carry the label OMARCHY)
#   DRY_RUN=1 print the diskutil/fsck commands instead of running them
#   M5_LOGS   where `logs` copies to     (default ~/Work/m5-logs)
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

DEFAULT_ESP=/Volumes/OMARCHY
ESP_DIR=${ESP_DIR:-$DEFAULT_ESP}
ESP_DEV=${ESP_DEV:-disk0s4}
DRY_RUN=${DRY_RUN:-0}
ESP_FAKE=0; [ "$ESP_DIR" = "$DEFAULT_ESP" ] || ESP_FAKE=1

if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
    HOME_DIR=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
else
    HOME_DIR=$HOME
fi
M5_LOGS=${M5_LOGS:-$HOME_DIR/Work/m5-logs}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

MOUNTED_BY_US=0
W=""            # "sudo" when the mounted ESP is not writable by this user

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
usage:
  r1-deploy.sh status
  r1-deploy.sh deploy [--rotate] PAYLOAD_FILE
  r1-deploy.sh restore [prev|b2|p3|known-good]
  r1-deploy.sh logs
deploy: PAYLOAD_FILE must be listed in the SHA256SUMS file in its folder and match it.
        --rotate copies boot.bin to boot.bin.prev first (only do this when the current
        boot.bin is a payload that booted). Without it boot.bin.prev is left alone.
        Also copies r1-local.sh to the ESP root so Linux can run `bash /boot/r1-local.sh a`.
USAGE
}

# ---------------------------------------------------------------------------- hashes and names
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

name_of() {
    case "$1" in
        55d95928d4435b0e10e797f6d71cf7ebc65e7a76d7c788a5db865a405020ade2) echo "B2" ;;
        fccf71bcad938f34312e89b9f8c46e4431f78536d742f98c884d5eeca57f9806) echo "P3" ;;
        a2407e836c05d38acd756c74f8d8bdf37b9c3a197ebb9c776b884140793f563c) echo "known-good" ;;
        6d6a402b4192c0bd09e28fd87bfe55880a9a2338cace52b9e36398ce9970bf49) echo "R1-A" ;;
        c4edcb33058b44f0f89168b8e507afa338edc580559c872fe7141f2fe19bea8a) echo "R1-B" ;;
        019cf5f17a2e347ae4a3add9e476a6fb35799e8f8244ba5ea0ec455c2d21c244) echo "R1-C" ;;
        66c917bf4c85aeec05b4c7801c958a6678d83ac9455beaf0c875058edaf1a839) echo "old-1cpu (prev2)" ;;
        fcc402401b33325cac937037deb050660756a4d615182470b7dde3afad001a0d) echo "trackpad-first (no SSH)" ;;
        923f506a*) echo "B1" ;;
        *) echo "unknown" ;;
    esac
}

# ---------------------------------------------------------------------------- privileged helpers
# priv CMD...: run a privileged system command (or only print it when DRY_RUN=1).
priv() {
    if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] would run: sudo %s\n' "$*"; return 0; fi
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}
# wr CMD...: a file operation on the mounted ESP (sudo only if the mount is not user-writable).
wr() { if [ -n "$W" ]; then sudo "$@"; else "$@"; fi; }
cpf() { wr cp -X "$1" "$2" 2>/dev/null || wr cp "$1" "$2"; }

# ---------------------------------------------------------------------------- mount handling
is_mounted() {
    if [ "$ESP_FAKE" = 1 ]; then
        # A test directory: "mounted" when it exists, except that DRY_RUN pretends to mount it so
        # the diskutil commands get printed.
        [ "$DRY_RUN" != 1 ] && [ -d "$ESP_DIR" ]
        return
    fi
    mount | grep -qF " on $ESP_DIR ("
}

mount_esp() {
    if is_mounted; then
        say "ESP already mounted at $ESP_DIR (this script will leave it mounted)"
    else
        [ "$ESP_FAKE" = 1 ] && [ "$DRY_RUN" != 1 ] && die "test ESP_DIR $ESP_DIR does not exist"
        if [ "$DRY_RUN" != 1 ]; then
            label=$(diskutil info "$ESP_DEV" 2>/dev/null | sed -n 's/^ *Volume Name: *//p' | head -1)
            [ "$label" = OMARCHY ] || die "/dev/$ESP_DEV has volume name '${label:-?}', not OMARCHY. Run 'diskutil list', then re-run with ESP_DEV=diskXsN."
        fi
        say "mounting /dev/$ESP_DEV"
        if ! priv diskutil mount "$ESP_DEV"; then
            say "mount failed (dirty FAT?): running fsck_msdos -y on /dev/$ESP_DEV, then retrying once"
            priv fsck_msdos -y "/dev/$ESP_DEV" || true
            priv diskutil mount "$ESP_DEV" || die "could not mount /dev/$ESP_DEV"
        fi
        MOUNTED_BY_US=1
    fi
    [ -d "$ESP_DIR/m1n1" ] || die "$ESP_DIR/m1n1 not found: this does not look like the OMARCHY ESP"
    if [ ! -w "$ESP_DIR/m1n1" ] && [ "$(id -u)" != 0 ]; then W=sudo; fi
}

cleanup() {
    rc=$?
    if [ "$MOUNTED_BY_US" = 1 ]; then
        wr sync 2>/dev/null || sync || true
        if priv diskutil unmount "$ESP_DEV"; then
            say "unmounted $ESP_DEV (this script had mounted it)"
        else
            say "WARNING: could not unmount. Eject by hand: sudo diskutil unmount $ESP_DEV"
        fi
    fi
    exit $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------------------- common steps
# put_boot SRC LABEL: copy SRC to boot.bin.new, verify, move over boot.bin, sync, re-verify.
# Skips everything if boot.bin already has SRC's hash.
put_boot() {
    src=$1; label=$2
    want=$(sha "$src")
    bb=$ESP_DIR/m1n1/boot.bin; nw=$ESP_DIR/m1n1/boot.bin.new
    if [ -f "$bb" ] && [ "$(sha "$bb")" = "$want" ]; then
        say "boot.bin already is $label ($want): nothing to copy"
        return 0
    fi
    say "copy $label -> m1n1/boot.bin.new"
    cpf "$src" "$nw"; wr sync
    got=$(sha "$nw")
    [ "$got" = "$want" ] || die "boot.bin.new hash $got != $want. boot.bin NOT touched. Re-run, or try another cable-free copy (cp again)."
    say "verified boot.bin.new = $want"
    say "mv boot.bin.new -> boot.bin"
    wr mv -f "$nw" "$bb"; wr sync
    got=$(sha "$bb")
    [ "$got" = "$want" ] || die "boot.bin hash $got != $want after the move. Run: r1-deploy.sh restore"
    say "verified boot.bin = $want ($label)"
}

# ---------------------------------------------------------------------------- subcommands
cmd_status() {
    mount_esp
    say "ESP $ESP_DIR/m1n1:"
    n=0
    for f in "$ESP_DIR"/m1n1/boot.bin*; do
        [ -f "$f" ] || continue
        h=$(sha "$f"); n=$((n + 1))
        mark=""; [ "$(basename "$f")" = boot.bin ] && mark="   <== boots next"
        printf '  %-24s %-24s %s%s\n' "$(basename "$f")" "$(name_of "$h")" "$h" "$mark"
    done
    [ "$n" -gt 0 ] || say "  (no boot.bin* files found)"
    if [ -f "$ESP_DIR/r1-local.sh" ]; then
        say "r1-local.sh on the ESP: $(sha "$ESP_DIR/r1-local.sh")"
    else
        say "r1-local.sh on the ESP: missing (deploy copies it)"
    fi
    if [ -d "$ESP_DIR/r1-logs" ]; then
        say "r1-logs on the ESP: $(find "$ESP_DIR/r1-logs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') run folder(s)"
    else
        say "r1-logs on the ESP: none yet"
    fi
}

cmd_deploy() {
    rotate=0; payload=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --rotate) rotate=1; shift ;;
            -*) die "unknown option: $1" ;;
            *) [ -z "$payload" ] || die "only one payload file"; payload=$1; shift ;;
        esac
    done
    [ -n "$payload" ] || { usage >&2; exit 2; }
    [ -f "$payload" ] || die "no such file: $payload"
    base=$(basename "$payload"); pdir=$(cd "$(dirname "$payload")" && pwd)
    sums=$pdir/SHA256SUMS
    [ -f "$sums" ] || die "no SHA256SUMS next to $payload"
    expect=$(awk -v n="$base" '{f=$2; sub(/^\*/, "", f); if (f == n) { print $1; exit }}' "$sums")
    [ -n "$expect" ] || die "$base is not listed in $sums. Refusing."
    have=$(sha "$payload")
    [ "$have" = "$expect" ] || die "sha256 mismatch for $base: file $have, SHA256SUMS $expect. Refusing. Copy it from iCloud Drive again."
    label=$(name_of "$have"); [ "$label" != unknown ] || label=$base
    say "payload $base verified against SHA256SUMS: $have ($label)"

    mount_esp
    bb=$ESP_DIR/m1n1/boot.bin; pv=$ESP_DIR/m1n1/boot.bin.prev
    curh=""; [ -f "$bb" ] && curh=$(sha "$bb")
    [ -z "$curh" ] || say "current boot.bin: $curh ($(name_of "$curh"))"
    prevh=""; [ -f "$pv" ] && prevh=$(sha "$pv")
    [ -z "$prevh" ] || say "current boot.bin.prev: $prevh ($(name_of "$prevh"))"

    if [ "$rotate" = 1 ]; then
        if [ -z "$curh" ]; then
            say "--rotate: there is no boot.bin to rotate"
        elif [ "$curh" = "$have" ]; then
            say "--rotate: boot.bin already is the payload; boot.bin.prev stays $(name_of "$prevh")"
        else
            say "--rotate: copy boot.bin ($(name_of "$curh")) -> boot.bin.prev"
            cpf "$bb" "$pv.new"; wr sync
            [ "$(sha "$pv.new")" = "$curh" ] || die "boot.bin.prev.new hash mismatch; boot.bin.prev NOT replaced"
            wr mv -f "$pv.new" "$pv"; wr sync
            [ "$(sha "$pv")" = "$curh" ] || die "boot.bin.prev hash mismatch after the move"
            say "verified boot.bin.prev = $curh ($(name_of "$curh"))"
        fi
    else
        say "no --rotate: boot.bin.prev left untouched (${prevh:-absent}${prevh:+ = $(name_of "$prevh")})"
    fi

    put_boot "$payload" "$label"

    lsrc=""
    for c in "$SCRIPT_DIR/r1-local.sh" "$pdir/r1-local.sh"; do [ -f "$c" ] && { lsrc=$c; break; }; done
    if [ -n "$lsrc" ]; then
        lh=$(sha "$lsrc")
        if [ -f "$ESP_DIR/r1-local.sh" ] && [ "$(sha "$ESP_DIR/r1-local.sh")" = "$lh" ]; then
            say "r1-local.sh on the ESP is already current ($lh)"
        else
            say "copy r1-local.sh -> $ESP_DIR/r1-local.sh"
            cpf "$lsrc" "$ESP_DIR/r1-local.sh"; wr sync
            [ "$(sha "$ESP_DIR/r1-local.sh")" = "$lh" ] || die "r1-local.sh copy hash mismatch"
            say "verified r1-local.sh = $lh"
        fi
    else
        say "WARNING: r1-local.sh not found next to this script or the payload; Linux will have no test script. Put it beside r1-deploy.sh and re-run."
    fi

    wr sync
    say "DONE: boot.bin = $label. Next: set Startup Disk (or power-hold menu) to the Omarchy stub and reboot."
}

cmd_restore() {
    which=${1:-prev}
    case "$which" in
        prev) f=boot.bin.prev ;;
        b2) f=boot.bin.b2 ;;
        p3) f=boot.bin.p3 ;;
        known-good) f=boot.bin.known-good ;;
        *) die "unknown name '$which' (prev, b2, p3, known-good)" ;;
    esac
    mount_esp
    src=$ESP_DIR/m1n1/$f
    [ -f "$src" ] || die "$src does not exist on the ESP. Run: r1-deploy.sh status"
    h=$(sha "$src")
    say "restoring from $f = $h ($(name_of "$h"))"
    put_boot "$src" "$(name_of "$h") (from $f)"
    say "DONE: boot.bin = $(name_of "$h"). Source file $f was not changed."
}

cmd_logs() {
    mount_esp
    src=$ESP_DIR/r1-logs
    if [ ! -d "$src" ]; then
        say "no r1-logs folder on the ESP yet: nothing to copy"
        return 0
    fi
    mkdir -p "$M5_LOGS"
    say "copy $src -> $M5_LOGS/r1-logs"
    cp -R -X "$src" "$M5_LOGS/" 2>/dev/null || cp -R "$src" "$M5_LOGS/"
    nsrc=$(find "$src" -type f | wc -l | tr -d ' ')
    ndst=$(find "$M5_LOGS/r1-logs" -type f | wc -l | tr -d ' ')
    say "files on the ESP: $nsrc, files in $M5_LOGS/r1-logs: $ndst"
    [ "$ndst" -ge "$nsrc" ] || die "fewer files arrived than exist on the ESP"
    say "run folders now in $M5_LOGS/r1-logs:"
    find "$M5_LOGS/r1-logs" -mindepth 1 -maxdepth 1 | sort | sed 's|^.*/|  |'
}

# ---------------------------------------------------------------------------- main
sub=${1:-}
[ $# -gt 0 ] && shift
case "$sub" in
    status) cmd_status ;;
    deploy) cmd_deploy "$@" ;;
    restore) cmd_restore "$@" ;;
    logs) cmd_logs ;;
    -h|--help|help|"") usage; [ -n "$sub" ] || exit 2 ;;
    *) usage >&2; exit 2 ;;
esac
