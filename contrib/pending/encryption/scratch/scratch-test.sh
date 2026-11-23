#!/bin/bash
# encryption-1 on the J716s, as root, NO reboot: the initramfs unlock code against a LUKS2 container that is a FILE.
# Proves, on the running machine: (a) the initramfs's own musl cryptsetup + aurora-sep token plugin work against the real
# SEP, (b) /lib/m5-crypt.sh (the code init.v4 runs) unlocks by SEP token and falls back to the passphrase, (c) failures
# leave the container untouched, (d) a token copied to another volume is refused, (e) the internal keyboard is a
# built-in driver (no module, no file the initramfs would have to carry).
# It touches ONLY files under $W and the loop/dm devices it creates itself. It never opens a block device that is not
# its own loop device (checked before every cryptsetup call) and contains no path of the real disk.
# usage: sudo ./scratch-test.sh CHROOT_TARBALL.tar.gz       (CHROOT_TARBALL = the prod initramfs unpacked, built by the
#        build; its /lib/m5-crypt.sh, /sbin/cryptsetup and token plugin are what the boot runs)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/m5-chroot.sh"
m5_enter_ns bash "$0" "$@"     # everything below runs in a private mount namespace
TAR=${1:?usage: scratch-test.sh chroot-v4-prod.tar.gz}
W=/var/tmp/m5-enc1; R=$W/root; IMG=$W/scratch.img; IMG2=$W/scratch2.img; LOG=$W/result.txt
PASSF=$W/pass; WRONGF=$W/wrong
NAME=m5scratch; MNT=$W/mnt
FAILS=0; LOOP=; LOOP2=
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
mkdir -p "$W" && : > "$LOG"
say()  { echo "$*" | tee -a "$LOG"; }
pass() { say "PASS $1"; }
fail() { say "FAIL $1${2:+  -> $2}"; FAILS=$((FAILS+1)); }
cleanup() {
    umount "$MNT" 2>/dev/null
    for n in $NAME ${NAME}2; do cryptsetup close $n 2>/dev/null; done
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; [ -n "$LOOP2" ] && losetup -d "$LOOP2" 2>/dev/null
    m5_chroot_teardown "$R" | tee -a "$LOG"
    say "cleanup done. Remove with: bash $HERE/safe-rm.sh $W   (it refuses while anything is mounted under it; never rm -rf it by hand)"
}
trap cleanup EXIT
own_loop() {   # own_loop /dev/loopN IMAGE: refuse unless the loop device is backed by our image file
    [ "$(losetup -nO BACK-FILE "$1" 2>/dev/null)" = "$2" ] || { say "ABORT: $1 is not backed by $2"; exit 3; }
}
say "== m5 encryption-1 $(date -u +%FT%TZ)  kernel $(uname -r)  root $(findmnt -no SOURCE /)"
say "== precondition: apple_sep loaded, trusted keys on, dm-crypt, loop"
[ -d /sys/module/apple_sep ] && pass "apple_sep is loaded" || fail "apple_sep not loaded (touchid-up not run?)"
dmesg | grep -q 'registering "trusted" key type' && pass "trusted key type registered by the SEP driver" || fail "no trusted key registration line in dmesg"
modprobe dm_crypt 2>/dev/null; [ -e /dev/mapper/control ] || modprobe dm_mod 2>/dev/null
grep -q -w xts /proc/crypto || modprobe xts 2>/dev/null
[ -c /dev/mapper/control ] && pass "device-mapper control present" || fail "no /dev/mapper/control"
[ -c /dev/loop-control ] && pass "loop control present" || fail "no /dev/loop-control"

say "== keyboard: built in, firmware in the initramfs, listed by the input core"
KB=$(awk 'BEGIN{RS="";FS="\n"} /Handlers=[^\n]*kbd/ {for(k=1;k<=NF;k++) if ($k ~ /^N: /) print $k}' /proc/bus/input/devices)
say "keyboard devices with a kbd handler: ${KB:-none}"
[ -n "$KB" ] && pass "input core lists a keyboard with the console (kbd) handler" || fail "no keyboard with a kbd handler"
for m in dockchannel_hid hid_dockchannel; do [ -d /sys/module/$m ] && DC=$m; done
if grep -q -i dockchannel /lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null || [ -n "${DC:-}" ]; then
    if find /lib/modules/"$(uname -r)" -iname '*dockchannel*hid*.ko*' 2>/dev/null | grep -q .; then fail "dockchannel-hid is a module on this kernel: the initramfs would need it"
    else pass "dockchannel-hid is built in (modules.builtin / sysfs, no .ko): nothing to carry in the initramfs"; fi
