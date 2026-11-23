#!/bin/sh
# m5-crypt.sh - LUKS2 root unlock for the J716s initramfs (busybox ash). Sourced by init (v4), by m5-unlock and by
# the userspace scratch test (tests/scratch-test.sh), so the scratch test runs the same code the boot runs.
#
# Order, all bounded, nothing here can hang the boot for longer than its timeouts:
#   1. SEP token: only if the LUKS2 header has an "aurora-sep" token. apple_sep is loaded for the key store only
#      (keystore_only=1; the real root's touchid-up writes complete_attach), then `cryptsetup open --token-only`.
#   2. passphrase on the console (built-in dockchannel keyboard) up to M5C_TRIES times, a password-mode
#      (FileVault model) token takes the typed secret as its PIN. Between tries /dev/mapper/<name> is checked, so
#      `ssh root@<gadget ip> m5-unlock` (USB gadget, dropbear) can unlock instead of the keyboard.
# Never writes to the LUKS device, never formats, never touches anything but the mapping it opens.
#
# Knobs (kernel command line; m5.crypt=off skips everything and the device is left alone):
#   m5.crypt=off | m5.crypt_sep=0 (no SEP attempt) | m5.crypt_sep_wait=N (s, default 45) | m5.crypt_tries=N (3)
#   m5.crypt_prompt_timeout=N (s per passphrase try, default 120) | m5.crypt_selftest_prompt=1 (see m5c_selftest)
#   m5.crypt_name=NAME (mapper name, default m5root) | m5.crypt_kbd_wait=N (s, default 20)
# Environment overrides (tests): M5C_SEP_FAKE, M5C_STDIN, M5C_DEVMAPPER_NAME, M5C_CMDLINE (file standing in for /proc/cmdline),
#   M5C_SEPKO (path of apple-sep.ko), M5C_CONSOLE (default /dev/console), M5C_SKIP_KBD=1.

BB=${BB:-/bin/busybox}
M5C_CMDLINE=${M5C_CMDLINE:-/proc/cmdline}
M5C_CONSOLE=${M5C_CONSOLE:-/dev/console}
M5C_CONF=${M5C_CONF:-/etc/m5-crypt.conf}
M5C_SEPKO=${M5C_SEPKO:-/lib/modules/apple-sep.ko}
[ -r "$M5C_CONF" ] && . "$M5C_CONF"     # SEP_OPTS="..." (the options /etc/modprobe.d/apple-sep.conf has on the root)

m5c_log() { echo "m5-crypt: $*"; echo "<5>m5-crypt: $*" > /dev/kmsg 2>/dev/null; echo "$*" >> /run/m5-crypt.log 2>/dev/null; return 0; }
m5c_arg() { $BB sed -n "s/^\\(.* \\)\\{0,1\\}$1=\\([^ ]*\\).*/\\2/p" "$M5C_CMDLINE" | $BB tail -n 1; }
m5c_argdef() { v=$(m5c_arg "$1"); echo "${v:-$2}"; }

M5C_NAME=${M5C_DEVMAPPER_NAME:-$(m5c_argdef m5\\.crypt_name m5root)}
M5C_TRIES=$(m5c_argdef m5\\.crypt_tries 3)
M5C_SEPWAIT=$(m5c_argdef m5\\.crypt_sep_wait 45)
M5C_KBDWAIT=$(m5c_argdef m5\\.crypt_kbd_wait 20)
M5C_PROMPT_TIMEOUT=$(m5c_argdef m5\\.crypt_prompt_timeout 120)

# m5c_enabled: 0 unless m5.crypt=off
m5c_enabled() { [ "$(m5c_arg m5\\.crypt)" != off ]; }

# m5c_sepoff: SEP and every token disabled (m5.crypt_sep=0, or forced by the selftest's prompt phase)
m5c_sepoff() { [ "$M5C_FORCE_NOSEP" = 1 ] || [ "$(m5c_arg m5\\.crypt_sep)" = 0 ]; }

# m5c_isluks DEV
m5c_isluks() { [ -x /sbin/cryptsetup ] && /sbin/cryptsetup isLuks "$1" >/dev/null 2>&1; }

# m5c_has_sep_token DEV: the header carries an aurora-sep token (readable without any key)
m5c_has_sep_token() { /sbin/cryptsetup luksDump "$1" 2>/dev/null | $BB grep -q 'aurora-sep'; }

# m5c_kbd_wait: wait until the input core lists a keyboard (handler "kbd"), print which one. Returns 1 on timeout.
m5c_kbd_wait() {
    [ -n "$M5C_SKIP_KBD" ] && return 0
    i=0
    while [ $i -lt $((M5C_KBDWAIT * 5)) ]; do
        if $BB awk 'BEGIN{RS="";FS="\n"} /Handlers=[^\n]*kbd/ {for(k=1;k<=NF;k++) if ($k ~ /^N: /) {print $k; found=1}} END{exit !found}' /proc/bus/input/devices > /run/m5-crypt.kbd 2>/dev/null; then
            m5c_log "keyboard: $($BB head -n 1 /run/m5-crypt.kbd)"
            return 0
        fi
        $BB sleep 0.2; i=$((i + 1))
    done
    m5c_log "WARNING: no keyboard after ${M5C_KBDWAIT}s; unlock over the USB gadget: ssh root@10.55.0.2 m5-unlock"
    return 1
}

