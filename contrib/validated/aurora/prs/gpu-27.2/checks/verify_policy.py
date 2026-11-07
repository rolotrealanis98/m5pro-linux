#!/usr/bin/env python3
"""Check the M5 power-policy relayout 26A428 (macOS 27.0) -> 26B123 (27.2, = 27.3 beta 1).

  verify_policy.py [initdata.rs] [workdir]

initdata.rs: drivers/gpu/drm/asahi/g17/fw/m5/initdata.rs of the patched tree
workdir:     a directory with the kext store lists (pol-*.txt) and the GFX1
             firmware policy access lists (fu7*.txt) (default: work/ next to this script).

1. The band table, as ANALYSIS.md gives it, must equal the one in the driver source.
2. Every 27.0 kext policy store, relocated by the bands, must be a 27.2 store; 27.2 stores no
   27.0 store explains are printed (expected: 0x492c only). Same for 27.3.
3. Same for the GFX1 firmware's policy accesses (27.0 -> 27.2 and 27.3).
4. The driver's own policy words: the 26A428 encoders (bundle policy + each board's controller
   defaults) are compiled out of the driver source with rustc and run; then the driver's
   relayout_m5_policy() lays the result out for 26B123. Every non-zero 27.0 byte must land at its
   relocated offset, nothing may land in an insert, and the only other words are the controller
   words. The 26A428 path must leave the policy byte-identical. Relocated words are matched
   against the 27.2 kext stores and firmware accesses.
Needs python3 and rustc only.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1]
WORK = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'work')
OUT = os.path.join(WORK, 'verify-rs')

SIZE_70, SIZE_72 = 0x126b0, 0x12728
# ANALYSIS.md: 27.0 range -> shift.
BANDS = [(0x0000, 0x4910, 0), (0x4910, 0x491c, 0x10), (0x491c, 0x49b8, 0x14),
         (0x49b8, 0x4a98, 0x18), (0x4a98, 0x12668, 0x30), (0x12668, 0x126b0, 0x78)]
# Inserted 27.2 ranges and the ranges where an insert sits somewhere unmeasured (nothing
# touches them in either build).
INSERTS = [(0x4910, 0x4920, 'fw time accumulators'), (0x492c, 0x4930, 'threshold 5000'),
           (0x4960, 0x49d0, '4 bytes, placement free'), (0x4a18, 0x4ac8, '0x18 bytes, placement free'),
           (0x12698, 0x126e0, '3 residency entries')]
EXPECTED_NEW_KEXT = {0x492c}


def reloc(o):
    for s, e, d in BANDS:
        if s <= o < e:
            return o + d
    return None


def target_covered(t):
    return any(s + d <= t < e + d for s, e, d in BANDS)


def width(op, reg):
    n = {'w': 4, 's': 4, 'x': 8, 'd': 8, 'q': 16}.get(reg[0], 4)
    if reg in ('wzr', 'xzr'):
        n = 4 if reg == 'wzr' else 8
    if op == 'strb':
        n = 1
    elif op == 'strh':
        n = 2
    return n * (2 if op == 'stp' else 1)


def load_stores(path):
    st = {}
    for line in open(path):
        f = line.split()
        o = int(f[0], 16)
        acc = [x.split(':') for x in f[1:]]
        st[o] = max(width(op, reg) for _, op, reg in acc), sorted({op + ':' + reg for _, op, reg in acc})
    return st


def load_fw(path):
    fw = {}
    for line in open(path):
        f = line.split()
        fw[int(f[0], 16)] = int(f[2])
    return fw


def section(title):
    print('\n== ' + title)


ok = True

# 1. Band table equality.
section('1. band table: ANALYSIS.md vs driver source')
src = open(SRC).read()
m = re.search(r'pub\(crate\) const M5_26B123_POLICY_BANDS: &\[LayoutBand\] = &\[(.*?)\];', src, re.S)
drv = []
for a, b, d in re.findall(r'band\((0x[0-9a-f]+), (0x[0-9a-f]+|M5_POLICY_SIZE), (0x[0-9a-f]+|0),', m.group(1)):
    drv.append((int(a, 16), SIZE_70 if b == 'M5_POLICY_SIZE' else int(b, 16), int(d, 16)))
print('driver:', ', '.join(f'[{s:#x},{e:#x}) {d:+#x}' for s, e, d in drv))
if drv != BANDS:
    ok = False
    print('MISMATCH with ANALYSIS.md')
else:
    print('equal; end', hex(BANDS[-1][1] + BANDS[-1][2]),
          'size const', (re.search(r'M5_26B123_POLICY_SIZE: usize = (0x[0-9a-f]+)', src) and
                         re.search(r'M5_26B123_POLICY_SIZE: usize = (0x[0-9a-f]+)', src).group(1)) or
          # Integration: the size is entry 4 (ALLOC_POLICY) of A's 26B123 allocation size table.
          re.findall(r'0x[0-9a-f]+', re.search(r'ABI_ALLOCATION_SIZES_26B123_M5: \[usize; 24\] = \[([^\]]*)\]',
                                               src).group(1))[4])

# 2. Kext stores.
k70 = load_stores(os.path.join(WORK, 'pol-27.0-26A428.txt'))
for name, f in (('27.2 (26B123)', 'pol-27.2-26B123.txt'), ('27.3 (26C5035r)', 'pol-27.3.txt')):
    section(f'2. kext policy stores 27.0 -> {name}')
    k72 = load_stores(os.path.join(WORK, f))
    mapped = {}
    for o, (w, ops) in k70.items():
        t = reloc(o)
        if t is None or reloc(o + w - 1) != t + w - 1:
            print(f'  27.0 store {o:#x} (+{w}) crosses a band edge or the end')
            ok = False
        mapped[t] = o
    miss = sorted(t for t in mapped if t not in k72)
    new = sorted(t for t in k72 if t not in mapped)
    kind = [t for t in mapped if t in k72 and k70[mapped[t]][1] != k72[t][1]]
    print(f'  27.0 stores {len(k70)}, {name} stores {len(k72)}; relocated and found: '
          f'{len(mapped) - len(miss)}')
    print('  relocated 27.0 stores missing in', name + ':', [hex(x) for x in miss] or 'none')
    print('  unexplained', name, 'stores:', [f'{x:#x} {k72[x][1]}' for x in new] or 'none')
    print('  same offset, other instruction form:', len(kind),
          [f'{mapped[t]:#x}->{t:#x} {k70[mapped[t]][1]}->{k72[t][1]}' for t in sorted(kind)][:6])
    if miss or set(new) != EXPECTED_NEW_KEXT:
        ok = False
    in_insert = [t for t in k72 if not target_covered(t) and t not in EXPECTED_NEW_KEXT]
    if in_insert:
        ok = False
        print('  stores inside an insert:', [hex(x) for x in in_insert])
    if name.startswith('27.2'):
        k72_2 = k72

# 3. Firmware accesses.
f70 = load_fw(os.path.join(WORK, 'fu70.txt'))
# The two new u64 accumulators (27.2 armfw1 0xf598..0xf5b0, 0x302ec..0x30304).
FW_INSERTS = {0x4910: 'u64 accumulator', 0x4918: 'u64 accumulator'}
# 27.2 armfw1 0x2e1f8..0x2e260 (x20 = policy + 0x4bd4): a u64 at 0x94e4, two 16-byte arrays at
# 0x9504/0x9524 and their maximum at 0x9544, all cleared after use. In 27.0 the same computation
# (0x2e0dc..0x2e148) kept them in another object (x4 +0x8c8, +0x7f8, +0x818, +0x838). Their
# 27.0 source range must be untouched by the 27.0 kext, firmware and driver (checked below).
MOVED_IN = (0x94e4, 0x954c)
# Read through x26 = policy + 0x122a0 (27.0, set at 0x2bae8) / + 0x122d0 (27.2, 0x2bc18) at
# +0x14/+0x1c (27.0 0x2dd34/0x2dd44, 27.2 0x2de50/0x2de60); fwtrack lists them for 27.2 only.
X26_27_0 = {0x122e4: 0x122b4, 0x122ec: 0x122bc}


def dis_has(path, addr, text):
    for line in open(path):
        if line.startswith(addr):
            return text in line
    return False


for path, addr, text in (('fw170.dis', 'fffffc000002bae8', 'add\tx26, x10, #0x2a0'),
                         ('fw172.dis', 'fffffc000002bc18', 'add\tx26, x10, #0x2d0'),
                         ('fw170.dis', 'fffffc000002dd34', 'ldur\tx8, [x26, #0x1c]'),
                         ('fw170.dis', 'fffffc000002dd44', 'ldur\tx9, [x26, #0x14]'),
                         ('fw172.dis', 'fffffc000002de50', 'ldur\tx8, [x26, #0x1c]'),
                         ('fw172.dis', 'fffffc000002de60', 'ldur\tx9, [x26, #0x14]'),
                         ('fw172.dis', 'fffffc000002e1f8', 'ldr\tx8, [x20, #0x4910]'),
                         ('fw172.dis', 'fffffc000002e260', 'str\txzr, [x20, #0x4910]'),
                         ('fw170.dis', 'fffffc000002e0e0', 'ldr\tx10, [x4, #0x8c8]')):
    if not dis_has(os.path.join(WORK, path), addr, text):
        ok = False
        print('  disassembly check failed:', path, addr, text)
src_lo, src_hi = MOVED_IN[0] - 0x30, MOVED_IN[1] - 0x30
for name, f in (('27.2', 'fu72.txt'), ('27.3', 'fu73.txt')):
    section(f'3. GFX1 firmware policy accesses 27.0 -> {name}')
    f72 = load_fw(os.path.join(WORK, f))
    mapped = {reloc(o): o for o in f70}
    if None in mapped:
        ok = False
        print('  27.0 access outside the policy:', hex(mapped[None]))
    miss = sorted(t for t in mapped if t is not None and t not in f72)
    new = sorted(t for t in f72 if t not in mapped)
    print(f'  27.0 offsets {len(f70)}, {name} offsets {len(f72)}')
    print('  relocated 27.0 accesses missing in', name + ':', [hex(x) for x in miss] or 'none')
    explained = {}
    for x in new:
        if x in FW_INSERTS:
            explained[x] = 'insert: ' + FW_INSERTS[x]
        elif MOVED_IN[0] <= x < MOVED_IN[1]:
            explained[x] = 'firmware field in 27.0-unused space'
        elif x in X26_27_0:
            explained[x] = f'27.0 {X26_27_0[x]:#x} via x26, missed by the 27.0 tracker'
    for x in new:
        if x in explained:
            print(f'  new {x:#x}: {explained[x]}')
    rest = [hex(x) for x in new if x not in explained]
    print('  unexplained', name, 'accesses:', rest or 'none')
    if miss or rest:
        ok = False
    if name == '27.2':
        f72_2 = f72

for c, t in ((0x8254, 0x8284), (0x11a1c, 0x11a4c)):
    print(f'  pointer {c:#x} -> {reloc(c):#x}: kext 27.0 {c in k70} 27.2 {t in k72_2}; '
          f'fw 27.0 {c in f70} 27.2 {t in f72_2}')
    ok &= reloc(c) == t and t in k72_2 and (c in f70) == (t in f72_2)

# 4. The driver's words through the driver's own relayout.
section("4. driver policy words, encoded and laid out by the driver's own code (rustc)")


def item(pat):
    mm = re.search(r'^(#\[derive[^\n]*\n)?' + pat, src, re.M)
    if not mm:
        sys.exit('missing ' + pat)
    i, depth, assigned = mm.start(), 0, False
    while True:
        c = src[i]
        if c == '=' and depth == 0 and src[i + 1] != '>':
            assigned = True
        elif c in '{[(':
            depth += 1
        elif c in '}])':
            depth -= 1
            if depth == 0 and not assigned and c == '}':
                return src[mm.start():i + 1]
        elif c == ';' and depth == 0:
            return src[mm.start():i + 1]
        i += 1


ITEMS = [
    r'pub\(crate\) enum Evidence', r'pub\(crate\) struct LayoutBand', r'const fn band\(',
    r'pub\(crate\) const fn relocate_by_bands', r'pub\(crate\) enum InitdataError',
    r'fn put_u16', r'fn put_u32', r'fn put_u64', r'pub\(crate\) struct M5PolicyBindings',
    r'pub\(crate\) const ABI_ALLOCATION_SIZES_26A428_M5', r'pub\(crate\) const ALLOC_POLICY:',
    r'pub\(crate\) const ABI_ALLOCATION_SIZES_26B123_M5', r'fn m5_policy_source',
    r'pub\(crate\) const M5_POLICY_SIZE:', r'pub\(crate\) const M5_POLICY_STATE_PTR',
    r'pub\(crate\) const M5_POLICY_AON_PTD_PTR', r'pub\(crate\) const M5_POLICY_MAXIMUM_POWER',
    r'pub\(crate\) const M5_26B123_POLICY_BANDS', r'pub\(crate\) const M5_26B123_POLICY_SIZE',
    r'pub\(crate\) const M5_26B123_POLICY_CONTROLLER_WORDS:',
    r'pub\(crate\) const M5_26B123_POLICY_CONTROLLER_WORDS_G17D', r'const M5_CORE_TYPE_G17D',
    r'pub\(crate\) struct M5PolicyMap', r'impl M5PolicyMap', r'pub\(crate\) const M5_26A428_POLICY:',
    r'pub\(crate\) const M5_26B123_POLICY:', r'pub\(crate\) const fn m5_policy\(',
    r'pub\(crate\) const fn m5_policy_size', r'const fn expands_in_place',
    r'const _: \(\) = \{\n    assert!\(expands_in_place', r'pub\(crate\) fn relayout_m5_policy',
    r'pub\(crate\) const J714_GPU_POWER_SAMPLE_PERIOD_AIC_CLOCKS', r'pub\(crate\) const J714_GPU_PERF_BASE_PSTATE',
    r'const J714_POWER_POLICY_MINIMUM_TABLE', r'const J714_POWER_POLICY_MINIMUM_ENTRIES',
    r'pub\(crate\) const J714_GPU_NUM_PERF_STATES', r'const J775D_PERF_FLOOR',
    r'pub\(crate\) fn encode_m5_bundle_policy', r'pub\(crate\) fn encode_m5_policy_controller_defaults\(',
    r'pub\(crate\) fn encode_m5_policy_controller_defaults_j716c',
    r'pub\(crate\) fn encode_m5_policy_controller_defaults_j775d',
]
STUBS = r'''
#![allow(dead_code)]
use core::result::Result;
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum M5Layouts { V26A428, V26B123 }
pub(crate) struct Board { core_revision: (u32, u32) }
fn required_address(a: u64) -> Result<(), InitdataError> {
    if a == 0 { Err(InitdataError::NullRequiredAddress) } else { Ok(()) }
}
#[derive(Copy, Clone)]
pub(crate) struct Layout { block_c18: usize, block_1048: usize, block_e10: usize, policy: usize }
// The policy sits where the encoders put it; the blocks before it are outside this check.
pub(crate) const M5_SHARED_LAYOUT: Layout =
    Layout { block_c18: 0x2000, block_1048: 0x3000, block_e10: 0x4000, policy: 0x10000 };
pub(crate) const M5_SHARED_PREFIX_SIZE: usize = 0x10000 + 0x12780;
const M5_25G76_SHARED_LAYOUT: Layout = M5_SHARED_LAYOUT;
const M5_25G76_POLICY_WORDS: &[(usize, u32)] = &[];
// Integration: encode_m5_bundle_policy takes the M5 layout; only these parts are used.
pub(crate) struct M5Layout { shared: Layout, prefix: usize, policy: usize }
impl M5Layout {
    const fn shared_prefix_size(&self) -> usize { self.prefix }
    const fn policy_size(&self) -> usize { self.policy }
}
'''
MAIN = r'''
fn dump(tag: &str, p: &[u8]) {
    for (i, w) in p.chunks(4).enumerate() {
        let v = u32::from_le_bytes([w[0], w[1], *w.get(2).unwrap_or(&0), *w.get(3).unwrap_or(&0)]);
        if v != 0 { println!("{} {:#x} {:#x}", tag, i * 4, v); }
    }
}
fn main() {
    let boards: [(&str, u32, fn(&mut [u8]) -> Result<(), InitdataError>); 3] = [
        ("J714", 0x18, encode_m5_policy_controller_defaults),
        ("J716C", 0x19, encode_m5_policy_controller_defaults_j716c),
        ("J775D", 0x1a, encode_m5_policy_controller_defaults_j775d),
    ];
    let p = M5_SHARED_LAYOUT.policy;
    for (name, core, defaults) in boards {
        let board = Board { core_revision: (core, 0) };
        for applied in [false, true] {
            let mut out = vec![0u8; M5_SHARED_PREFIX_SIZE];
            let layout = M5Layout { shared: M5_SHARED_LAYOUT, prefix: M5_SHARED_PREFIX_SIZE, policy: M5_POLICY_SIZE };
            encode_m5_bundle_policy(&layout, M5PolicyBindings { state: 0x1111_2222_3333, aon_ptd: 0x4444_5555_6666,
                boot_timestamp: 0 }, &mut out).unwrap();
            if applied { defaults(&mut out).unwrap(); }
            let before = out.clone();
            let map = m5_policy(M5Layouts::V26A428);
            relayout_m5_policy(map, &board, applied, &mut out[p..p + m5_policy_size(M5Layouts::V26A428)]).unwrap();
            assert!(out == before, "26A428 relayout changed the policy");
            let old = out[p..p + M5_POLICY_SIZE].to_vec();
            let map = m5_policy(M5Layouts::V26B123);
            relayout_m5_policy(map, &board, applied, &mut out[p..p + m5_policy_size(M5Layouts::V26B123)]).unwrap();
            assert!(out[..p] == before[..p] && out[p + M5_26B123_POLICY_SIZE..] == before[p + M5_26B123_POLICY_SIZE..],
                "26B123 relayout wrote outside the policy");
            let tag = format!("{} {}", name, if applied { "defaults" } else { "base" });
            dump(&format!("{} A", tag), &old);
            dump(&format!("{} B", tag), &out[p..p + M5_26B123_POLICY_SIZE]);
            // Byte image of A for the per-byte check.
            println!("{} BYTES {}", tag, old.iter().map(|b| format!("{:02x}", b)).collect::<String>());
            println!("{} BYTESB {}", tag, out[p..p + M5_26B123_POLICY_SIZE].iter().map(|b| format!("{:02x}", b)).collect::<String>());
        }
    }
    // Wrong slice length is refused.
    let mut short = vec![0u8; M5_POLICY_SIZE];
    assert!(relayout_m5_policy(&M5_26B123_POLICY, &Board { core_revision: (0x18, 0) }, true, &mut short).is_err());
    println!("OK");
}
'''
os.makedirs(OUT, exist_ok=True)
rs = STUBS + '\n'.join(item(p) for p in ITEMS) + '\n' + MAIN
open(os.path.join(OUT, 'policy_check.rs'), 'w').write(rs)
exe = os.path.join(OUT, 'policy_check')
r = subprocess.run(['rustc', '--edition', '2021', '-O', '-o', exe, os.path.join(OUT, 'policy_check.rs')],
                   capture_output=True, text=True)
if r.returncode:
    print(r.stderr)
    sys.exit('rustc failed')
run = subprocess.run([exe], capture_output=True, text=True)
if run.returncode or not run.stdout.rstrip().endswith('OK'):
    print(run.stdout[-2000:], run.stderr)
    sys.exit('policy_check failed')
print('  compiled the driver items with', subprocess.run(['rustc', '--version'], capture_output=True,
      text=True).stdout.strip(), '; 26A428 relayout byte-identical for every board; short slice refused')

images = {}
for line in run.stdout.splitlines():
    f = line.split()
    if len(f) == 4 and f[2] in ('BYTES', 'BYTESB'):
        images[(f[0], f[1], f[2])] = bytes.fromhex(f[3])

CW = {0x18: {0x492c: 5000, 0x4a14: 1600}, 0x19: {0x492c: 5000, 0x4a14: 1600},
      0x1a: {0x4920: 2500, 0x4928: 800, 0x492c: 1100, 0x49e4: 0, 0x4a14: 1600}}
aurora = set()
for name, core in (('J714', 0x18), ('J716C', 0x19), ('J775D', 0x1a)):
    for mode in ('base', 'defaults'):
        a = images[(name, mode, 'BYTES')]
        b = images[(name, mode, 'BYTESB')]
        assert len(a) == SIZE_70 and len(b) == SIZE_72
        exp = bytearray(SIZE_72)
        for o in range(SIZE_70):
            exp[reloc(o)] = a[o]
        words = CW[core] if mode == 'defaults' else {}
        for o, v in words.items():
            exp[o:o + 4] = v.to_bytes(4, 'little')
        bad = [hex(i) for i in range(SIZE_72) if exp[i] != b[i]]
        lost = [hex(o) for o in range(SIZE_70) if a[o] and not target_covered(reloc(o))]
        in_ins = sorted({t & ~3 for t in range(SIZE_72) if b[t] and not target_covered(t)})
        nz = sorted({o & ~3 for o in range(SIZE_70) if a[o]})
        aurora |= set(nz)
        print(f'  {name:5} {mode:8}: {len(nz)} non-zero 27.0 words; mismatches vs Python relocation '
              f'{len(bad)}{" " + str(bad[:8]) if bad else ""}; words in inserts '
              f'{[hex(x) for x in in_ins] or "none"}; lost {lost or "none"}')
        ok &= not bad and not lost and set(in_ins) <= {o for o in words if words[o]}

touch = [hex(o) for o in sorted(set(k70) | set(f70) | aurora) if src_lo <= o < src_hi]
print(f'\n  27.0 source of the moved-in firmware fields [{src_lo:#x}, {src_hi:#x}) touched by the 27.0 kext, '
      f'firmware or driver: {touch or "no"}')
ok &= not touch

section('4b. driver words (all boards) at their 27.2 offsets vs the 27.2 kext stores / fw accesses')


def covers(st, t):
    return any(o <= t < o + w for o, (w, _) in st.items())


k70_cov = [o for o in sorted(aurora) if covers(k70, o)]
k72_cov = [o for o in sorted(aurora) if covers(k72_2, reloc(o))]
f70_hit = [o for o in sorted(aurora) if o in f70]
f72_hit = [o for o in sorted(aurora) if reloc(o) in f72_2]
print(f'  {len(aurora)} driver word offsets; written by a 27.0 kext store: {len(k70_cov)}, by the relocated '
      f'27.2 store: {len(k72_cov)}; read by 27.0 fw: {len(f70_hit)}, at the relocated 27.2 offset: {len(f72_hit)}')
lose_k = [hex(o) for o in k70_cov if o not in k72_cov]
lose_f = [hex(o) for o in f70_hit if o not in f72_hit]
print('  covered in 27.0 but not after relocation: kext', lose_k or 'none', '; fw', lose_f or 'none')
ok &= not lose_k and not lose_f
above = [o for o in sorted(aurora) if o >= 0x4910]
print(f'  {len(above)} driver words at or above 0x4910, e.g. ' +
      ', '.join(f'{o:#x}->{reloc(o):#x}' for o in above[:4] + above[-4:]))
print('  controller words in the 27.2 kext stores:', {hex(o): o in k72_2 for o in (0x492c, 0x4a14)})

print('\nRESULT:', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
