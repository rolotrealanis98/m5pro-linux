#!/usr/bin/env python3
# Build W1 (N1 port training, chosen.m5pro,n1=1) = the W0 recipe with the "train" m1n1 plus one
# chosen.* line. mk-daily.py has no flag for that line, so build a base in a scratch dir and insert it.
#   python3 -I ~/Work/agents/n1-wifi/prep/mk-w1.py          # n=1 (W1)
#   python3 -I ~/Work/agents/n1-wifi/prep/mk-w1.py 2        # W2, only after W1 stopped at "link up ... after 500 ms"
# Output: ~/Work/agents/aurora-kernel/payloads/w<n>-n1train-<date>-<sha8>.bin (+ .recipe.txt, SHA256SUMS line).
# Private: the initramfs carries the per-unit FTAB. Never into a repo.
import datetime, hashlib, pathlib, re, subprocess, sys, tempfile
H = pathlib.Path.home()
N1 = H/"Work/agents/n1-wifi"
OUT = H/"Work/agents/aurora-kernel/payloads"
T = H/"Documents/GitHub/m5pro-linux/contrib/pending/aurora/tools"
n = sys.argv[1] if len(sys.argv) > 1 else "1"
assert n in ("1", "2")
sha = lambda b: hashlib.sha256(b).hexdigest()
M1N1 = N1/"build/m1n1-plain-n1-train.bin"
assert sha(M1N1.read_bytes()) == "d31e5248fed273fdb4fd81cdb08bd007f82fc0df7e953e6ffb75434ba6a3deae", "train m1n1 changed"
INITRD = N1/"payloads/initramfs-selftest-n1-b1f61a85.cpio.gz"
assert sha(INITRD.read_bytes()) == "4f299656af6ad896e98ad7e206ae6c7765c097b9389128126c59586e2fe023e4", "n1 initramfs changed"
DTB = H/"Work/agents/dt-prep/build/stack-right-port+hwmon.dtb"
assert sha(DTB.read_bytes()).startswith("594f2a9f"), "daily DTB changed"
date = datetime.date.today().strftime("%Y%m%d")
with tempfile.TemporaryDirectory() as tmp:
    r = subprocess.run([sys.executable, "-I", str(T/"mk-daily.py"), "--out", tmp, "--label", "wbase", "--battery",
                        "--kernel", "series", "--dtb", str(DTB), "--initramfs", str(INITRD),
                        "--m1n1", str(M1N1), "--date", date], check=True, capture_output=True, text=True)
    base = next(pathlib.Path(tmp).glob("wbase-*.bin"))
    b = base.read_bytes()
M = 0x400000
assert b[M:M+16] == b"chosen.bootargs="
nl = b.index(b"\n", M) + 1
NOTCH = b"chosen.asahi,show-notch=1\n"
assert b[nl:nl+len(NOTCH)] == NOTCH and b"chosen.m5pro,n1" not in b[M:M+4096]
at = nl + len(NOTCH)
line = b"chosen.m5pro,n1=%s\n" % n.encode()
blob = b[:at] + line + b[at:]
d = sha(blob)
out = OUT/f"w{n}-n1train-{date}-{d[:8]}.bin"
out.write_bytes(blob)
with open(OUT/"SHA256SUMS", "a") as f:
    f.write(f"{d}  {out.name}\n")
bootargs = b[M+len(b"chosen.bootargs="):nl-1].decode()
out.with_name(out.name + ".recipe.txt").write_text(
    f"payload   {out.name}\nsha256    {d}\nmode      test W{n}; m5.selftest ON; battery driver ENABLED (attended boot only)\n"
    f"m1n1      {M1N1.name} sha256 {sha(M1N1.read_bytes())} (n1 train: 0020+0021+0022+0023, v2.0.0-75-g119168fa)\n"
    f"kernel    series /Volumes/linux-cs/wt-series-out/arch/arm64/boot/Image.gz (7.3.0-g4f630b11270d)\n"
    f"dtb       {DTB.name} sha256 {sha(DTB.read_bytes())}\n"
    f"initramfs {INITRD.name} sha256 {sha(INITRD.read_bytes())} (selftest base 1f61a850 + FTAB)\n"
    f"bootargs  {bootargs}\nchosen    asahi,show-notch=1 + m5pro,n1={n} (inserted by prep/mk-w1.py at offset {at:#x}, {len(line)} bytes)\n"
    f"base      mk-daily.py --label wbase (scratch, not kept): {sha(b)}\n")
print(out, d, f"inserted at {at:#x}")
