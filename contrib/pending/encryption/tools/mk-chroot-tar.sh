#!/bin/zsh
# initramfs.cpio.gz -> chroot tarball for scratch/scratch-test.sh. The initramfs is several concatenated newc archives (the
# kernel unpacks all of them; busybox cpio stops at the first TRAILER), so split them and extract in order (later wins).
set -eu
IN=${1:?initramfs.cpio.gz}; OUT=${2:?out.tar.gz}
T=$(mktemp -d /Volumes/m5pro/bench/encryption/split.XXXXXX)
python3 -I -B - "$IN" "$T" <<'PY'
import gzip,sys
d=gzip.open(sys.argv[1]).read(); o=0; n=0; start=0
while o+110<=len(d):
    if d[o:o+6]!=b'070701':
        # zero padding between archives
        o+=1; start=o if d[start:o].strip(b'\0')==b'' else start; continue
    fs=int(d[o+54:o+62],16); ns=int(d[o+94:o+102],16)
    name=d[o+110:o+110+ns-1]
    o=(o+110+ns+3)&~3; o=(o+fs+3)&~3
    if name==b'TRAILER!!!':
        open(f"{sys.argv[2]}/{n:02d}.cpio",'wb').write(d[start:o]); n+=1; start=o
print(n,"archives")
PY
container run --rm -v /Volumes/m5pro:/Volumes/m5pro alpine:3.22 sh -c "apk add --no-cache cpio >/dev/null; mkdir -p /root/x && cd /root/x && for f in $T/*.cpio; do cpio -idmu --quiet < \$f; done; rm -rf dev/*; tar czf $OUT ."
rm -f $T/*.cpio; rmdir $T 2>/dev/null || true
shasum -a 256 $OUT
