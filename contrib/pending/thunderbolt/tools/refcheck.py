import re, sys
s = open(sys.argv[1]).read()
NODE = re.compile(r'\s*((?:\w+:\s*)*)([\w@,.\-/]+) \{')
lab = {}; stack = []; status = {}
for line in s.splitlines():
    m = NODE.match(line)
    if m:
        stack.append(m.group(2)); p = '/'.join(stack); status[p] = 'okay'
        for l in re.findall(r'(\w+):', m.group(1)): lab[l] = p
        continue
    if re.match(r'\s*\};', line): stack.pop(); continue
    st = re.search(r'status = "(\w+)"', line)
    if st: status['/'.join(stack)] = st.group(1)
def en(p):
    parts = p.split('/'); return all(status.get('/'.join(parts[:i+1]), 'okay') != 'disabled' for i in range(len(parts)))
stack = []; bad = 0; seen = 0
for line in s.splitlines():
    m = NODE.match(line)
    if m: stack.append(m.group(2)); continue
    if re.match(r'\s*\};', line): stack.pop(); continue
    p = '/'.join(stack)
    if not re.search(sys.argv[2], p) or not en(p): continue
    for r in set(re.findall(r'&(\w+)', line)):
        seen += 1; tp = lab.get(r)
        if not (tp and en(tp)):
            bad += 1; print('PROBLEM', p.split('/')[-1], line.strip()[:70], '->', r, tp)
print('enabled routers:', sorted(p.split('/')[-1] for p in status if re.search(r'acio@[0-9a-f]+$', p) and en(p)))
print('%d references checked, %d to a disabled or missing provider' % (seen, bad))