# m5c_keystore_load: the SEP key store copies (aurora-sep-keybag.bin, aurora-sep-refkey*.bin) the driver reads from /var/lib.
# The driver rewrites the key bag on the root every boot (mtime), so a copy frozen into the initramfs can go stale. Source order:
#   1. the ESP directory m5sep/ (m5.esp= device, default /dev/nvme0n1p4, mounted read-only): kept current by the root's
#      m5pro-sep-keystore-sync (rootside/), no repack needed;
#   2. the copies embedded in this initramfs (/var/lib, written at build time).
# Both are logged by sha256 prefix so a stale unseal can be told from a SEP refusal.
m5c_keystore_load() {
    esp=$(m5c_argdef m5\\.esp /dev/nvme0n1p4); used=embedded
    if [ -b "$esp" ]; then
        $BB mkdir -p /esp
        if $BB mount -t vfat -o ro "$esp" /esp 2>/dev/null; then
            if [ -s /esp/m5sep/aurora-sep-keybag.bin ] && [ -s /esp/m5sep/aurora-sep-refkey.bin ]; then
                $BB mkdir -p /var/lib
                for f in /esp/m5sep/aurora-sep-*.bin; do $BB cp "$f" /var/lib/ && $BB chmod 600 "/var/lib/${f##*/}"; done; used=esp
            fi
            $BB umount /esp 2>/dev/null
        else m5c_log "key store: cannot mount $esp (vfat)"; fi
    fi
    for f in /var/lib/aurora-sep-*.bin; do [ -e "$f" ] && m5c_log "key store ($used): ${f##*/} $($BB sha256sum "$f" | $BB cut -c1-12) $($BB wc -c < "$f") B"; done
    [ -s /var/lib/aurora-sep-keybag.bin ]
}

# m5c_sep_load: load apple_sep for the key store only. Returns 0 when the SEP key source is (or already was) up.
m5c_sep_load() {
    m5c_sepoff && { m5c_log "SEP unlock disabled (m5.crypt_sep=0)"; return 1; }
    [ -d /sys/module/apple_sep ] && return 0
    m5c_keystore_load
    [ -n "$M5C_SEP_FAKE" ] && return 0       # tests only (tests/qemu): the plugin is the user-key build, no SEP driver
    [ -r "$M5C_SEPKO" ] || { m5c_log "no apple-sep.ko in this initramfs"; return 1; }
    [ -s /var/lib/aurora-sep-keybag.bin ] || { m5c_log "no SEP key store copy in this initramfs"; return 1; }
    # the module must be the one built for the running kernel
    want=$($BB cat /lib/modules/apple-sep.release 2>/dev/null); have=$($BB uname -r)
    [ -z "$want" ] || [ "$want" = "$have" ] || { m5c_log "apple-sep.ko is for $want, kernel is $have"; return 1; }
    # apple_sep.* words on the command line (the OS identity pin) reach a module loaded later only if passed here
    cl=$($BB tr ' ' '\n' < "$M5C_CMDLINE" | $BB sed -n 's/^apple_sep\.\(.*=.*\)$/\1/p' | $BB tr '\n' ' ')
    m5c_log "insmod apple-sep.ko keystore_only=1 ${SEP_OPTS:-} $cl"
    $BB timeout 120 $BB insmod "$M5C_SEPKO" keystore_only=1 ${SEP_OPTS:-} $cl || { m5c_log "insmod apple_sep failed"; return 1; }
    return 0
}

