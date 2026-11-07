#!/usr/bin/env python3
"""Check the T6050 native ASCWrap v6 role table in drivers/soc/apple/mailbox.c against the ADT
gfx-asc/gfx1-asc nodes (role, compatible, reg[0] wrapper 0x88000, reg[1] start + >= 8 bytes)."""
import os, re, sys
sys.path.insert(0, os.environ.get("M1N1_PROXYCLIENT", os.path.expanduser("~/Work/m1n1/proxyclient")))
from m1n1.adt import load_adt
src = open(sys.argv[1]).read()
adt = load_adt(open(sys.argv[2], "rb").read())
d = {k: int(v, 16) for k, v in re.findall(r"#define (APPLE_T6050_GFX1?_\w+_BASE) (0x[0-9a-f]+)ULL", src)}
ok = True
for node, role, pre in (("gfx-asc", "GFX", "APPLE_T6050_GFX_"), ("gfx1-asc", "GFX1", "APPLE_T6050_GFX1_")):
    n = adt["/arm-io/" + node]
    w, ws = n.get_reg(0); v, vs = n.get_reg(1)
    good = (n.role == role and list(n.compatible) == ["iop,ascwrap-v6"] and ws == 0x88000 and vs >= 8
            and d[pre + "WRAPPER_BASE"] == w and d[pre + "IOP_VBAR_BASE"] == v
            and re.search(r'\{ "%s", APPLE_MBOX_ASCWRAP_V6_ROLE_%s,\s*%sWRAPPER_BASE, %sIOP_VBAR_BASE \}' % (role, role, pre, pre), src))
    ok &= bool(good)
    print(f"{'ok  ' if good else 'FAIL'} {node} role {n.role}: wrapper {w:#x}+{ws:#x} vbar {v:#x}+{vs:#x} "
          f"table {d[pre + 'WRAPPER_BASE']:#x}/{d[pre + 'IOP_VBAR_BASE']:#x}")
good = '"apple,t6050-native-ascwrap-v6"' in src
print(("ok   " if good else "FAIL ") + "compatible apple,t6050-native-ascwrap-v6 matched")
sys.exit(0 if ok and good else 1)
