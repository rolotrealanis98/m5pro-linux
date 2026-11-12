#!/bin/bash
# SPDX-License-Identifier: MIT
# Run ON THE M5, booted into macOS, after a macOS update: bring the Omarchy stub's OS loader
# (iBoot/mBoot stage 2, "OS FW version" in m1n1) up to the macOS that is now installed.
#
# Why: the stub boots m1n1 with the stage-2 mBoot from its own Preboot restore bundle, which
# prep-stub.sh cloned from the host macOS at install time. A macOS update replaces LLB
# (/chosen/system-firmware-version) but not that bundle (/chosen/firmware-version), so the
# 27.3 beta 1 "single core from a custom raw boot object" fix never reaches a 27.2 stub.
#
#   sudo host/macos/refresh-stub-firmware.sh check              versions only, changes nothing
#   sudo host/macos/refresh-stub-firmware.sh refresh [--m1n1 F]  move the old restore bundle aside,
#                                                               re-run prep-stub.sh (resume mode:
#                                                               no resize, no new partitions), then
#                                                               finish-install.sh; then do the
#                                                               power-hold -> Omarchy -> step2 ceremony
#   sudo host/macos/refresh-stub-firmware.sh recreate --yes [--m1n1 F]
#       when `refresh` fails at bless with bootpolicy error 11 "AP boot mode": the SEP only lets a
#       LocalPolicy that already exists (ours is Permissive, custom boot object) be rewritten from
#       1TR, and a new restore bundle needs a new policy. Backs up the old bundle, boot dir and
#       boot.bin to ~/Work/stub-backup-<build>, deletes the four stub volumes (new VGID, no old
#       policy), re-runs prep-stub.sh + finish-install.sh. The container (disk0s3), the EFI
#       partition, the Linux root and macOS are not touched. Then the usual 1TR ceremony.
# Needs the omarchy-m5 checkout (branch j716s) at $OMARCHY_M5 (default ~/Work/omarchy-m5).
# --m1n1 defaults to the boot.bin already on the stub (the installed stage-1), so the ceremony
# re-registers the same image.
set -euo pipefail
OM=${OMARCHY_M5:-$HOME/Work/omarchy-m5}
STUB_NAME=${STUB_NAME:-Omarchy}
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"

vol_by_role() {   # vol_by_role <System-volume-name> <Role>
    diskutil apfs list -plist | python3 -c '
import plistlib, sys
name, role = sys.argv[1], sys.argv[2]
d = plistlib.loads(sys.stdin.buffer.read())
for c in d["Containers"]:
    vols = c.get("Volumes", [])
    if not any("System" in v.get("Roles", []) and v.get("Name") == name for v in vols): continue
    for v in vols:
        if role in v.get("Roles", []): print(v["DeviceIdentifier"])
' "$1" "$2"
}
mnt() { local m; m=$(diskutil info "$1" | awk -F': *' '/Mount Point/{print $2}'); [ -n "$m" ] && [ "$m" != "Not mounted" ] || { diskutil mount "$1" >/dev/null; m=$(diskutil info "$1" | awk -F': *' '/Mount Point/{print $2}'); }; echo "$m"; }
build_of() { plutil -extract ProductBuildVersion raw -o - "$1" 2>/dev/null || echo "?"; }

