#!/usr/bin/env python3
"""Check the M5 status-config 26A428 -> 26B123 map against the kexts and the GFX1 firmware.

Inputs are local disassemblies (llvm-objdump text) of the AGXG17X kext __text from the 27.0
(26A428) and 27.2 (26B123) kernelcaches, optionally of the armfw1 GPU firmware of both builds,
and the driver source (g17/fw/m5/initdata.rs) carrying the map. Nothing is copied out of the
inputs; the output is offsets, constants and instruction addresses only.

  verify_statuscfg.py --kext0 26A428.dis --kext2 26B123.dis --src initdata.rs \
      [--base-src initdata.rs.orig] [--fw0 armfw1-26A428.dis --fw2 armfw1-26B123.dis]

Checks:
  1. Every status-config store of the 26A428 kext, moved by the driver's bands, lands on a
     26B123 store of the same kind of source (same configuration word up to the configuration
     object's own shift, an immediate, zero, or the same register role). 26B123 stores no
     26A428 store explains must be the driver's inserted words.
  2. The same for the GFX1 firmware's accesses through its status-config pointer, and its block
     stride.
  3. The driver's 26A428 image is byte-identical between the original encoder and the map's
     26A428 path (when --base-src is given), and the 26B123 image is printed per word.
"""
import argparse
import re
import sys

INS = re.compile(r'\s*([0-9a-f]+):\s+(\S+)\s*(.*)')


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            m = INS.match(line)
            if m:
                out.append((int(m.group(1), 16), m.group(2), m.group(3).split('//')[0].strip()))
    return out


def rn(r):
    """Register identity: ('g', n) for w/x, ('v', n) for b/h/s/d/q/v."""
    m = re.match(r'^([wx]|[bhsdqv])(\d+)(?:\.\w+)?$', r)
    if not m:
        return r
    return ('g' if m.group(1) in 'wx' else 'v', int(m.group(2)))


def split_ops(ar):
    return [p.strip() for p in re.split(r',(?![^\[]*\])', ar)]


STORES = ('str', 'stur', 'strh', 'strb', 'sturh', 'sturb', 'stp', 'stnp')
SIZE = {'w': 4, 'x': 8, 'q': 16, 'd': 8, 's': 4}


def store_size(op, reg):
    if op in ('strb', 'sturb'):
        return 1
    if op in ('strh', 'sturh'):
        return 2
    return SIZE.get(reg[0], 4) if reg not in ('wzr', 'xzr') else (4 if reg == 'wzr' else 8)


def kext_status_stores(ins, member, cfg_member):
    """Stores through `ldr xN, [x19, #member]`; each with a resolved source."""
    found = []
    for i, (a, op, ar) in enumerate(ins):
        if op != 'ldr':
            continue
        m = re.match(r'^(x\d+), \[x19, #' + hex(member) + r'\]$', ar)
        if not m:
            continue
        bases = {rn(m.group(1)): 0}
        for j in range(i + 1, min(i + 400, len(ins))):
            a2, op2, ar2 = ins[j]
            if op2 in ('ret', 'retab'):
                break
            parts = split_ops(ar2)
            if op2 in STORES:
                mm = re.search(r'\[(x\d+)(?:, #(-?0x[0-9a-f]+|-?\d+))?\]', ar2)
                if mm and rn(mm.group(1)) in bases:
                    off = bases[rn(mm.group(1))] + (int(mm.group(2), 0) if mm.group(2) else 0)
                    regs = parts[:2] if op2 in ('stp', 'stnp') else parts[:1]
                    for k, r in enumerate(regs):
                        sz = store_size(op2, r)
                        found.append((off + k * sz, sz, a2, op2, r,
                                      resolve(ins, j, r, cfg_member)))
                continue
            if not parts or not parts[0]:
                continue
            dst = rn(parts[0]) if re.match(r'([wx]|[bhsdqv])\d+', parts[0]) else None
            if op2 == 'add' and len(parts) >= 3 and rn(parts[1]) in bases:
                m3 = re.match(r'#(0x[0-9a-f]+|\d+)', parts[2])
                if m3:
                    bases[dst] = bases[rn(parts[1])] + int(m3.group(1), 0) * (
                        4096 if 'lsl #12' in ar2 else 1)
                    continue
            if dst is not None and op2 not in ('cmp', 'cmn', 'tst', 'b', 'cbz', 'cbnz', 'tbz',
                                               'tbnz', 'bl', 'blraa', 'blr', 'br', 'braa'):
                bases.pop(dst, None)
            if op2 in ('bl', 'blraa', 'blr', 'blraaz'):
                for r in list(bases):
                    if isinstance(r, tuple) and r[1] < 19:
                        bases.pop(r)
    # one entry per (offset, address)
    seen = {}
    for s in found:
        seen[(s[0], s[2], s[4])] = s
    return sorted(seen.values())


