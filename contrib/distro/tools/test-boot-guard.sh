#!/bin/bash
# Offline test of pkg/m5pro-boot/m5pro-boot-guard with a fake pacman and a fake root. Needs bash >= 4
# (on macOS: Homebrew bash); runs as is on Linux. The guard reads pacman's command line from /proc on a
# real system; the test passes it through M5PRO_PACMAN_ARGS (honoured only under M5PRO_GUARD_TEST).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
G=$here/../pkg/m5pro-boot/m5pro-boot-guard
BASH5=$(command -v /opt/homebrew/bin/bash || command -v bash)
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir -p "$S/root/etc/m5pro" "$S/bin"

# fake pacman: -Q name; -Si [repo/]name (first repo in $FAKE_DB order); -Qp file
cat > "$S/bin/pacman" <<'FAKE'
#!/bin/bash
case $1 in
  -Q)  awk -v n="$2" '$1 == n { print $1, $2 }' "$FAKE_INST" ;;
  -Qp) b=${2##*/}; b=${b%.pkg.tar*}; b=${b%-*}; n=${b%-*-*}; echo "$n ${b#"$n"-}" ;;
  -Si) a=$2; r=; n=$a; [[ $a == */* ]] && { r=${a%%/*}; n=${a#*/}; }
       awk -v r="$r" -v n="$n" '$2 == n && (r == "" || $1 == r) { print "Repository      : " $1; print "Name            : " $2; print "Version         : " $3; exit }' "$FAKE_DB" ;;
esac
FAKE
chmod +x "$S/bin/pacman"
printf 'linux-m5pro 7.2.2-1\nm1n1-m5pro 1.6.1.m5pro14-1\nm5pro-boot 0.1.0-1\n' > "$S/inst"
# omarchy first, as after `omarchy refresh pacman` with the [m5pro] line gone below it
printf 'omarchy omarchy-mac-boot 3.1-1\nomarchy linux-m5pro 9.9-1\nm5pro linux-m5pro 7.2.3-1\nm5pro m1n1-m5pro 1.6.1.m5pro15-1\nm5pro omarchy-mac-boot 0.1-1\nextra linux-m5pro 1.0-1\n' > "$S/db"

fail=0
run() { # mode, args-string, stdin names...
  local mode=$1 args=$2; shift 2
  printf '%s\n' "$@" | M5PRO_GUARD_TEST=1 M5PRO_ROOT=$S/root M5PRO_PACMAN=$S/bin/pacman M5PRO_PACMAN_ARGS=$args \
    FAKE_DB=$S/db FAKE_INST=$S/inst "$BASH5" "$G" "$mode" 2>"$S/err"
}
expect() { # description, expected rc, then run's args
  local d=$1 want=$2; shift 2
  run "$@"; local rc=$?
  if [ "$rc" != "$want" ]; then echo "FAIL: $d (rc $rc, wanted $want)"; sed 's/^/    /' "$S/err"; fail=1; else echo "ok:   $d"; fi
}

expect "no targets"                                   0 packages "-Syu"
# first repo wins: omarchy lists linux-m5pro before m5pro, so -Syu would take it
expect "-Syu, omarchy repo first, linux-m5pro"        1 packages "-Syu" linux-m5pro
/usr/bin/grep -q 'from \[omarchy\]' "$S/err" || { echo "FAIL: message does not name the repo"; fail=1; }
expect "-Syu, m1n1-m5pro only in m5pro"               0 packages "-Syu" m1n1-m5pro
expect "m5pro/linux-m5pro explicit"                   0 packages "-S m5pro/linux-m5pro" linux-m5pro
expect "extra/linux-m5pro explicit"                   1 packages "-S extra/linux-m5pro" linux-m5pro
expect "-U package file"                              0 packages "-U /tmp/linux-m5pro-7.2.3-1-aarch64.pkg.tar.zst" linux-m5pro
expect "name in no repo, no file"                     1 packages "-S m5pro-boot" m5pro-boot
expect "omarchy-mac-boot from omarchy"                1 packages "-Syu" omarchy-mac-boot
expect "omarchy-mac-boot from m5pro"                  0 packages "-S m5pro/omarchy-mac-boot" omarchy-mac-boot
expect "one bad of two stops the transaction"         1 packages "-Syu" m1n1-m5pro linux-m5pro
expect "remove"                                       1 remove "-Rns" linux-m5pro
expect "remove, conflict-driven (no -R on the line)"  1 remove "-S something" m1n1-m5pro
expect "bad mode"                                     2 bogus "-Syu" linux-m5pro
# allow file: one transaction
touch "$S/root/etc/m5pro/allow-boot-package-change"
expect "allowed once"                                 0 packages "-Syu" linux-m5pro
[ ! -e "$S/root/etc/m5pro/allow-boot-package-change" ] || { echo "FAIL: allow file not consumed"; fail=1; }
expect "refused again after it was used"              1 packages "-Syu" linux-m5pro
# BOOT_REPOS from boot.conf
printf 'CMDLINE="x"\nBOOT_REPOS="omarchy m5pro"\n' > "$S/root/etc/m5pro/boot.conf"
expect "BOOT_REPOS lists omarchy"                     0 packages "-Syu" linux-m5pro
# the environment overrides do not count outside the test
printf '%s\n' linux-m5pro | M5PRO_ROOT=$S/root M5PRO_PACMAN=$S/bin/pacman M5PRO_PACMAN_ARGS="-Syu" FAKE_DB=$S/db FAKE_INST=$S/inst \
  "$BASH5" "$G" packages 2>/dev/null
rc=$?; if [ "$rc" = 0 ]; then echo "FAIL: overrides honoured without M5PRO_GUARD_TEST"; fail=1; else echo "ok:   overrides ignored outside the test (rc $rc)"; fi
[ "$fail" = 0 ] && echo OK || { echo FAILED; exit 1; }
