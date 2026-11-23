#!/usr/bin/env python3 -I
"""Compare the macOS 27.2 power policy captured on the J716s (hv27-gpu run, policy.bin, 26B123 layout)
with what the kernel sends: J714 controller defaults (+ J716s leakage) laid out for 26B123.
usage: policy-diff.py LINUX_WT CAPTURE_DIR   (CAPTURE_DIR = .../capture/initdata-gfx1-asc-send-1)"""
import re, struct, sys, os
wt, cap = sys.argv[1], sys.argv[2]
src = open(os.path.join(wt, 'drivers/gpu/drm/asahi/g17/fw/m5/initdata.rs')).read()
body = src[src.index('pub(crate) fn encode_m5_policy_controller_defaults(out'):]
body = body[:body.index('/// Initial controller inputs for J716c')]
ini = body[body.index('const INITIAL'):body.index('for &(offset, value) in INITIAL')]
NP = 13 * 100
ours = {}
for m in re.finditer(r'\((0x[0-9a-fA-F_]+|M5_POLICY_MAXIMUM_POWER),\s*([^)]*?)\),', ini):
    off = 0xa18 if m.group(1).startswith('M5_') else int(m.group(1).replace('_', ''), 16)
    v = m.group(2).strip()
    v = NP if 'J714_GPU_NUM_PERF_STATES' in v else int(v.replace('_', ''), 16) if v.startswith('0x') else int(v)
    ours[off] = v
def f32(h):  # halves -> float bits
    import struct as s
    return s.unpack('<I', s.pack('<f', h / 2))[0]
# J716s leakage this part (db578d3d99cc log: clusters 3732/2 3808/2, SRAM 362/2, AFR 992/2 halves)
for i, h in enumerate((3732, 3808)):
    ours[0x121b0 + 4 * i] = f32(h); ours[0x12230 + 4 * i] = f32(362)
ours[0x12280] = f32(992)
bands = [(0x0000,0x4910,0),(0x4910,0x491c,0x10),(0x491c,0x49b8,0x14),(0x49b8,0x4a98,0x18),(0x4a98,0x12668,0x30),(0x12668,0x126b0,0x78)]
def reloc(o):
    for s, e, d in bands:
        if s <= o < e: return o + d
sent = {reloc(o): v for o, v in ours.items()}
sent[0x492c] = 5000; sent[0x4a14] = 1600
sent.pop(reloc(0x49fc), None) if False else None
pol = open(os.path.join(cap, 'policy.bin'), 'rb').read()
mac = {i: struct.unpack_from('<I', pol, i)[0] for i in range(0, len(pol) - 3, 4)}
inv = {}
for s, e, d in bands:
    for o in range(s, e, 4): inv[o + d] = o
def name(o): return '%#x (26A428 %#x)' % (o, inv[o]) if o in inv and inv[o] != o else '%#x' % o
print('# words we send that differ from macOS (ours -> macOS)')
for o in sorted(sent):
    if mac.get(o) != sent[o]:
        print(name(o), '%#x' % sent[o], '->', '%#x' % mac.get(o, -1))
print('# words macOS sets (nonzero) that we leave zero')
cnt = 0
for o in sorted(mac):
    if mac[o] and o not in sent:
        cnt += 1; print(name(o), '%#x' % mac[o])
print('count', cnt, 'of', sum(1 for v in mac.values() if v), 'nonzero')
