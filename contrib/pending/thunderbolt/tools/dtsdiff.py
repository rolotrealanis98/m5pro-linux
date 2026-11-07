import sys, re
def parse(p):
    nodes = {}; stack = []
    for line in open(p):
        t = line.strip()
        if not t or t.startswith('/dts-v1/') or t.startswith('//'): continue
        m = re.match(r'^(?:[\w,.-]+:\s*)*([^\s{=;]+)\s*\{$', t)
        if m:
            name = m.group(1); stack.append(name)
            path = '/'.join(stack).replace('//', '/') or '/'
            nodes.setdefault(path, {}); continue
        if t == '};':
            stack.pop(); continue
        if t.endswith(';'):
            path = '/'.join(stack).replace('//', '/')
            k = t.split('=')[0].strip().rstrip(';')
            if k == 'phandle': continue
            nodes[path][k] = t
    return nodes
a, b = parse(sys.argv[1]), parse(sys.argv[2])
add = sorted(set(b) - set(a)); rem = sorted(set(a) - set(b))
print('nodes added (%d):' % len(add)); [print('  +', n) for n in add]
print('nodes removed (%d):' % len(rem)); [print('  -', n) for n in rem]
print('properties changed in common nodes:')
for n in sorted(set(a) & set(b)):
    for k in sorted(set(a[n]) | set(b[n])):
        if a[n].get(k) != b[n].get(k):
            print('  %s: %s\n      was: %s\n      now: %s' % (n, k, (a[n].get(k) or '-')[:140], (b[n].get(k) or '-')[:140]))
