#!/usr/bin/env python3
# Print the structure of an IM4M (or IMG4) DER blob: manifest body property names, value types and
# lengths. Integer/boolean values are printed only for a short allowlist of non-identifying keys;
# octet strings (digests, nonces) are never printed, only their length. ECID presence is reported
# as present/absent, never its value.
import sys
SHOW = {b"CHIP", b"BORD", b"CPRO", b"CSEC", b"SDOM", b"EPRO", b"ESEC", b"Ap,i", b"love"}
def tlv(b, i):
    t = b[i]; i += 1
    if t & 0x1f == 0x1f:  # high tag number (private tags like 'MANP')
        tag = 0
        while True:
            c = b[i]; i += 1; tag = (tag << 7) | (c & 0x7f)
            if not c & 0x80: break
        t = (t, tag)
    L = b[i]; i += 1
    if L & 0x80:
        n = L & 0x7f; L = int.from_bytes(b[i:i+n], "big"); i += n
    return t, i, L
def name(t):
    if isinstance(t, tuple):
        v = t[1]; return v.to_bytes((v.bit_length()+7)//8, "big")
    return None
def walk(b, i, end, depth, out):
    while i < end:
        t, vi, L = tlv(b, i)
        nm = name(t); cls = t[0] if isinstance(t, tuple) else t
        cons = bool(cls & 0x20)
        ind = "  " * depth
        if nm is not None:
            out.append(f"{ind}[{nm.decode('latin1')}] len {L}")
        elif cls in (0x30, 0x31):
            out.append(f"{ind}{'SEQ' if cls==0x30 else 'SET'} len {L}")
        elif cls == 0x16:
            out.append(f"{ind}IA5 {b[vi:vi+L].decode('latin1')!r}")
        elif cls == 0x02:
            out.append(f"{ind}INT len {L}" + (f" = {int.from_bytes(b[vi:vi+L],'big'):#x}" if depth and out_ctx[-1:] and out_ctx[-1] in SHOW else ""))
        elif cls == 0x01:
            out.append(f"{ind}BOOL" + (f" = {b[vi]!=0}" if out_ctx[-1:] and out_ctx[-1] in SHOW|{b"uidm",b"EKEY"} else ""))
        elif cls == 0x04:
            out.append(f"{ind}OCTETS len {L}")
        elif cls == 0xa0 or cls == 0xa1:
            out.append(f"{ind}[ctx {cls-0xa0}] len {L}")
        else:
            out.append(f"{ind}tag {cls:#x} len {L}")
        if nm is not None: out_ctx.append(nm)
        if cons and depth < 14 and not (nm is None and cls == 0x04):
            # stop descending into the certificate chain (an OCTET STRING at top level)
            walk(b, vi, vi+L, depth+1, out)
        if nm is not None: out_ctx.pop()
        i = vi + L
out_ctx = []
for p in sys.argv[1:]:
    b = open(p, "rb").read()
    out = []
    walk(b, 0, len(b), 0, out)
    keys = [l.strip() for l in out if l.strip().startswith("[")]
    print(f"== {p.rsplit('/',1)[-1]}  size {len(b)}  ECID {'present' if '[ECID] len' in ' '.join(keys) else 'absent'}  BNCH {'present' if any(k.startswith('[BNCH]') for k in keys) else 'absent'}")
    print("\n".join(out))