else say "NOTE could not tell from modules.builtin; check /sys/module for the HID driver"; fi
FW=$(dmesg | grep -i -E 'tpmtfw|dockchannel.*firmware|MTP.*firmware' | tail -n 3); say "firmware lines in dmesg: ${FW:-none}"
[ -f /usr/lib/firmware/apple/tpmtfw-j716s.bin ] && say "NOTE root has tpmtfw-j716s.bin; the initramfs must carry the same file under /lib/firmware/apple (it does in v3/v4)"

say "== chroot (the initramfs, unpacked)"
m5_safe_rm "$R" || exit 1; mkdir -p "$R" "$MNT"; tar -xzf "$TAR" -C "$R" 2>/dev/null; mkdir -p "$R"/{tmp,var/lib}
[ -x "$R/sbin/cryptsetup" ] && [ -f "$R/lib/m5-crypt.sh" ] && [ -f "$R/usr/lib/cryptsetup/libcryptsetup-token-aurora-sep.so" ] && pass "chroot has cryptsetup, m5-crypt.sh, the token plugin" || { fail "chroot incomplete"; exit 1; }
m5_chroot_setup "$R" "$W"
inroot() { chroot "$R" /bin/busybox env PATH=/sbin:/usr/sbin:/bin:/usr/bin "$@"; }
inroot /sbin/cryptsetup --version | tee -a "$LOG"
inroot /sbin/cryptsetup --help | grep -i 'external token' | tee -a "$LOG"

say "== scratch container"
printf 'm5-enc1-passphrase' > "$PASSF"; printf 'wrong-passphrase' > "$WRONGF"; chmod 600 "$PASSF" "$WRONGF"
rm -f "$IMG" "$IMG2"; truncate -s 64M "$IMG" "$IMG2"
LOOP=$(losetup --find --show "$IMG"); own_loop "$LOOP" "$IMG"; cp -a "$LOOP" "$R/dev/"
LOOP2=$(losetup --find --show "$IMG2"); own_loop "$LOOP2" "$IMG2"; cp -a "$LOOP2" "$R/dev/"
# the format runs through the chroot's musl cryptsetup; memory-light argon2 so it is quick
mk() {   # mk LOOPDEV NAME CANARY
    own_loop "$1" "$([ "$1" = "$LOOP" ] && echo $IMG || echo $IMG2)"
    inroot /sbin/cryptsetup luksFormat --type luks2 --batch-mode --pbkdf argon2id --pbkdf-memory 65536 --pbkdf-parallel 1 --iter-time 200 "$1" /mnt/pass || return 1
    inroot /sbin/cryptsetup open "$1" "$2" --key-file /mnt/pass || return 1
    mkfs.ext4 -q -L m5scratch "$R/dev/mapper/$2" || return 1
    mount "$R/dev/mapper/$2" "$MNT" && echo "m5-crypt-canary-$3" > "$MNT/canary" && umount "$MNT"; rc=$?
    inroot /sbin/cryptsetup close "$2"; return $rc
}
mk "$LOOP" $NAME real && pass "LUKS2 container formatted by the initramfs cryptsetup (aes-xts, argon2id), ext4 inside" || fail "format"
mk "$LOOP2" ${NAME}2 other && pass "second container (for the foreign-token check)" || fail "second format"
own_loop "$LOOP" "$IMG"
PASSWORD=$(cat "$PASSF") inroot /sbin/aurora-sep-cryptenroll "$LOOP" 2>&1 | tee -a "$LOG"
inroot /sbin/aurora-sep-cryptenroll --status "$LOOP" 2>&1 | tee -a "$LOG" | grep -q '^1 SEP enrolment' && pass "SEP enrolment: token + keyslot added, SEP sealed a key (real apple_sep)" || fail "enrol"
inroot /sbin/aurora-sep-cryptenroll --test "$LOOP" 2>&1 | tee -a "$LOG"; [ "${PIPESTATUS[0]}" = 0 ] && pass "aurora-sep-cryptenroll --test opens through the token" || fail "enrol --test"
H0=$(sha256sum < "$IMG")

