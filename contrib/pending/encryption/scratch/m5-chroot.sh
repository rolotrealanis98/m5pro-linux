# m5-chroot.sh - shared by scratch-test.sh, enc2-prep.sh and safe-rm.sh. SOURCE it, do not run it.
# Past incident (2026-11-23, encryption-1): the first scratch-test.sh --rbind-mounted the REAL /dev (and /sys) under its chroot,
# its cleanup did not unmount them, and the request's `rm -rf /var/tmp/m5-enc1` then deleted every device node of the Mac's
# live /dev. Rules since: (1) all chroot mounts live in a private mount namespace (`unshare -m --propagation private`), so
# they vanish when the script exits even if cleanup fails; (2) the real /dev is NEVER mounted into a chroot: a private tmpfs
# /dev with copies of the few nodes needed; (3) /sys is a non-recursive bind; (4) nothing here ever `rm -rf`s a tree that has
# a mount under it (m5_safe_rm refuses, and uses --one-file-system); (5) cleanup verifies with /proc/self/mountinfo.

m5_mounts_under() { awk -v p="$1" '{ if (index($5, p) == 1 && (length($5) == length(p) || substr($5, length(p) + 1, 1) == "/")) print $5 }' /proc/self/mountinfo; }

# m5_safe_rm DIR: remove DIR only if nothing is mounted at or under it. No lazy tricks, no -r over a mountpoint.
m5_safe_rm() {
    d=$(readlink -f "$1") || return 1
    case "$d" in /var/tmp/m5-*|/var/lib/m5-enc*) ;; *) echo "m5_safe_rm: refusing $d (not under /var/tmp/m5-* or /var/lib/m5-enc*)"; return 1 ;; esac
    m=$(m5_mounts_under "$d")
    if [ -n "$m" ]; then echo "m5_safe_rm: REFUSING, still mounted under $d:"; echo "$m"; return 1; fi
    rm -rf --one-file-system "$d" 2>/dev/null || rm -rf "$d"   # GNU option first; plain rm is safe too: nothing is mounted under $d (checked above)
}

# m5_enter_ns SCRIPT ARGS...: re-exec inside a private mount namespace once.
m5_enter_ns() {
    if [ -z "${M5_IN_NS:-}" ]; then
        command -v unshare >/dev/null || { echo "unshare (util-linux) is required"; exit 2; }
        M5_IN_NS=1 exec unshare -m --propagation private "$@"
    fi
}

# m5_chroot_setup ROOT SHARED_DIR: private /dev (tmpfs + needed nodes), proc, non-recursive sys, run tmpfs, SHARED_DIR at /mnt.
m5_chroot_setup() {
    R=$1; S=$2
    mkdir -p "$R"/{dev,proc,sys,run,mnt}
    mount -t tmpfs -o mode=755,size=2m tmpfs "$R/dev"
    for n in null zero urandom random tty full; do cp -a /dev/$n "$R/dev/$n"; done
    cp -a /dev/loop-control "$R/dev/"; for l in /dev/loop[0-9]*; do cp -a "$l" "$R/dev/"; done
    mkdir -p "$R/dev/mapper"; cp -a /dev/mapper/control "$R/dev/mapper/" || { echo "no /dev/mapper/control (dm_mod not loaded?)"; return 1; }
    mount -t proc proc "$R/proc"
    mount --bind /sys "$R/sys"            # non-recursive: sysfs only, no securityfs/cgroup/etc.
    mount -t tmpfs tmpfs "$R/run"
    mount --bind "$S" "$R/mnt"
}

# m5_chroot_teardown ROOT: unmount everything under ROOT (deepest first), verify, report.
m5_chroot_teardown() {
    R=$(readlink -f "$1") || return 1
    for i in 1 2 3; do
        for m in $(m5_mounts_under "$R" | sort -r); do umount "$m" 2>/dev/null; done
        [ -z "$(m5_mounts_under "$R")" ] && break
        for m in $(m5_mounts_under "$R" | sort -r); do umount -l "$m" 2>/dev/null; done
    done
    left=$(m5_mounts_under "$R")
    if [ -n "$left" ]; then echo "TEARDOWN INCOMPLETE, still mounted (this is a private namespace: they vanish at exit, but do NOT rm -rf here):"; echo "$left"; return 1; fi
    echo "teardown verified: nothing mounted under $R"
}
