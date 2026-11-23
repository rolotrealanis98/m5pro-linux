#!/bin/sh
# Inside Alpine 3.22: stage the QEMU test kernel (Alpine linux-virt, dm-crypt/AF_ALG as modules) and the extra overlay tree.
# usage: stage-in-container.sh OUTDIR SRCDIR      -> OUTDIR/Image, OUTDIR/extra.cpio
set -eu
OUT=$1; SRC=$2
apk add --no-cache linux-virt e2fsprogs busybox-static cpio kmod python3 >/dev/null
R=$(ls /lib/modules | head -1); mkdir -p "$OUT"
python3 - "$R" "$OUT/Image" <<'PY'
import sys,zlib
rel,out=sys.argv[1:3]
d=open('/boot/vmlinuz-virt','rb').read()
i=d.find(b'\x1f\x8b\x08')
while i>=0:
    try:
        img=zlib.decompressobj(31).decompress(d[i:])
        if img[56:60]==b'ARM\x64': open(out,'wb').write(img); sys.exit(0)
    except Exception: pass
    i=d.find(b'\x1f\x8b\x08',i+1)
sys.exit("no arm64 Image inside vmlinuz-virt")
PY
E=$OUT/extra; rm -rf "$E"; mkdir -p "$E/lib/modules/qemu" "$E/sbin" "$E/bin"
: > "$E/lib/modules/qemu/load-order.txt"; n=0
for m in loop virtio_blk dm-crypt algif_aead algif_skcipher algif_hash ccm ext4; do
    modprobe -d / -S "$R" --show-depends $m 2>/dev/null | sed -n 's/^insmod \/*//p' | while read -r f; do
        b=$(basename "$f" .gz); [ -f "$E/lib/modules/qemu/$b" ] || { zcat "/$f" > "$E/lib/modules/qemu/$b"; echo "$b" >> "$E/lib/modules/qemu/load-order.txt"; }
    done
done
cat "$E/lib/modules/qemu/load-order.txt" | tr '\n' ' '; echo
install -m 755 /sbin/mke2fs "$E/sbin/mke2fs"; install -m 755 /bin/busybox.static "$E/bin/busybox.static"
install -m 755 "$SRC/guest-prep.sh" "$E/qemu-guest"; install -m 755 "$SRC/root-init.sh" "$E/qemu-root-init"
( cd "$E" && find . | sed 's|^\./||; /^\.$/d' | sort | cpio -o -H newc --owner 0:0 --quiet > "$OUT/extra.cpio" )
echo "extra.cpio $(wc -c < "$OUT/extra.cpio") kernel $R"
