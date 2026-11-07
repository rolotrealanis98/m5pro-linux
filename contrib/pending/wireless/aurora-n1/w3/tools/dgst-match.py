#!/usr/bin/env python3
# For each image property in an IM4M, compare its DGST with SHA-384 / SHA-256 / SHA-1 of the FTAB
# entry of the same tag. Prints only tag names and match/mismatch, never a digest.
import hashlib, struct, sys
ftab, im4m = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
n = struct.unpack_from("<I", ftab, 0x28)[0]
ent = {}
for i in range(n):
    tag, o, s, _ = struct.unpack_from("<4sIII", ftab, 0x30 + 16*i)
    ent[tag] = ftab[o:o+s]
# crude: find "\x16\x04TAG" ... "DGST" "\x04\x30<48>" for each image
res = {}
i = 0
while True:
    j = im4m.find(b"DGST", i)
    if j < 0: break
    # tag of the enclosing image: last IA5 len-4 before j that is not DGST
    k = im4m.rfind(b"\x16\x04", 0, j - 2)
    tag = im4m[k+2:k+6]
    o = j + 4
    if im4m[o] != 0x04:
        i = o; continue
    L = im4m[o+1]; dg = im4m[o+2:o+2+L]
    res[tag] = dg
    i = o + 2 + L
ok = bad = 0
for tag, dg in sorted(res.items()):
    data = ent.get(tag)
    if data is None:
        print(f"{tag.decode()}: no FTAB entry"); bad += 1; continue
    m = [h for h in ("sha384", "sha256", "sha1") if hashlib.new(h, data).digest() == dg]
    print(f"{tag.decode()}: {'match ' + m[0] if m else 'MISMATCH'}")
    ok += bool(m); bad += not m
covered = set(res)
print(f"manifest images {len(res)}: {ok} match, {bad} mismatch; FTAB entries not in the manifest: {len(ent) - len(covered & set(ent))}")
