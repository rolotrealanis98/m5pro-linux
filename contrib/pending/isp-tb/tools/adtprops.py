import sys, re
from m1n1.adt import load_adt
adt = load_adt(open(sys.argv[1],'rb').read())
DENY = re.compile(r'drom|uid|guid|serial|mlb|mac-addr|local-mac|region|wifi|bluetooth|bt-addr|address|uuid|udid|ecid|unique|nonce|cert|sn$|-sn|snum|identifier|nvram|boot-nonce|calib|otp|fuse|crypto|key', re.I)
def show(path, maxlen=96):
    n = adt
    for part in path.strip('/').split('/'):
        n = n[part]
    print('== '+path)
    for k in n._properties.keys() if hasattr(n,'_properties') else []:
        pass
    for k, v in n._properties.items():
        if DENY.search(k):
            print(f'  {k}: <withheld>'); continue
        if k in ('name',): continue
        try:
            val = getattr(n, k)
        except Exception:
            val = v
        s = repr(val)
        if isinstance(val,(bytes,bytearray)) and len(val)>maxlen:
            s = f'<{len(val)} bytes> ' + val[:32].hex()
        elif len(s) > 400:
            s = s[:400]+'...'
        print(f'  {k}: {s}')
for p in sys.argv[2:]:
    try: show(p)
    except Exception as e: print('ERR', p, e)
