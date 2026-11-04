#!/bin/bash
# Offline test of pkg/m5pro-boot/m5pro-update-payload against the October J716s artifacts
# (~/Work/studio-artifacts) in a fake root and a fake ESP directory. Needs GNU coreutils
# (brew coreutils) and bash >= 4 on macOS; runs as is on Linux.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=$here/../pkg/m5pro-boot/m5pro-update-payload
A=${M5_ARTIFACTS:-$HOME/Work/studio-artifacts}
M1N1=${M1N1_PLAIN:-$HOME/Work/m1n1-linuxbuild/m1n1-plain.bin}
[ "$(uname -s)" = Darwin ] && export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"
BASH5=$(command -v /opt/homebrew/bin/bash || command -v bash)
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
K=$S/root/usr/lib/modules/7.2.2-m5pro
mkdir -p "$K/dtbs/apple" "$S/root/usr/lib/m1n1-m5pro" "$S/root/boot" "$S/root/etc/m5pro" "$S/esp"
cp "$A/Image.gz" "$K/"; echo linux-m5pro > "$K/pkgbase"; cp "$A/t6050-j716s.dtb" "$K/dtbs/apple/"
cp "$M1N1" "$S/root/usr/lib/m1n1-m5pro/m1n1-stage2.bin"; cp "$A/initramfs.cpio.gz" "$S/root/boot/initramfs-linux-m5pro.img"
run() { "$BASH5" "$U" --root "$S/root" --esp "$S/esp" --board j716s "$@"; }
run build; run build | grep -q 'already'; run verify
echo 'CMDLINE="console=tty0 root=LABEL=m5root rw"' > "$S/root/etc/m5pro/boot.conf"
if run verify; then echo "verify should report stale"; exit 1; fi
run build; run status; run rollback
printf '\x28\xb5\x2f\xfd' > "$S/z.img"; if run build --initramfs "$S/z.img" 2>/dev/null; then echo "zstd accepted"; exit 1; fi
python3 -I "$here/mk-stage1.py" inspect "$S/esp/m1n1/boot.bin" | head -6
echo OK