say "== the boot's own code: m5c_open, SEP token path (the same function init.v4 calls)"
ONE() {   # ONE CMDLINE STDIN-FILE EXPECT-RC  (runs m5c_open in the chroot against the loop device; prints result)
    printf '%s\n' "$1" > "$W/cmdline"
    ( inroot /bin/sh -c "M5C_CMDLINE=/mnt/cmdline M5C_STDIN=/mnt/$2 M5C_CONSOLE=/dev/null M5C_SKIP_KBD=1 M5C_DEVMAPPER_NAME=$NAME; export M5C_CMDLINE M5C_STDIN M5C_CONSOLE M5C_SKIP_KBD M5C_DEVMAPPER_NAME; BB=/bin/busybox; . /lib/m5-crypt.sh; m5c_open $LOOP; echo m5c_open_rc=\$?" ) 2>&1 | tee -a "$LOG"
}
own_loop "$LOOP" "$IMG"
T0=$(date +%s); OUT=$(ONE "m5.crypt_sep_wait=30" wrong); T1=$(date +%s)
echo "$OUT" | grep -q 'unlocked by the Secure Enclave' && echo "$OUT" | grep -q 'm5c_open_rc=0' && [ -b "$R/dev/mapper/$NAME" ] && pass "SEP token unlock through m5c_open in $((T1-T0)) s (no passphrase given: stdin is the WRONG passphrase file)" || fail "SEP token unlock" "$OUT"
mount -o ro "$R/dev/mapper/$NAME" "$MNT" && grep -q 'canary-real' "$MNT/canary" && pass "unlocked volume mounts and holds the canary" || fail "mount/canary"
umount "$MNT"; inroot /sbin/cryptsetup close $NAME

say "== fallback: SEP off (m5.crypt_sep=0), wrong passphrase, then right one"
OUT=$(ONE "m5.crypt_sep=0 m5.crypt_tries=1" wrong); echo "$OUT" | grep -q 'NOT unlocked' && [ ! -b "$R/dev/mapper/$NAME" ] && pass "wrong passphrase: not unlocked, no mapping" || fail "wrong passphrase" "$OUT"
[ "$(sha256sum < "$IMG")" = "$H0" ] && pass "container byte-identical after the failed unlock" || fail "container changed by a failed unlock"
OUT=$(ONE "m5.crypt_sep=0 m5.crypt_tries=1" pass); echo "$OUT" | grep -q 'unlocked by passphrase' && pass "right passphrase unlocks (the keyboard-prompt path, stdin from a file)" || fail "passphrase unlock" "$OUT"
inroot /sbin/cryptsetup close $NAME

say "== a token copied onto another volume is refused (token is bound to its LUKS UUID)"
own_loop "$LOOP" "$IMG"; own_loop "$LOOP2" "$IMG2"
TJ=$W/token.json; inroot /sbin/cryptsetup token export --token-id 0 "$LOOP" > "$TJ" 2>/dev/null
if [ -s "$TJ" ]; then
    inroot /sbin/cryptsetup token import "$LOOP2" < "$TJ" >/dev/null 2>&1
    out=$(inroot /sbin/cryptsetup open --token-only --token-type aurora-sep "$LOOP2" ${NAME}2 2>&1); rc=$?
    [ $rc -ne 0 ] && [ ! -b "$R/dev/mapper/${NAME}2" ] && pass "foreign token refused (rc=$rc)" || { fail "foreign token opened another volume"; inroot /sbin/cryptsetup close ${NAME}2; }
else say "NOTE token export not available; foreign-token check skipped"; fi

say "== optional attended keyboard check: ATTENDED_KBD=1 makes this wait 15 s for ANY key on the internal keyboard"
if [ "${ATTENDED_KBD:-0}" = 1 ]; then
    ev=$(awk 'BEGIN{RS="";FS="\n"} /Handlers=[^\n]*kbd/ && /dockchannel|Apple|Keyboard/ {for(k=1;k<=NF;k++) if ($k ~ /^H: /) {match($k,/event[0-9]+/); print substr($k,RSTART,RLENGTH); exit}}' /proc/bus/input/devices)
    say "press a key on the built-in keyboard now ($ev)"; timeout 15 head -c 24 /dev/input/$ev | od -An -tx1 | head -n 2 | tee -a "$LOG" | grep -q . && pass "key events read from $ev" || fail "no key event from $ev in 15 s"
fi
say "== result: $FAILS failure(s)  (log $LOG)"
[ $FAILS = 0 ]