def resolve(ins, j, reg, cfg_member):
    """What a stored register holds: ('zero',), ('imm', v), ('cfg', off), ('reg', text)."""
    if reg in ('wzr', 'xzr'):
        return ('zero',)
    r = rn(reg)
    for k in range(j - 1, max(j - 600, 0), -1):
        a, op, ar = ins[k]
        parts = split_ops(ar)
        if not parts or op in STORES or op in ('cmp', 'cmn', 'tst', 'fcmp'):
            continue
        defs = [rn(parts[0])] + ([rn(parts[1])] if op in ('ldp', 'ldnp') else [])
        if r not in defs:
            continue
        if op == 'movi' and re.match(r'#0+$', parts[-1].replace('x', '0')):
            return ('zero',)
        if op == 'mov' and parts[1].startswith('#'):
            return ('imm', int(parts[1][1:], 0))
        if op in ('ldr', 'ldrb', 'ldur') or op == 'and':
            if op == 'and':  # ldrb + and #1
                continue
            mm = re.search(r'\[(x\d+)(?:, #(-?0x[0-9a-f]+|-?\d+))?\]', ar)
            if mm:
                base = cfg_base(ins, k, rn(mm.group(1)), cfg_member)
                if base is not None:
                    return ('cfg', base + (int(mm.group(2), 0) if mm.group(2) else 0))
            return ('reg', op + ' ' + ar)
        return ('reg', op + ' ' + ar)
    return ('reg', '?')


def cfg_base(ins, k, r, cfg_member):
    """Offset into the configuration object if register `r` at `k` points into it."""
    for q in range(k - 1, max(k - 200, 0), -1):
        a, op, ar = ins[q]
        parts = split_ops(ar)
        if not parts or rn(parts[0]) != r or op in STORES or op in ('cmp', 'cmn', 'tst'):
            continue
        if op == 'add' and len(parts) >= 3 and parts[2].startswith('#'):
            v = int(parts[2][1:].split()[0], 0) * (4096 if 'lsl #12' in ar else 1)
            inner = cfg_base(ins, q, rn(parts[1]), cfg_member)
            return None if inner is None else inner + v
        if op == 'ldr' and re.match(r'^x\d+, \[x19, #' + hex(cfg_member) + r'\]$', ar):
            return 0
        return None
    return None


# --- driver source -------------------------------------------------------------------------

def parse_words(src, name):
    m = re.search(r'const ' + name + r': &\[\(usize, u32\)\] =\s*&\[(.*?)\];', src, re.S)
    return [(int(a, 16), int(b, 16) if b.startswith('0x') else int(b))
            for a, b in re.findall(r'\((0x[0-9a-f_]+|\d+), (0x[0-9a-f_]+|\d+)\)',
                                   m.group(1).replace('_', ''))]


def parse_bands(src, name, consts):
    m = re.search(r'const ' + name + r': &\[LayoutBand\] = &\[(.*?)\n\];', src, re.S)
    out = []
    for args in re.findall(r'band\(\s*([^)]*?)\s*\)', m.group(1), re.S):
        f = [x.strip() for x in args.split(',') if x.strip()]
        val = [consts[x] if x in consts else int(x, 0) for x in f[:3]]
        out.append(tuple(val))
    return out


