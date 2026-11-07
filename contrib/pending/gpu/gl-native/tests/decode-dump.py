#!/usr/bin/env python3
"""Decode the command buffers of an ASAHI_SHIM_DUMP_SUBMIT file: headers,
program storage records, and the main render/compute fields."""
import struct, sys
NAMES = {0:'RENDER',1:'COMPUTE',2:'SET_VERTEX_ATT',3:'SET_FRAGMENT_ATT',4:'SET_COMPUTE_ATT',
         5:'SET_RENDER_RES',6:'SET_COMPUTE_RES',7:'SET_RENDER_RES_V2'}
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 6
n = 0
for line in open(sys.argv[1]):
    if line.startswith('SUBMIT'):
        print(line.strip()); n += 1
        if n > limit: break
    if not line.startswith('CMDBUF'): continue
    b = bytes.fromhex(line.split()[1])
    at = 0
    while at + 8 <= len(b):
        t, size, vb, cb = struct.unpack_from('<HHHH', b, at); at += 8
        p = b[at:at+size]; at += size
        print(f'  {NAMES.get(t,t)} size={size} vdm_barrier={vb:#x} cdm_barrier={cb:#x}')
        if t in (5,7):
            stride = 40 if t == 5 else 104
            for i in range(0, size, stride):
                f = struct.unpack_from('<10I', p, i)
                print('    stage=%d primary=%d secondary=%d linked=%d min=%d aux=%d tg=%d ib=%d ms=%d flags=%d' % f)
        elif t == 6:
            for i in range(0, size, 28):
                print('    primary=%d secondary=%d linked=%d min=%d tg=%d threads=%d flags=%d' % struct.unpack_from('<7I', p, i))
        elif t == 0:
            flags, = struct.unpack_from('<I', p, 0)
            print(f'    flags={flags:#x} payload={size}B')
        elif t == 1:
            base, end = struct.unpack_from('<QQ', p, 8)
            print(f'    stream {base:#x}..{end:#x} ({end-base} B)')
