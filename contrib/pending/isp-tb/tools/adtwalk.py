import sys, re
from m1n1.adt import load_adt
adt = load_adt(open(sys.argv[1],'rb').read())
pat = re.compile(sys.argv[2], re.I)
def walk(n, path):
    for c in n:
        p = path + '/' + c.name
        if pat.search(c.name):
            compat = getattr(c, 'compatible', None) if hasattr(c,'compatible') else None
            try: compat = c.compatible
            except Exception: compat=None
            print(p, compat)
        walk(c, p)
walk(adt, '')
