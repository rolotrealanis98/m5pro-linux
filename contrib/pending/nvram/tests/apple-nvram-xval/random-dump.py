# Random synthetic v3 dump (made-up values) for run.sh: random variables, deleted entries and boot-volume position.
import importlib.util, random, sys
spec = importlib.util.spec_from_file_location("sy", sys.argv[1]); sy = importlib.util.module_from_spec(spec); spec.loader.exec_module(sy)
random.seed(int(sys.argv[3]))
e = []
nbv = random.randint(0, 6)
for i in range(random.randint(5, 120)):
    if random.random() < 0.05:
        e.append(sy.entry(b"boot-volume", sy.vol(random.choice([1, 2])), state=0x7C))
    g = random.choice([sy.SYSTEM, sy.COMMON])
    e.append(sy.entry(b"v%03d" % i, bytes(random.randrange(256) for _ in range(random.randint(0, 400))), g, state=random.choice([0x7F, 0x7C, 0x7C])))
e.insert(random.randint(0, len(e)), sy.entry(b"boot-volume", sy.vol(random.choice([1, 2]))))
while sum(map(len, e)) + 24 > 0x10000 - 400: e.pop(0)
act = random.randrange(12)
banks = []
for i in range(12):
    if i == act: banks.append(sy.bank(500, e))
    elif random.random() < 0.3: banks.append(b"\xff" * 0x10000)
    else: banks.append(sy.bank(400 + i, e[:random.randint(0, 20)]))
open(sys.argv[2], "wb").write(b"".join(banks))
