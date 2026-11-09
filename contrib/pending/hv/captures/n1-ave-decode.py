#!/usr/bin/env python3
# Offline decoder for hv27 apcie0/ave0 MMIO traces (read-only). Usage: python3 -I n1-ave-decode.py LOG [apcie|ave]
# Prints the apcie0 events with polls and sequential same-value writes collapsed; line numbers are log lines.
import re, sys, itertools
rx = re.compile(r'^\[cpu(\d+)\] \[(0x[0-9a-f]+)\] MMIO: ([RW])\.(\d)\s+(0x[0-9a-f]+) \(([\w.]+), offset (0x[0-9a-f]+)\) = (0x[0-9a-f]+)')
ev = []
for i, l in enumerate(open(sys.argv[1]), 1):
    m = rx.match(l)
    if m:
        c, pc, rw, sz, a, reg, off, v = m.groups()
        ev.append((i, rw, reg, int(off, 16), int(v, 16)))
want = sys.argv[2] if len(sys.argv) > 2 else 'apcie'
ev = [e for e in ev if e[2].startswith('apcie0' if want == 'apcie' else 'ave0')]
i = 0
while i < len(ev):
    ln, rw, reg, off, v = ev[i]
    j = i
    if rw == 'R':
        while j + 1 < len(ev) and ev[j+1][1] == 'R' and ev[j+1][2] == reg and ev[j+1][3] == off:
            j += 1
        if j > i:
            vals = [ev[k][4] for k in range(i, j + 1)]
            runs = [[x, len(list(g))] for x, g in itertools.groupby(vals)]
            print('L%d..%d R %s+%#x x%d: %s' % (ln, ev[j][0], reg, off, j - i + 1,
                  ' '.join('%#x%s' % (x, '(x%d)' % n if n > 1 else '') for x, n in runs)))
            i = j + 1
            continue
    else:
        while j + 1 < len(ev) and ev[j+1][1] == 'W' and ev[j+1][2] == reg and ev[j+1][3] == ev[j][3] + 4 and ev[j+1][4] == v:
            j += 1
        if j > i + 1:
            print('L%d..%d W %s+%#x..+%#x x%d = %#x' % (ln, ev[j][0], reg, off, ev[j][3], j - i + 1, v))
            i = j + 1
            continue
    print('L%d %s %s+%#x = %#x' % (ln, rw, reg, off, v))
    i += 1