def parse_const(src, name):
    m = re.search(r'const ' + name + r': usize =\s*([^;]+);', src)
    v = m.group(1).strip()
    if re.match(r'^(0x[0-9a-f_]+|\d+)$', v):
        return int(v.replace('_', ''), 0)
    return None


def relocate(bands, off):
    for s, e, d in bands:
        if s <= off < e:
            return off + d
    return None


def image(words, first, second, size, inserted, link_word):
    """The status config the encoder writes (pointer bytes left zero)."""
    out = bytearray(size)
    for off, val in words:
        for i, byte in enumerate(val.to_bytes(4, 'little')):
            if byte == 0:
                continue
            t = relocate(first, off + i)
            if t is not None and second is not None:
                t = relocate(second, t)
            if t is not None:
                out[t] = byte
    for off, val in inserted:
        out[off:off + 4] = val.to_bytes(4, 'little')
    out[link_word:link_word + 4] = (1).to_bytes(4, 'little')
    return out


# --- firmware ------------------------------------------------------------------------------

def fw_global(ins):
    """The global the GFX1 firmware keeps the status-config pointer in (used with +0x5b4)."""
    for i, (a, op, ar) in enumerate(ins):
        if op == 'add' and ar.endswith('#0x5b4'):
            for k in range(i - 1, max(i - 8, 0), -1):
                a2, op2, ar2 = ins[k]
                m = re.match(r'x\d+, \[x\d+, #(0x[0-9a-f]+)\]$', ar2)
                if op2 == 'ldr' and m:
                    page = ins[k - 1]
                    if page[1] == 'adrp':
                        return int(page[2].split(',')[1].split()[0], 16), int(m.group(1), 16)
    return None


