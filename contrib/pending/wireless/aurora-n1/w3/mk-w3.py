#!/usr/bin/env python3
# W3 payload = the W2c payload (w2c-n1smc-20261107-d8bab230.bin: m1n1 n1-smc a4cc59fd, n1=4, kernel
# 7.3.0-g4f630b11270d, DTB stack-right-port+hwmon 594f2a9f, W1 bootargs) with ONLY its initramfs
# replaced by w3/private/initramfs-selftest-n1-w3.cpio.gz (the stitched FTAB). mk-daily.py's layout
# puts the initramfs last (m1n1 | chosen lines | Image.gz | dtb | initramfs), so W3 = W2c's first
# 0x149a4b6 bytes + the new initramfs. Then writes the deploy script (mk-daily.py --deploy-plan steps
# 0-2 + the known-daily guard of w2/prep/gen-deploy-w2.py).
#   python3 -I ~/Work/agents/n1-wifi/w3/mk-w3.py
# Output (all private, 0600): w3/private/w3-n1ftab-<date>-<sha8>.bin, .recipe.txt, SHA256SUMS line,
# w3/private/deploy-W3.sh. Stdout: file names and sizes.
import datetime, hashlib, os, pathlib, subprocess, sys
H = pathlib.Path.home()
PRIV = (H/"Work/agents/n1-wifi/w3/private").resolve()
W2C = H/"Work/agents/aurora-kernel/payloads/w2c-n1smc-20261107-d8bab230.bin"
OLD_INITRD = H/"Work/agents/n1-wifi/payloads/initramfs-selftest-n1-b1f61a85.cpio.gz"
NEW_INITRD = PRIV/"initramfs-selftest-n1-w3.cpio.gz"
M1N1 = H/"Work/agents/n1-wifi/w2/build/m1n1-plain-n1-smc.bin"
T = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools"
GEN = H/"Work/agents/n1-wifi/w2/prep/gen-deploy-w2.py"
sha = lambda b: hashlib.sha256(b).hexdigest()

w2c, old, new, m1n1 = W2C.read_bytes(), OLD_INITRD.read_bytes(), NEW_INITRD.read_bytes(), M1N1.read_bytes()
assert sha(w2c) == "d8bab230903bb7fc54338760d7ceb6c51f5897337c2d04558faa684793ae83fd", "W2c payload changed"
assert sha(old) == "4f299656af6ad896e98ad7e206ae6c7765c097b9389128126c59586e2fe023e4", "b1f61a85 initramfs changed"
assert sha(m1n1) == "a4cc59fd94f9abc896a1ea4dd0964bf0710f154290ff957b44f31aefa9127db4", "n1-smc m1n1 changed"
for l in (PRIV/"SHA256SUMS").read_text().splitlines():
    if l.endswith("  " + NEW_INITRD.name):
        want = l.split()[0]
assert sha(new) == want, "W3 initramfs differs from its SHA256SUMS line: rerun mk-initramfs-n1-w3.py"
M = 0x400000
assert w2c[:M] == m1n1 and w2c.endswith(old)
cut = len(w2c) - len(old)
assert cut == 0x149a4b6, hex(cut)
head = w2c[:cut]
assert b"chosen.m5pro,n1=4\n" in head[M:M + 4096] and b"m5.selftest=1" in head[M:M + 4096]
blob = head + new
assert blob[:cut] == w2c[:cut] and blob[cut:] == new

d = sha(blob)
date = datetime.date.today().strftime("%Y%m%d")
out = PRIV/f"w3-n1ftab-{date}-{d[:8]}.bin"
def wr(p, data, mode=0o600):
    tmp = p.with_name(p.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    os.replace(tmp, p)
wr(out, blob)
with open(PRIV/"SHA256SUMS", "a") as fh:
    fh.write(f"{d}  {out.name}\n")
nl = head.index(b"\n", M)
wr(out.with_name(out.name + ".recipe.txt"), (
    f"payload   {out.name}\nsha256    {d}\nmode      test W3; m5.selftest ON; battery driver ENABLED (attended boot only)\n"
    f"base      {W2C.name} (sha256 {sha(w2c)}), bytes 0..{cut:#x} unchanged: m1n1, chosen lines, Image.gz, dtb\n"
    f"m1n1      {M1N1.name} sha256 {sha(m1n1)} (n1 smc: 0020+0021+0022+0023+0025+0026, v2.0.0-77-g9b9c8e1d)\n"
    f"kernel    series /Volumes/linux-cs/wt-series-out/arch/arm64/boot/Image.gz (7.3.0-g4f630b11270d), as W2c\n"
    f"dtb       stack-right-port+hwmon.dtb sha256 594f2a9f0e0d09ceca4b3fd3e9bd5360f3116d0c3f351cccf3ea0ac82a142bbc, as W2c\n"
    f"initramfs {NEW_INITRD.name} sha256 {sha(new)} @{cut:#x}+{len(new):#x} (selftest base 1f61a850 + stitched FTAB)\n"
    f"bootargs  {head[M + 16:nl].decode()}\nchosen    asahi,show-notch=1 + m5pro,n1=4 (as W2c)\n").encode())

# Deploy script: run W2's generator against this payload in a scratch copy, so nothing is written
# outside w3/ (gen-deploy-w2.py writes next to itself and resolves the payload in aurora-kernel/payloads).
src = GEN.read_text()
assert 'O = H/"Work/agents/aurora-kernel/payloads"' in src and "HERE = pathlib.Path(__file__).resolve().parent" in src
src = src.replace('O = H/"Work/agents/aurora-kernel/payloads"', f'O = pathlib.Path({str(PRIV)!r})')
gen = PRIV/"gen-deploy-w3.tmp.py"
wr(gen, src.encode())
try:
    r = subprocess.run([sys.executable, "-I", str(gen), out.name, "W3"], check=True, capture_output=True, text=True)
finally:
    gen.unlink()
dep = PRIV/"deploy-W3.sh"
txt = dep.read_text()
assert f"PAYLOAD={out}" in txt and f"SHA={d}" in txt and "dcec81ed" in txt
os.chmod(dep, 0o600)
print(f"wrote w3/private/{out.name}: {len(blob)} bytes (W2c up to {cut:#x} + initramfs {len(new)} bytes)")
print(f"wrote w3/private/{out.name}.recipe.txt, w3/private/deploy-W3.sh; sha256 in w3/private/SHA256SUMS")