rebuild_from_container() {   # rebuild_from_container <containerRef> <m1n1 file>: the second half of recreate
    local CT=$1 M1N1=$2 STUB_PART STUB_BYTES VOLS v
    STUB_PART=$(diskutil apfs list "$CT" -plist | python3 -c '
import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(d["Containers"][0]["PhysicalStores"][0]["DeviceIdentifier"])')
    STUB_BYTES=$(diskutil info "$STUB_PART" | sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -1)
    VOLS=$(diskutil apfs list "$CT" -plist | python3 -c '
import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(" ".join(v["DeviceIdentifier"] + "=" + str(v.get("Name")) for v in d["Containers"][0]["Volumes"]))')
    echo; echo "stub container:    $CT on $STUB_PART ($STUB_BYTES bytes), volumes left: ${VOLS:-none}"
    case "$STUB_PART" in disk0s1|disk0s6) die "refusing: $STUB_PART is the iSC or the Recovery container" ;; esac
    [ "$(diskutil info "$STUB_PART" | awk -F': *' '/Partition Type/{print $2}')" = Apple_APFS ] || die "refusing: $STUB_PART is not Apple_APFS"
    [ "$STUB_BYTES" -lt 8000000000 ] || die "refusing: $STUB_PART is larger than the 6 GB stub"
    [ "$YES" = 1 ] || die "add --yes to delete the volumes above and rebuild the stub in $CT"
    for v in $VOLS; do v=${v%%=*}; echo "==> deleting $v"; diskutil apfs deleteVolume "$v" || die "could not delete $v"; done
    echo "==> seeding a fresh Data volume (prep-stub finds the container by a volume named ${STUB_NAME}*)"
    diskutil apfs addVolume "$CT" apfs "$STUB_NAME - Data" -role D
    echo "==> prep-stub.sh (resume: creates System/Preboot/Recovery, populates from this macOS)"
    (cd "$OM" && scripts/prep-stub.sh --yes)
    local NEW_SYS NEW_VGID
    NEW_SYS=$(vol_by_role "$STUB_NAME" System); NEW_VGID=$(diskutil info "$NEW_SYS" | awk -F': *' '/APFS Volume Group/{print $2}')
    echo "==> new stub VGID: $NEW_VGID"
    echo "==> finish-install.sh --m1n1 $M1N1"
    (cd "$OM" && scripts/finish-install.sh --m1n1 "$M1N1")
    echo; echo "Next: sudo shutdown -h now; hold power -> Omarchy -> step2 (bputil -nc + kmutil --raw)."
    echo "Then on the Studio: host/macos/m5.sh wait && host/macos/m5.sh fw  (expect firmware-version mBoot-20457.60.x)"
}
if [ "${1:-}" = continue ]; then
    # recreate was interrupted after the volume group was deleted: no System volume to discover.
    #   sudo refresh-stub-firmware.sh continue --container disk3 --m1n1 ~/Work/stub-backup-<VGID>/boot.bin --yes
    shift; CT=""; M1N1=""; YES=0
    while [ $# -gt 0 ]; do case "$1" in --container) CT=$2; shift 2 ;; --m1n1) M1N1=$2; shift 2 ;; --yes) YES=1; shift ;; *) die "unknown arg $1" ;; esac; done
    [ -n "$CT" ] && [ -f "$M1N1" ] || die "need --container diskN and --m1n1 FILE (the backed-up boot.bin)"
    [ -d "$OM/scripts" ] || die "omarchy-m5 not at $OM"
    [ "$(stat -f %z "$M1N1")" = 5046272 ] || echo "note: $M1N1 is not the 5046272-byte stage-1 from October"
    rebuild_from_container "$CT" "$M1N1"; exit 0
fi

SYS_VOL=$(vol_by_role "$STUB_NAME" System); [ -n "$SYS_VOL" ] || die "no stub System volume named $STUB_NAME (interrupted recreate? use: continue --container diskN)"
PB_VOL=$(vol_by_role "$STUB_NAME" Preboot)
VGID=$(diskutil info "$SYS_VOL" | awk -F': *' '/APFS Volume Group/{print $2}')
MACOS_SYS=$(diskutil info / | awk -F': *' '/Device Identifier/{print $2}')
MACOS_VGID=$(diskutil info "$MACOS_SYS" | awk -F': *' '/APFS Volume Group/{print $2}')
MAC_RESTORE=/System/Volumes/Preboot/$MACOS_VGID/restore
PB_MNT=$(mnt "$PB_VOL"); SYS_MNT=$(mnt "$SYS_VOL")
STUB_RESTORE=$PB_MNT/$VGID/restore
BOOTBIN="$SYS_MNT/Finish Installation.app/Contents/Resources/boot.bin"

echo "macOS:             $(sw_vers -productVersion) $(sw_vers -buildVersion)"
echo "macOS restore:     $MAC_RESTORE -> $(build_of "$MAC_RESTORE/BuildManifest.plist")"
echo "stub VGID:         $VGID ($SYS_VOL, Preboot $PB_VOL at $PB_MNT)"
echo "stub restore:      $STUB_RESTORE -> $(build_of "$STUB_RESTORE/BuildManifest.plist")"
echo "stub SystemVersion: $(build_of "$SYS_MNT/System/Library/CoreServices/SystemVersion.plist")"
system_profiler SPHardwareDataType 2>/dev/null | grep -E 'System Firmware Version|OS Loader Version' | sed 's/^ */host /'
ls -d "$PB_MNT/$VGID"/boot/*/ 2>/dev/null | sed 's/^/stub boot dir:     /'
[ -f "$BOOTBIN" ] && echo "stub boot.bin:     $(stat -f %z "$BOOTBIN") bytes, $(shasum -a 256 "$BOOTBIN" | cut -c1-16)..." || echo "stub boot.bin:     not present"

case ${1:-check} in
check) exit 0 ;;
refresh)
    shift; M1N1=""
    while [ $# -gt 0 ]; do case "$1" in --m1n1) M1N1=$2; shift 2 ;; *) die "unknown arg $1" ;; esac; done
    [ -d "$OM/scripts" ] || die "omarchy-m5 not at $OM"
    [ "$(build_of "$MAC_RESTORE/BuildManifest.plist")" != "$(build_of "$STUB_RESTORE/BuildManifest.plist")" ] \
        || die "stub restore bundle already matches macOS; nothing to refresh"
    if [ -z "$M1N1" ]; then
        [ -f "$BOOTBIN" ] || die "no boot.bin on the stub; pass --m1n1 PATH (e.g. m1n1 build-plain/m1n1.bin)"
        M1N1=$(mktemp /tmp/m1n1-stage1.XXXXXX); cp "$BOOTBIN" "$M1N1"
    fi
    # prep-stub.sh assumes the stub volumes are mounted and writable, as they were when it created
    # them. After the ceremony the System volume comes up read-only and Recovery is not mounted.
    REC2_VOL=$(vol_by_role "$STUB_NAME" Recovery); REC2_MNT=$(mnt "$REC2_VOL")
    mount -u -w "$SYS_MNT" || die "could not remount $SYS_MNT read-write"
    echo "stub mounts:       System $SYS_MNT (rw), Preboot $PB_MNT, Recovery $REC2_MNT"
    old="$STUB_RESTORE.$(build_of "$STUB_RESTORE/BuildManifest.plist")"
    [ -x "$OM/scripts/prep-stub.sh" ] && [ -x "$OM/scripts/finish-install.sh" ] \
        || die "prep-stub.sh or finish-install.sh missing in $OM/scripts"
    [ ! -e "$old" ] || die "$old already exists (an earlier refresh stopped half way?); move it away first"
    echo; echo "==> moving $STUB_RESTORE -> $old"; mv "$STUB_RESTORE" "$old"
    echo "==> prep-stub.sh (resume: re-populates restore, BaseSystem, SystemVersion)"
    if ! (cd "$OM" && scripts/prep-stub.sh --yes); then
        # put the bundle back so the stub still has one and the next run starts from the same state
        if [ -e "$STUB_RESTORE" ]; then
            mv "$STUB_RESTORE" "$STUB_RESTORE.failed.$$"
            echo "prep-stub.sh left a partial bundle: kept as $STUB_RESTORE.failed.$$" >&2
        fi
        mv "$old" "$STUB_RESTORE"
        die "prep-stub.sh failed; the previous restore bundle is back at $STUB_RESTORE"
    fi
    echo "==> stub restore now: $(build_of "$STUB_RESTORE/BuildManifest.plist")"
    echo "==> finish-install.sh --m1n1 $M1N1"
    (cd "$OM" && scripts/finish-install.sh --m1n1 "$M1N1")
    echo; echo "Next: sudo shutdown -h now; hold power -> Omarchy -> step2 (bputil -nc + kmutil --raw)."
    echo "Then on the Studio: host/macos/m5.sh wait && host/macos/m5.sh fw  (expect a new firmware-version)" ;;
recreate)
    shift; M1N1=""; YES=0
    while [ $# -gt 0 ]; do case "$1" in --m1n1) M1N1=$2; shift 2 ;; --yes) YES=1; shift ;; *) die "unknown arg $1" ;; esac; done
    [ -d "$OM/scripts" ] || die "omarchy-m5 not at $OM"
    STUB_CT=$(diskutil info "$SYS_VOL" | awk -F': *' '/Part of Whole/{print $2}')
    STUB_PART=$(diskutil apfs list "$STUB_CT" -plist | python3 -c '
import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(d["Containers"][0]["PhysicalStores"][0]["DeviceIdentifier"])')
    STUB_BYTES=$(diskutil info "$STUB_PART" | sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -1)
    REC2_VOL=$(vol_by_role "$STUB_NAME" Recovery); DATA_VOL=$(vol_by_role "$STUB_NAME" Data)
    VOLS=$(diskutil apfs list "$STUB_CT" -plist | python3 -c '
import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(" ".join(v["DeviceIdentifier"] + "=" + str(v.get("Name")) for v in d["Containers"][0]["Volumes"]))')
    echo; echo "stub container:    $STUB_CT on $STUB_PART ($STUB_BYTES bytes), volumes: $VOLS"
    case "$STUB_PART" in disk0s1|disk0s6) die "refusing: $STUB_PART is the iSC or the Recovery container" ;; esac
    [ "$(diskutil info "$STUB_PART" | awk -F': *' '/Partition Type/{print $2}')" = Apple_APFS ] || die "refusing: $STUB_PART is not Apple_APFS"
    [ "$STUB_BYTES" -lt 8000000000 ] || die "refusing: $STUB_PART is larger than the 6 GB stub"
    [ -n "$PB_VOL" ] && [ -n "$REC2_VOL" ] && [ -n "$DATA_VOL" ] || die "stub volume set incomplete (Data=$DATA_VOL Preboot=$PB_VOL Recovery=$REC2_VOL)"
    [ "$YES" = 1 ] || die "add --yes to delete the four volumes above (container, EFI, Linux root and macOS stay)"
    if [ -z "$M1N1" ]; then
        [ -f "$BOOTBIN" ] || die "no boot.bin on the stub; pass --m1n1 PATH"
        M1N1=$(mktemp /tmp/m1n1-stage1.XXXXXX); cp "$BOOTBIN" "$M1N1"
    fi
    HOME_DIR=$(eval echo "~${SUDO_USER:-root}")
    for r in "$PB_MNT/$VGID"/restore*; do
        b=$(build_of "$r/BuildManifest.plist"); BK=$HOME_DIR/Work/stub-backup-$b
        echo "==> backing up $r -> $BK/restore"; mkdir -p "$BK"; ditto "$r" "$BK/restore"
    done
    BK=$HOME_DIR/Work/stub-backup-$VGID; mkdir -p "$BK"
    echo "==> backing up boot dir + boot.bin + LocalPolicy-era files -> $BK"
    [ -d "$PB_MNT/$VGID/boot" ] && ditto "$PB_MNT/$VGID/boot" "$BK/boot"
    cp "$M1N1" "$BK/boot.bin"; chown -R "${SUDO_USER:-root}" "$HOME_DIR/Work/stub-backup-"* 2>/dev/null || true
    echo "==> deleting the stub volume group (exit code -69495 about a Preboot directory is harmless)"
    diskutil apfs deleteVolumeGroup "$VGID" || true
    rebuild_from_container "$STUB_CT" "$M1N1" ;;
*) die "usage: $0 check | refresh [--m1n1 FILE] | recreate --yes [--m1n1 FILE] | continue --container diskN --m1n1 FILE --yes" ;;
esac
