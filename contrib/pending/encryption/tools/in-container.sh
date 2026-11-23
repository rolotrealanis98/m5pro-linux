#!/bin/sh
# Runs INSIDE an Alpine 3.22 aarch64 container (same musl as the daily initramfs). Builds cryptsetup 2.7.5 with
# external-token support (Alpine's own package has it disabled), the aurora-sep token plugin and enrolment tool from
# aurora-sep-userspace, and stages the overlay tree + cpio. Called by build-initramfs.sh; nothing here touches a device.
# usage: in-container.sh WORK SEPSRC INDIR [test]     WORK/overlay.cpio and WORK/manifest.txt are the results
set -eu
WORK=$1; SEPSRC=$2; IN=$3; MODE=${4:-prod}
CS_VER=2.7.5; CS_SHA=d2be4395b8f503b0ebf4b2d81db90c35a97050a358ee21fe62a0dfb66e5d5522
apk add --no-cache bash build-base pkgconf cryptsetup-dev json-c-dev keyutils-dev linux-headers cpio curl xz tar \
    popt-dev openssl-dev lvm2-dev util-linux-dev argon2-dev gettext-dev >/dev/null
B=/root/b; mkdir -p "$B" && cd "$B"   # build on the container disk: the shared volume loses exec bits in the autotools tree
[ -f cs.tar.xz ] || curl -fsSL -o cs.tar.xz https://www.kernel.org/pub/linux/utils/cryptsetup/v2.7/cryptsetup-$CS_VER.tar.xz
echo "$CS_SHA  cs.tar.xz" | sha256sum -c - >/dev/null
rm -rf cryptsetup-$CS_VER stage; tar xf cs.tar.xz
( cd cryptsetup-$CS_VER && ./configure --prefix=/usr --sbindir=/sbin --libdir=/usr/lib --disable-ssh-token --disable-asciidoc \
    --disable-nls --disable-static --enable-external-tokens --with-crypto_backend=openssl --disable-udev --disable-selinux \
    --disable-veritysetup --disable-integritysetup >configure.log 2>&1 && { make -j"$(nproc)" >make.log 2>&1 || { tail -20 make.log; exit 1; }; } \
  && make install DESTDIR="$B/stage" >inst.log 2>&1 && make install >inst2.log 2>&1 )
rm -rf luks && cp -r "$SEPSRC/luks" luks && cd luks && make clean >/dev/null 2>&1 || true
if [ "$MODE" = test ]; then   # kernel "user" keys instead of the SEP: for the QEMU test only, never for the Mac
    make test/libcryptsetup-token-aurora-sep.so test/aurora-sep-cryptenroll >/dev/null
    PLUG=test/libcryptsetup-token-aurora-sep.so; ENR=test/aurora-sep-cryptenroll
else
    make libcryptsetup-token-aurora-sep.so aurora-sep-cryptenroll >/dev/null
    PLUG=libcryptsetup-token-aurora-sep.so; ENR=aurora-sep-cryptenroll
fi
O=$WORK/ovl; rm -rf "$O"; mkdir -p "$O/sbin" "$O/usr/lib/cryptsetup" "$O/usr/sbin" "$O/lib/modules" "$O/etc/aurora-sep" "$O/var/lib" "$O/run"
install -m 755 "$B/stage/sbin/cryptsetup" "$O/sbin/cryptsetup"
cp -a "$B"/stage/usr/lib/libcryptsetup.so* "$O/usr/lib/"
install -m 755 "$PLUG" "$O/usr/lib/cryptsetup/libcryptsetup-token-aurora-sep.so"
install -m 755 "$ENR" "$O/sbin/aurora-sep-cryptenroll"
install -m 644 fde.conf "$O/etc/aurora-sep/fde.conf"
install -m 755 "$IN/init.v4" "$O/init"
install -m 644 "$IN/m5-crypt.sh" "$O/lib/m5-crypt.sh"
install -m 755 "$IN/m5-unlock" "$O/usr/sbin/m5-unlock"
[ -f "$IN/m5-crypt.conf" ] && install -m 644 "$IN/m5-crypt.conf" "$O/etc/m5-crypt.conf"
[ -f "$IN/apple-sep.ko" ] && { install -m 644 "$IN/apple-sep.ko" "$O/lib/modules/apple-sep.ko"; install -m 644 "$IN/apple-sep.release" "$O/lib/modules/apple-sep.release"; }
if [ -d "$IN/keystore" ]; then for f in "$IN"/keystore/aurora-sep-*.bin; do [ -s "$f" ] && install -m 600 "$f" "$O/var/lib/$(basename "$f")"; done; fi
# shared libraries the three binaries need that the base initramfs does not carry
: > "$WORK/needed.txt"
for b in "$O/sbin/cryptsetup" "$O/usr/lib/cryptsetup/libcryptsetup-token-aurora-sep.so" "$O/sbin/aurora-sep-cryptenroll"; do
    LD_LIBRARY_PATH="$O/usr/lib" ldd "$b" 2>/dev/null | sed -n 's/.*=> \(\/[^ ]*\) .*/\1/p' >> "$WORK/needed.txt"
done
sort -u "$WORK/needed.txt" -o "$WORK/needed.txt"
while read -r lib; do
    case "$lib" in "$O"/*|*/ld-musl-*|*/libc.musl-*) continue ;; esac
    real=$(readlink -f "$lib"); name=$(basename "$lib"); dir=$(dirname "$lib")
    if grep -q -x -F "${dir#/}/$name" "$IN/base.list" 2>/dev/null || grep -q -x -F "${dir#/}/$(basename "$real")" "$IN/base.list" 2>/dev/null; then
        echo "base has $lib"; continue
    fi
    mkdir -p "$O$dir"; cp -a "$real" "$O$dir/$(basename "$real")"
    [ "$name" != "$(basename "$real")" ] && ln -sf "$(basename "$real")" "$O$dir/$name"
    echo "add $lib"
done < "$WORK/needed.txt" | tee "$WORK/libs.txt"
{ echo "built $(date -u +%FT%TZ) in $(cat /etc/alpine-release) mode=$MODE"
  echo "cryptsetup $CS_VER sha256 $CS_SHA"
  echo "aurora-sep-userspace $(git -C "$SEPSRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  ( cd "$O" && find . -type f | sort | xargs sha256sum ); } > "$O/etc/m5-crypt.build"
( cd "$O" && find . | sed 's|^\./||; /^\.$/d' | sort | cpio -o -H newc --owner 0:0 --quiet > "$WORK/overlay.cpio" )
( cd "$O" && find . -type f -o -type l | sort ) > "$WORK/manifest.txt"
echo "overlay.cpio $(wc -c < "$WORK/overlay.cpio") bytes"
