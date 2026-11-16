#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""dryrun-synthetic.py ADT.bin OUTDIR LAYOUT  (LAYOUT = pr | v27.0)

Offline end-to-end check of hv/hv27-gpu-initdata.py with no MacBook: builds a synthetic InitData graph the way the
PR's driver lays it out (LAYOUT pr = 27.3 beta 1 per PR #1173; v27.0 = the 26A428 layout, the negative control),
maps it through synthetic UAT tables at the ADT's TTBAT, runs hv27-trace-late.py and the GPU module in a mock hv
(the real m1n1 DictRangeMap/TraceMode, the real J716s ADT), fires the SPTM AMCC hook, replays the RTKit words of a
GPU bring-up through the module's SYNC callbacks, and leaves the dump in OUTDIR/capture.
The synthetic values are made up; only their positions follow the PR (or 27.0) layout.
Run with the venv python and PYTHONPATH=<m1n1>/proxyclient."""
import os, runpy, struct, sys, types
from m1n1.adt import load_adt
from m1n1.utils import DictRangeMap, BoolRangeMap, irange
from m1n1.hv import TraceMode

ADT, OUT, LAYOUT = sys.argv[1], sys.argv[2], sys.argv[3]
HERE = os.path.dirname(os.path.abspath(__file__))
HV = HERE if os.path.exists(os.path.join(HERE, "hv27-gpu-initdata.py")) else os.path.join(HERE, "..", "hv")
sys.path.insert(0, HERE)
cmp = runpy.run_path(os.path.join(HERE, "initdata-compare.py"), run_name="cmp")
V = cmp["DEFAULTS"]
T = V["ABI_ALLOCATION_SIZES_26B123_M5"] if LAYOUT == "pr" else V["ABI_ALLOCATION_SIZES_26A428_M5"]
SH, PV = cmp["layouts"](T)
reloc = cmp["relocate"]
new = LAYOUT == "pr"


class Mem:
    def __init__(self):
        self.pages = {}

    def w(self, pa, data):
        for i, b in enumerate(data):
            pg = (pa + i) & ~0x3fff
            self.pages.setdefault(pg, bytearray(0x4000))[(pa + i) & 0x3fff] = b

    def r(self, pa, n):
        out = bytearray()
        for i in range(n):
            pg = self.pages.get((pa + i) & ~0x3fff)
            out.append(pg[(pa + i) & 0x3fff] if pg else 0)
        return bytes(out)


mem = Mem()
adt = load_adt(open(ADT, "rb").read())
TTBAT = adt["/arm-io/sgx"].gpu_region_base

# ---------------------------------------------------------------- synthetic objects (VA -> bytes)
BASE = 0xffff_fe10_0000_0000
BUNDLE, PRIVATE, ROOTS = BASE + 0x1000_0000, BASE + 0x2000_0000, BASE + 0x3000_0000
REGION_A, REGION_C, MISC = BASE + 0x3010_0000, BASE + 0x3020_0000, BASE + 0x3030_0000
objs = {}


def obj(va, size):
    objs[va] = bytearray(size)
    return objs[va]


p32 = lambda b, o, v: struct.pack_into("<I", b, o, v)
p64 = lambda b, o, v: struct.pack_into("<Q", b, o, v)
hb = V["M5_26C5035_HW_DATA_BANDS"]
hwo = (lambda o: reloc(hb, o)) if new else (lambda o: o)
hw = obj(BUNDLE + SH["hw"], T[0])
p32(hw, 0xfb0, 0x6050)
p32(hw, 0x271c, 0x96)
p32(hw, 0x10d4, 0x18); p32(hw, 0x10d8, 0x11); p32(hw, 0x10dc, 20)
for i in range(13):
    p32(hw, 0x10e4 + 4 * i, 400 + 100 * i)                       # made-up perf table
ct = hwo(0x273c)
for i in range(4):
    p64(hw, ct + 0x20 * i, 0x70_0184_8000 + i * 0x20000); p64(hw, ct + 0x20 * i + 8, MISC + i * 0x20000)
    p32(hw, ct + 0x20 * i + 0x10, 0x800); p32(hw, ct + 0x20 * i + 0x14, 0x40); p32(hw, ct + 0x20 * i + 0x18, i)
p64(hw, hwo(0x27d4), MISC + 0x10_0000)
p64(hw, hwo(0x27dc), MISC + 0x18_0000)
p32(hw, hwo(0x2842), 1); p32(hw, hwo(0x2846), 1)
if new:
    p32(hw, 0x2720, 5000)
for k, sz in (("view0", T[1]), ("view1", T[2]), ("view2", T[3]), ("view3", T[5]), ("view4", T[6])):
    v = obj(BUNDLE + SH[k], sz); v[0:4] = b"\x01\x02\x03\x04"
pb = V["M5_26B123_POLICY_BANDS"]
po = (lambda o: reloc(pb, o)) if new else (lambda o: o)
pol = obj(BUNDLE + SH["policy"], T[4])
p32(pol, 0xa18, 30000)
p64(pol, po(0x8254), PRIVATE + PV["policy_state"])
p64(pol, po(0x11a1c), MISC + 0x20_0000)
for i in range(40 if new else 37):
    pol[po(0x122f0) + 24 * i: po(0x122f0) + 24 * i + 4] = struct.pack("<I", 100 + i)
p32(pol, po(0x12668), 7)
if new:
    for o, v in ((0x4920, 3500), (0x4924, 1000), (0x4928, 3000), (0x492c, 5000), (0x4a14, 1600)):
        p32(pol, o, v)
else:
    for o, v in ((0x4910, 3500), (0x4914, 1000), (0x4918, 3000), (0x49fc, 500)):
        p32(pol, o, v)
obj(PRIVATE + PV["status_b"], T[12])[0] = 1
sc = obj(PRIVATE + PV["status_config"], T[13])
stride = 0x64 if new else 0x5c
for blk in (0x5b4, 0x5b4 + stride):
    for o, v in ((0, 1), (4, 2), (0x10, 3), (0x20, 4), (0x30, 5)):
        p32(sc, blk + o, v)
if new:
    p32(sc, 0x60c, 5000)
sb = V["M5_26B123_STATUS_CONFIG_BANDS"]
so = (lambda o: reloc(sb, o)) if new else (lambda o: o)
p32(sc, so(0x774), 1); p64(sc, so(0x778), MISC + 0x28_0000)
p64(sc, so(0x73c), 16); p64(sc, so(0x73c) + 8, 8)
for k in ("status_a0", "status_a1", "sx1", "policy_state"):
    obj(PRIVATE + PV[k], 0x40)[0] = 2
obj(REGION_A, 0x4000)[0] = 3
obj(REGION_C, T[22])[0] = 4
mains = []
for i in range(2):
    m = obj(BUNDLE + SH[f"main{i}"], 0x600)
    p64(m, 0, BUNDLE)
    if i == 0:
        for j, k in enumerate(("view0", "view1", "view2", "view3", "view4")):
            p64(m, 0x254 + 8 * j, BUNDLE + SH[k])
    else:
        struct.pack_into("<Q", m, 0x481, BUNDLE + SH["policy"])
    mains.append(BUNDLE + SH[f"main{i}"])
roots = []
for i in range(2):
    r = obj(ROOTS + 0x8000 * i, 0xc8)
    p64(r, 0, V["M5_26B123_INITDATA_VERSION_WORD"] if new else V["M5_INITDATA_VERSION_WORD"])
    p64(r, 0x08, REGION_A); p64(r, 0x18, mains[i]); p64(r, 0x20, REGION_C); p32(r, 0x28, i); p32(r, 0x2c, 1)
    struct.pack_into("<HBB", r, 0x30, 0x4000, 14, 3)
    p64(r, 0xa8, PRIVATE + PV[f"status_a{i}"])
    if i == 0:
        p64(r, 0xb0, PRIVATE + PV["status_b"])
    else:
        p64(r, 0xb8, PRIVATE + PV["status_config"]); p64(r, 0xc0, PRIVATE + PV["sx1"])
    roots.append(ROOTS + 0x8000 * i)

# ---------------------------------------------------------------- UAT: TTBAT ctx0 TTBR1 -> L1 (64) -> L2 -> L3
next_pa = [0x10_9000_0000]


def alloc():
    pa = next_pa[0]; next_pa[0] += 0x4000; return pa


L1 = alloc()
mem.w(TTBAT + 8, struct.pack("<Q", L1 | 1))
tables = {}


def map_page(va, pa):
    t = L1
    for shift, bits in ((36, 6), (25, 11)):
        idx = (va >> shift) & ((1 << bits) - 1)
        key = (t, idx)
        if key not in tables:
            tables[key] = alloc()
            mem.w(t + 8 * idx, struct.pack("<Q", tables[key] | 3))
        t = tables[key]
    mem.w(t + 8 * ((va >> 14) & 0x7ff), struct.pack("<Q", pa | 0x403))


mapped = {}
for va, data in sorted(objs.items()):
    for off in range(0, len(data) + (va & 0x3fff), 0x4000):
        pg = (va & ~0x3fff) + off
        if pg not in mapped:
            mapped[pg] = alloc() + 0x10_0000          # non-contiguous PAs
            map_page(pg, mapped[pg])
for va, data in objs.items():
    for i in range(0, len(data)):
        pass
    done = 0
    while done < len(data):
        cur = va + done
        k = min(len(data) - done, 0x4000 - (cur & 0x3fff))
        mem.w(mapped[cur & ~0x3fff] + (cur & 0x3fff), data[done:done + k])
        done += k

# ---------------------------------------------------------------- mock hv
class AMCC:
    registers = {0x200000000 + 4 * i: None for i in range(4)}

    def read(self, addr, width=None):
        return 0

    def write(self, addr, data, width=None):
        pass


hv = types.SimpleNamespace()
hv.adt = adt
hv.mmio_maps = DictRangeMap()
hv.dirty_maps = BoolRangeMap()
hv.ctx = object()
hv.iface = types.SimpleNamespace(readmem=mem.r)
hv.sptm_amcc = AMCC()


def add_tracer(zone, ident, mode=TraceMode.ASYNC, read=None, write=None, **kw):
    hv.mmio_maps[zone, ident] = (mode, ident, read, write, kw)
    hv.dirty_maps.set(zone)


def trace_range(zone, mode=TraceMode.ASYNC, read=True, write=True, name=None):
    add_tracer(zone, "PrintTracer", mode, print, print)


hv.add_tracer, hv.trace_range = add_tracer, trace_range
for a in hv.sptm_amcc.registers:
    add_tracer(irange(a, 4), "SPTM AMCC", TraceMode.HOOK, read=hv.sptm_amcc.read, write=hv.sptm_amcc.write)

os.environ["HV27_GPU_OUT"] = os.path.join(OUT, "capture")
os.environ["HV27_TRACE"] = ""
g = {"hv": hv}
g.update(runpy.run_path(os.path.join(HV, "hv27-trace-late.py"), init_globals=g, run_name="<hv_script>"))
g.update(runpy.run_path(os.path.join(HV, "hv27-gpu-initdata.py"), init_globals=g, run_name="<hv_script>"))

# SPTM's first AMCC read: the HOOK path calls read(addr, 8 << width)
a0 = next(iter(hv.sptm_amcc.registers))
mode, ident, rd, wr, kw = hv.mmio_maps[(a0, "SPTM AMCC")]
rd(a0, 32)
assert all(rd2 for rd2 in [hv.mmio_maps[(0x2302608800, "GPUINIT.gfx-asc")], hv.mmio_maps[(0x2302e08800, "GPUINIT.gfx1-asc")]]), "tracers not installed"


def ev(base, off, write, data):
    m = hv.mmio_maps[(base + off, f"GPUINIT.{'gfx-asc' if base == 0x2302608000 else 'gfx1-asc'}")]
    fn = m[3] if write else m[2]
    fn(types.SimpleNamespace(addr=base + off, data=data, flags=types.SimpleNamespace(WIDTH=3, WRITE=int(write))))


def send(base, ep, m0):      # stp x0, x1 -> [+0x800, +0x808]
    ev(base, 0x800, True, m0); ev(base, 0x808, True, ep)


def recv(base, ep, m0):      # ldp -> [+0x830, +0x838]
    ev(base, 0x830, False, m0); ev(base, 0x838, False, ep | (1 << 52))


for base, root in ((0x2302608000, roots[0]), (0x2302e08000, roots[1])):
    send(base, 0, (6 << 52) | 0x220)                          # SET_IOP_PWR
    recv(base, 0, (1 << 52) | 0x000c000c)                     # HELLO v12
    send(base, 0, (2 << 52) | 0x000c000c)                     # HELLO_ACK
    send(base, 0, (5 << 52) | (0x20 << 32) | 2)               # STARTEP 0x20
    send(base, 0x20, (0x81 << 48) | (root & ((1 << 44) - 1)))  # INITDATA
    recv(base, 0x20, (0x09 << 48))                            # INITDATA_ACK
    recv(base, 0x20, (0x42 << 48))                            # EVENTS
g["gpu_status"]()
g["_gpuinit"].summary()

# panel screenshot helper against a small synthetic 30-bit framebuffer
FB = 0x10_a000_0000
mem.w(FB, b"".join(struct.pack("<I", ((x * 4) << 22) | ((y * 4) << 12)) for y in range(64) for x in range(64)))
hv.u = types.SimpleNamespace(ba=types.SimpleNamespace(video=types.SimpleNamespace(base=FB, width=64, height=64, stride=256, depth=30)))
png = g["gpu_shot"]("dryrun")
assert open(png, "rb").read(8) == b"\x89PNG\r\n\x1a\n"
