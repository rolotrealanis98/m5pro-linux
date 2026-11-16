#!/usr/bin/python3 -I
# Source: betizzel/omarchy-m5 installer/recipes/speakerguardd-v2-upstream/sgv2-telemetry.py @ 1b9d5ef99def
# (MIT, Copyright (c) betizzel and omarchy-m5 contributors), unchanged. Read-only; for the speakerguardd v2
# pin 04169c44. Not run against a J716 engine page.
"""Read-only decoder of speakerguardd v2's engine page (layout 3, bd2b2099; 04169c44 only appends the sense-bind words after the fields read here).
Prints the latest telemetry record per channel: coil/magnet temps, powers,
V/I sense mean squares, gain; plus header health/amps."""
import struct, sys, math, os
TELE = 920; SLOT = 8 + TELE; RING_OFF = 4096; N = 256
CH = 108
def chan(b, o):
    f = struct.unpack_from('<8f', b, o)
    closed, fresh = b[o+32], b[o+33]
    d = struct.unpack_from('<4f', b, o+36)
    axis = struct.unpack_from('<5f', b, o+52)
    band = struct.unpack_from('<5f', b, o+72)
    gain, vms, ims, r = struct.unpack_from('<4f', b, o+92)
    return dict(mod_w=f[0], meas_w=f[1], coil_c=f[2], mag_c=f[3], ol_c=f[4], cl_c=f[5],
                closed=closed, cl_fresh=fresh, gain=gain, v_ms=vms, i_ms=ims, r_ohm=r,
                axis=axis)
def main(path):
    b = open(path, 'rb').read()
    print(f"size={len(b)} expect={RING_OFF+64+N*SLOT}")
    magic, layout, crc, lat, chans, sense, pid = struct.unpack_from('<QIIIIII', b, 0)
    seq, frames, mono = struct.unpack_from('<QQQ', b, 32)
    health, sdel, mg = struct.unpack_from('<IiI', b, 56)
    print(f"magic={magic.to_bytes(8,'little')} layout={layout} crc={crc:08x} channels={chans} sense={sense} pid={pid} seq={seq} frames={frames} health={health:#x} min_gain={struct.unpack('<f',struct.pack('<I',mg))[0]:.4f}")
    head = struct.unpack_from('<Q', b, RING_OFF)[0]
    if head == 0:
        print("no telemetry yet"); return
    i = (head - 1) % N
    o = RING_OFF + 64 + i*SLOT
    sseq, = struct.unpack_from('<Q', b, o)
    frame, h = struct.unpack_from('<QI', b, o+8)
    print(f"record head={head} slot_seq={sseq} frame={frame} health={h:#x}")
    for c in range(min(chans or 8, 8)):
        s = chan(b, o+8+12+c*CH)
        if all(math.isnan(v) for v in (s['coil_c'], s['gain'])): continue
        print(f" ch{c}: coil={s['coil_c']:.2f}C magnet={s['mag_c']:.2f}C cl={s['cl_c']:.2f}C closed={s['closed']} fresh={s['cl_fresh']} "
              f"P_mod={s['mod_w']:.4f}W P_meas={s['meas_w']:.4f}W V2={s['v_ms']:.3g} I2={s['i_ms']:.3g} R={s['r_ohm']:.3f} gain={s['gain']:.4f}")
    g = struct.unpack_from('<10f', b, o+8+12+8*CH)
    print(f" global: P_mod={g[0]:.4f}W P_meas={g[1]:.4f}W thermal_gain_db={g[2]:.2f} power_gain={g[7]:.4f}")
if __name__ == '__main__':
    main(sys.argv[1])