def fw_accesses(ins, page, lo):
    acc = {}
    strides = set()
    for i, (a, op, ar) in enumerate(ins):
        if op != 'adrp':
            continue
        p = [x.strip() for x in ar.split(',')]
        if int(p[1].split()[0], 16) != page:
            continue
        pr = rn(p[0])
        for j in range(i + 1, min(i + 6, len(ins))):
            a2, op2, ar2 = ins[j]
            m = re.match(r'(x\d+), \[(x\d+), #(0x[0-9a-f]+)\]$', ar2)
            if not (op2 == 'ldr' and m and rn(m.group(2)) == pr and int(m.group(3), 16) == lo):
                continue
            bases = {rn(m.group(1)): 0}
            regimm = {}
            for k in range(j + 1, min(j + 60, len(ins))):
                a3, op3, ar3 = ins[k]
                if op3 in ('ret', 'retab', 'b', 'br', 'bl', 'blr'):
                    break
                parts = split_ops(ar3)
                d = rn(parts[0]) if parts and parts[0] else None
                if op3 == 'mov' and len(parts) == 2 and parts[1].startswith('#'):
                    regimm[d] = int(parts[1][1:], 0)
                mm = re.search(r'\[(x\d+)(?:, (#-?0x[0-9a-f]+|x\d+))?\]', ar3)
                if mm and rn(mm.group(1)) in bases and (op3.startswith('ld') or op3.startswith('st')):
                    b = bases[rn(mm.group(1))]
                    g = mm.group(2)
                    if g and g.startswith('#'):
                        acc.setdefault(b + int(g[1:], 16), set()).add(a3)
                    elif not g:
                        acc.setdefault(b, set()).add(a3)
                if op3 == 'add' and len(parts) >= 3 and rn(parts[1]) in bases and parts[2].startswith('#'):
                    bases[d] = bases[rn(parts[1])] + int(parts[2][1:].split()[0], 16)
                    continue
                if d is not None and d in bases and not op3.startswith(('st', 'cmp', 'tb', 'cb')):
                    bases.pop(d)
            # register-selected offsets (csel between two immediates)
            for k in range(j + 1, min(j + 60, len(ins))):
                a3, op3, ar3 = ins[k]
                if op3 == 'mov':
                    parts = split_ops(ar3)
                    if parts[1].startswith('#'):
                        v = int(parts[1][1:], 0)
                        if 0x5b4 <= v < 0x7a0 and v & 3 == 0:
                            acc.setdefault(v, set()).add(a3)
            break
    for i, (a, op, ar) in enumerate(ins):
        m = re.match(r'(w\d+), #0x(5c|64)$', ar)
        if op == 'mov' and m:
            near = ins[i:i + 12]
            x = 'x' + m.group(1)[1:]
            if any(o == 'add' and t.endswith('#0x5b4') for _, o, t in near) and any(
                    o == 'mul' and t.endswith(x) for _, o, t in near):
                strides.add(int(m.group(2), 16))
    return acc, strides


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kext0', required=True)
    ap.add_argument('--kext2', required=True)
    ap.add_argument('--src', required=True)
    ap.add_argument('--base-src')
    ap.add_argument('--fw0')
    ap.add_argument('--fw2')
    ap.add_argument('--member0', type=lambda x: int(x, 0), default=0xcb8)
    ap.add_argument('--member2', type=lambda x: int(x, 0), default=0xcc0)
    ap.add_argument('--cfg0', type=lambda x: int(x, 0), default=0x2a0)
    ap.add_argument('--cfg2', type=lambda x: int(x, 0), default=0x2a8)
    a = ap.parse_args()

    src = open(a.src).read()
    consts = {'M5_STATUS_CONFIG_SIZE': 0x780, 'M5_25G76_HW_DATA_SIZE': 0x2708}
    bands = parse_bands(src, 'M5_26B123_STATUS_CONFIG_BANDS', consts)
    common = parse_bands(src, 'COMMON26_STATUS_CONFIG_BANDS', consts)
    inserted = parse_words(src, 'M5_26B123_STATUS_CONFIG_INSERTED')
    words = parse_words(src, 'M5_25G76_STATUS_CONFIG_WORDS')
    size2 = parse_const(src, 'M5_26B123_STATUS_CONFIG_SIZE')
    if size2 is None:
        # Integration: the size is entry 13 (ALLOC_STATUS_CONFIG) of A's 26B123 size table.
        table = re.search(r'ABI_ALLOCATION_SIZES_26B123_M5: \[usize; 24\] = \[([^\]]*)\]', src).group(1)
        size2 = int(re.findall(r'0x[0-9a-f]+', table)[13], 16)
    link0 = parse_const(src, 'M5_STATUS_CONFIG_LINK_WORD')
    ptr0 = parse_const(src, 'M5_STATUS_CONFIG_LINK_PTR')
    hist = [parse_const(src, n) for n in ('M5_STATUS_CONFIG_HISTORY',
                                          'M5_STATUS_CONFIG_HISTORY_GENERATION',
                                          'M5_STATUS_CONFIG_HISTORY_SLOTS')]
    ins_new = {o for o, _ in inserted}
    print('driver map (26A428 -> 26B123):')
    for s, e, d in bands:
        print(f'  [{s:#05x}, {e:#05x}) {d:+#x}')
    print('  inserted (26B123):', ', '.join(f'{o:#x}={v}' for o, v in inserted))
    print(f'  size {0x780:#x} -> {size2:#x}; link word/ptr {link0:#x}/{ptr0:#x} -> '
          f'{relocate(bands, link0):#x}/{relocate(bands, ptr0):#x}; history '
          + ', '.join(f'{h:#x}->{relocate(bands, h):#x}' for h in hist))
    bad = 0

    # 1. kext stores
    k0 = kext_status_stores(load(a.kext0), a.member0, a.cfg0)
    k2 = kext_status_stores(load(a.kext2), a.member2, a.cfg2)
    print(f'\nkext status-config stores: 26A428 {len(k0)}, 26B123 {len(k2)}')
    by2 = {}
    for s in k2:
        by2.setdefault(s[0], []).append(s)
    used2 = set()
    cfgpairs = []
    rows = []
    for off, sz, addr, op, reg, srcv in k0:
        if srcv == ('zero',):
            continue  # zero fills are compared byte by byte below
        t = relocate(bands, off)
        cands = by2.get(t, [])
        match = None
        for c in sorted(cands, key=lambda c: (c[0], c[2], c[4]) in used2):
            if c[1] != sz:
                continue
            k = srcv[0]
            if k == c[5][0] and (k != 'imm' or srcv[1] == c[5][1]):
                match = c
                break
        if match is None:
            bad += 1
            rows.append(f'  UNMATCHED 26A428 {off:#05x}/{sz} {addr:#x} {op} {reg} {srcv}'
                        f' -> {t if t is None else hex(t)}')
            continue
        used2.add((match[0], match[2], match[4]))
        if srcv[0] == 'cfg':
            cfgpairs.append((srcv[1], match[5][1], off, t))
        if 0x5b4 <= off:
            rows.append(f'  {off:#05x}/{sz:<2} {addr & 0xffffff:06x} -> {t:#05x} '
                        f'{match[2] & 0xffffff:06x}  {fmt_src(srcv)} | {fmt_src(match[5])}')
    print('  26A428 -> 26B123 (from +0x5b4; kext address low 24 bits; source 26A428 | 26B123):')
    print('\n'.join(rows))
    below = sum(1 for s in k0 if s[0] < 0x5b4)
    lowbad = sum(1 for r in rows if r.startswith('  UNMATCHED')
                 and int(r.split()[2].split('/')[0], 16) < 0x5b4)
    print(f'  below +0x5b4: {below} stores, {below - lowbad} at the same offset with the same'
          f' kind of source, {lowbad} unmatched')
    extra = [s for s in k2 if (s[0], s[2], s[4]) not in used2 and s[5] != ('zero',)]
    print('  26B123 stores no 26A428 store explains:')
    for off, sz, addr, op, reg, srcv in extra:
        covered = any(o <= off < o + 4 for o in ins_new) or (
            srcv == ('zero',) and all(any(o <= b < o + 4 for o in ins_new) or
                                      any(m[0] <= b < m[0] + m[1] for m in k2
                                          if (m[0], m[2], m[4]) in used2)
                                      for b in range(off, off + sz)))
        tag = 'inserted word' if covered else 'UNEXPLAINED'
        if not covered:
            bad += 1
        print(f'    {off:#05x}/{sz:<2} {addr:#x} {op} {reg} {fmt_src(srcv)}  [{tag}]')
    print('  configuration-object word pairs behind matched stores (26A428 -> 26B123):')
    for c0, c2, o0, o2 in sorted(set(cfgpairs)):
        print(f'    cfg {c0:#07x} -> {c2:#07x} ({c2 - c0:+#x})  status {o0:#05x} -> {o2:#05x}')
    cmap = {}
    for c0, c2, _o0, _o2 in cfgpairs:
        cmap.setdefault(c0, set()).add(c2)
    keys = sorted(cmap)
    mono = all(len(cmap[k]) == 1 for k in keys) and all(
        min(cmap[x]) < min(cmap[y]) for x, y in zip(keys, keys[1:]))
    print(f'    one 26B123 word per 26A428 word, order kept: {mono}')
    bad += not mono
    # zero fills, byte by byte
    z0, z2 = set(), set()
    for st, z in ((k0, z0), (k2, z2)):
        for off, sz, *_r, srcv in st:
            if srcv == ('zero',):
                z.update(range(off, off + sz))
    moved = {relocate(bands, b) for b in z0}
    lost = sorted(b for b in moved if b not in z2)
    new = sorted(b for b in z2 - moved)
    newok = [b for b in new if any(o <= b < o + 4 for o in ins_new)]
    newbad = [b for b in new if b not in newok]
    print('  zero-filled bytes: 26A428 ' + ', '.join(f'[{s:#x},{e:#x})' for s, e in ranges(sorted(z0))))
    print('                     26B123 ' + ', '.join(f'[{s:#x},{e:#x})' for s, e in ranges(sorted(z2))))
    print('    26A428 zero bytes not zero-filled at their 26B123 offset: '
          + (', '.join(f'[{s:#x},{e:#x})' for s, e in ranges(lost)) or 'none'))
    print('    26B123 zero bytes beyond the moved 26A428 ones: '
          + ', '.join(f'[{s:#x},{e:#x})' for s, e in ranges(new))
          + ('  (all inserted words)' if not newbad else '  UNEXPLAINED'))
    bad += len(lost) + len(newbad)

    # 2. firmware
    if a.fw0 and a.fw2:
        f0, f2 = load(a.fw0), load(a.fw2)
        g0, g2 = fw_global(f0), fw_global(f2)
        acc0, str0 = fw_accesses(f0, *g0)
        acc2, str2 = fw_accesses(f2, *g2)
        print(f'\nGFX1 firmware: status-config pointer at {g0[0] + g0[1]:#x} (26A428), '
              f'{g2[0] + g2[1]:#x} (26B123); block stride {sorted(str0)} -> {sorted(str2)}')
        pending = set(acc2)
        print('  accesses at +0x5b4 and above (26A428 -> 26B123):')
        for off in sorted(o for o in acc0 if o >= 0x5b4):
            t = relocate(bands, off) if off < 0x780 else None
            ok = t in acc2
            pending.discard(t)
            if not ok:
                bad += 1
            print(f'    {off:#05x} -> {t if t is None else hex(t)} {"ok" if ok else "MISSING"}')
        same = [o for o in acc0 if o < 0x5b4 and o in acc2]
        miss = [o for o in acc0 if o < 0x5b4 and o not in acc2]
        pending -= set(same)
        print(f'  below +0x5b4: {len(same)} offsets unchanged, {len(miss)} missing {miss}')
        bad += len(miss)
        print('  26B123 accesses no 26A428 access explains:',
              ', '.join(f'{o:#x}' + (' (inserted)' if o in ins_new else ' UNEXPLAINED')
                        for o in sorted(pending)) or 'none')
        bad += sum(1 for o in pending if o not in ins_new)

    # 3. driver images
    img0 = image(words, common, None, 0x780, [], link0)
    if a.base_src:
        base = open(a.base_src).read()
        old = image(parse_words(base, 'M5_25G76_STATUS_CONFIG_WORDS'),
                    parse_bands(base, 'COMMON26_STATUS_CONFIG_BANDS', consts), None, 0x780, [],
                    parse_const(base, 'M5_STATUS_CONFIG_LINK_WORD'))
        same = old == img0
        print(f'\n26A428 status config, original encoder vs map path: '
              f'{"byte-identical" if same else "DIFFERENT"} ({len(img0):#x} bytes)')
        bad += not same
    img2 = image(words, common, bands, size2, inserted, relocate(bands, link0))
    kst0 = {}
    for s in k0:
        kst0.setdefault(s[0], []).append(s)
    print('\ndriver words: 25G76 -> 26A428 -> 26B123, value, 26A428 kext store there | 26B123:')
    for off, val in words:
        t0 = relocate(common, off)
        t2 = None if t0 is None else relocate(bands, t0)
        if t0 is None:
            continue
        d0 = desc(kst0.get(t0))
        d2 = desc(by2.get(t2))
        flag = '' if t0 < 0x5b4 else ' *'
        print(f'  {off:#05x} -> {t0:#05x} -> {t2:#05x}  {val:#010x}  {d0} | {d2}{flag}')
    print('  (* = in the controller blocks)')
    nz = [(i, b) for i, b in enumerate(img2) if b]
    print(f'26B123 image: {len(nz)} non-zero bytes, '
          f'link word at {relocate(bands, link0):#x}, size {len(img2):#x}')
    print(f'\nresult: {"PASS" if bad == 0 else f"{bad} problem(s)"}')
    return 0 if bad == 0 else 1


def desc(st):
    if not st:
        return '-'
    return ','.join(fmt_src(s[5]) for s in st)


def fmt_src(s):
    if s[0] == 'zero':
        return '0'
    if s[0] == 'imm':
        return f'#{s[1]:#x}'
    if s[0] == 'cfg':
        return f'cfg+{s[1]:#x}'
    return s[1].split()[0] + '?'


def ranges(xs):
    out = []
    for x in xs:
        if out and out[-1][1] == x:
            out[-1][1] = x + 1
        else:
            out.append([x, x + 1])
    return [tuple(r) for r in out]


if __name__ == '__main__':
    sys.exit(main())
