#!/bin/bash
# Regression for mk-stage1.py against the stage-1 that boots the J716s untethered today:
# ~/Work/stage1-serve/chain-esp-small.bin = m1n1-linuxbuild/m1n1-chain.bin (0x420000, 14 patches)
# + "chainload=<ESP PARTUUID>;m1n1/boot.bin\n" + 00000000 + pad to 0x430000
# (m5pro-linux docs/boot-and-recovery.md:174-181). Read-only on those files.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
REF=${STAGE1_REF:-$HOME/Work/stage1-serve/chain-esp-small.bin}
# The bare m1n1 is taken from the reference itself (everything up to the STACKBOT marker), because
# ~/Work/m1n1-linuxbuild is rebuilt in place and no longer holds the exact bytes that were installed.
SRC=${M1N1_CHAIN:-$T/m1n1-chain-from-ref.bin}
[ -n "${M1N1_CHAIN:-}" ] || python3 -I -c 'import sys; b=open(sys.argv[1],"rb").read(); open(sys.argv[2],"wb").write(b[:b.index(b"STACKBOT")+8])' "$REF" "$SRC"
PLAIN=${M1N1_PLAIN:-$HOME/Work/m1n1-linuxbuild/m1n1-plain.bin}
UUID=<ESP PARTUUID>
py() { python3 -I "$here/mk-stage1.py" "$@"; }

echo "== 1. byte-identical rebuild of the installed stage-1"
py stage1 --m1n1 "$SRC" --esp-partuuid "$UUID" --no-efi-var -o "$T/s1.bin"
cmp "$T/s1.bin" "$REF" || { echo "   DIFFERS from $REF"; exit 1; }
echo "   identical to $(basename "$REF")"

echo "== 2. with the ESP chosen variable (proposed default)"
py stage1 --m1n1 "$SRC" --esp-partuuid "$(echo $UUID | tr a-f A-F)" -o "$T/s1e.bin"
py inspect "$T/s1e.bin"

echo "== 3. ESP-resident stage-1.5: no terminator, no padding"
py esp --m1n1 "$SRC" --esp-partuuid "$UUID" --path m1n1/slot-a.bin -o "$T/s15.bin"
py inspect "$T/s15.bin"

echo "== 4. refusals"
for args in "--m1n1 $PLAIN --esp-partuuid $UUID" \
            "--m1n1 $T/s1.bin --esp-partuuid $UUID" \
            "--m1n1 $SRC --esp-partuuid not-a-uuid" \
            "--m1n1 $SRC --esp-partuuid $UUID --path /abs/boot.bin" \
            "--m1n1 $SRC --esp-partuuid $UUID --var bogus=1"; do
    if py stage1 $args -o "$T/x.bin" 2>"$T/err"; then echo "   NOT refused: $args"; exit 1; fi
    echo "   refused: $(tail -1 "$T/err")"
done
echo "== 5. plain rescue/proxy object (no chainload=) is allowed explicitly"
py stage1 --m1n1 "$PLAIN" --allow-plain -o "$T/plain.bin" && py inspect "$T/plain.bin"
echo "OK"