# m5c_open DEV: unlock DEV as /dev/mapper/$M5C_NAME. Returns 0 when it is open.
m5c_open() {
    dev=$1
    echo "$dev" > /run/m5-crypt.dev 2>/dev/null
    [ -b /dev/mapper/$M5C_NAME ] && return 0
    # --- 1. SEP token
    if m5c_has_sep_token "$dev"; then
        m5c_log "$dev has an aurora-sep token"
        if m5c_sep_load; then
            t0=$($BB cut -d. -f1 /proc/uptime)
            AURORA_SEP_WAIT=$M5C_SEPWAIT $BB timeout $((M5C_SEPWAIT + 30)) /sbin/cryptsetup open --token-only --token-type aurora-sep "$dev" "$M5C_NAME" > /run/m5-crypt.sep.out 2>&1
            rc=$?
            m5c_log "SEP token: rc=$rc after $(( $($BB cut -d. -f1 /proc/uptime) - t0 )) s: $($BB tail -n 2 /run/m5-crypt.sep.out | $BB tr '\n' ' ')"
            [ $rc -eq 0 ] && [ -b /dev/mapper/$M5C_NAME ] && { m5c_log "unlocked by the Secure Enclave"; return 0; }
        fi
    fi
    # --- 2. passphrase / password (keyboard, or `m5-unlock` over ssh)
    m5c_kbd_wait
    NOTOK=; m5c_sepoff && NOTOK=--disable-external-tokens    # m5.crypt_sep=0: no token at all, passphrase only
    n=0
    while [ $n -lt $M5C_TRIES ]; do
        [ -b /dev/mapper/$M5C_NAME ] && { m5c_log "unlocked (by m5-unlock)"; return 0; }
        n=$((n + 1))
        { echo; echo "m5-crypt: unlock $dev ($n/$M5C_TRIES, $M5C_PROMPT_TIMEOUT s per try; or ssh root@10.55.0.2 m5-unlock)"; } > "$M5C_CONSOLE" 2>/dev/null
        # no token wait here: stage 1 already spent it; a password-mode token takes this typed secret as its PIN
        AURORA_SEP_WAIT=0 $BB timeout $M5C_PROMPT_TIMEOUT /sbin/cryptsetup open --tries 1 $NOTOK --type luks "$dev" "$M5C_NAME" < "${M5C_STDIN:-$M5C_CONSOLE}" > "$M5C_CONSOLE" 2>&1
        rc=$?
        [ $rc -eq 0 ] && [ -b /dev/mapper/$M5C_NAME ] && { m5c_log "unlocked by passphrase"; return 0; }
        m5c_log "passphrase try $n failed (rc=$rc)"
    done
    [ -b /dev/mapper/$M5C_NAME ] && return 0
    m5c_log "NOT unlocked after $M5C_TRIES tries; the LUKS device is untouched"
    return 1
}

# m5c_selftest IMAGE LOG: reboot-test mode (m5.crypt_selftest=<path in the root>). After the ordinary (unencrypted)
# root is mounted at /mnt, open a scratch LUKS2 image FILE that lives on it, by the SEP token only (no prompt),
# read its canary, close it, write the result to LOG. Never blocks the boot beyond the SEP wait; never touches the root.
m5c_selftest() {
    img=$1; log=$2
    M5C_NAME=m5scratch; M5C_TRIES=0; M5C_SKIP_KBD=1
    : > /run/m5-crypt.log
    m5c_log "selftest: image $img, kernel $($BB uname -r), cmdline: $($BB cat /proc/cmdline)"
    if [ ! -f "$img" ]; then m5c_log "selftest: FAIL no such image"; res=FAIL
    elif ! m5c_isluks "$img"; then m5c_log "selftest: FAIL not a LUKS image"; res=FAIL
    else
        res=FAIL
        m5c_selftest_phase "$img" token && res=PASS
        # m5.crypt_selftest_prompt=1 (attended): second phase, SEP forced off, the owner types the scratch passphrase on the
        # console keyboard (one try, 120 s). Proves the dockchannel keyboard + prompt in the initramfs.
        if [ "$(m5c_arg m5\\.crypt_selftest_prompt)" = 1 ]; then
            M5C_FORCE_NOSEP=1; M5C_TRIES=1; M5C_SKIP_KBD=
            m5c_selftest_phase "$img" prompt && m5c_log "selftest: PROMPT PASS" || { m5c_log "selftest: PROMPT FAIL"; res=FAIL; }
            M5C_FORCE_NOSEP=; M5C_TRIES=0; M5C_SKIP_KBD=1
        fi
    fi
    m5c_log "selftest: RESULT $res"
    { echo "== m5-crypt selftest $(date -u +%FT%TZ) kernel $($BB uname -r) cmdline: $($BB cat /proc/cmdline)"
      $BB cat /run/m5-crypt.log; [ -f /run/m5-crypt.sep.out ] && { echo "-- cryptsetup output:"; $BB cat /run/m5-crypt.sep.out; }
      echo "-- dmesg (sep|crypt|trusted|input|hid):"; $BB dmesg | $BB grep -i -E 'apple.sep|aurora|trusted|dm-crypt|device-mapper|dockchannel|hid' | $BB tail -n 60
    } >> "$log" 2>&1
    rm -f /run/m5-crypt.dev
    [ "$res" = PASS ]
}
# m5c_selftest_phase IMG LABEL: open, read the canary, close. 0 = unlocked and read.
m5c_selftest_phase() {
    if m5c_open "$1"; then
        $BB mkdir -p /tmp/m5scratch
        if $BB mount -t ext4 -o ro /dev/mapper/$M5C_NAME /tmp/m5scratch 2>/dev/null; then
            m5c_log "selftest[$2]: canary=$($BB cat /tmp/m5scratch/canary 2>&1)"; $BB umount /tmp/m5scratch; ok=0
        else m5c_log "selftest[$2]: unlocked but the file system did not mount"; ok=1; fi
        /sbin/cryptsetup close $M5C_NAME 2>/dev/null; return $ok
    fi
    m5c_log "selftest[$2]: not unlocked"; return 1
}
