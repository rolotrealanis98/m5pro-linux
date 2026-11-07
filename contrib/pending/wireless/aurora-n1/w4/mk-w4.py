#!/usr/bin/env python3
# W4 payload = DAILY-WIFI-T1 (daily-wifi-t1-20261107-5e188412.bin: m1n1 n1-smc a4cc59fd with chosen.m5pro,n1=4,
# WFI kernel 7.3.0-gf080637018df, stack DTB 594f2a9f, the stitched-FTAB initramfs, pcie_aspm=off, battery, selftest on)
# with two parts replaced:
#   m1n1    w4/build/m1n1-plain-n1-warm.bin (+0027: warm N1 / live port at entry, bounded SMC waits), same 0x400000 size
#   kernel  /Volumes/linux-cs/wt-n1shut-out/arch/arm64/boot/Image.gz = f080637018df + the two kernel patches
#           (pcie-apple shutdown park + no ASPM on adopted ports; centauri leaves a never-booted N1 alone)
# The chosen lines, DTB and initramfs are DAILY-WIFI-T1's bytes. Layout (mk-daily.py): m1n1 | chosen lines | Image.gz |
# dtb | initramfs, concatenated.
#   python3 -I ~/Work/agents/n1-wifi/w4/mk-w4.py <variant> [--daily <sha256>]...
#   w4             kernel 7.3.0-gff289b9ce8ec, selftest on (PASSED 2026-11-07: 3 warm restarts with wlan0 live)
#   w4d            w4 + initcall_debug (prints each device's shutdown)
#   w4t-lidwifi    kernel 7.3.0-gb61f760243c4 (= gff289b9ce8ec + the macsmc-input lid-open confirm, series 0066),
#                  selftest on: the test twin of the daily below
#   daily-wifi-lid the same without m5.selftest=1: the Wi-Fi + lid-sleep daily
#   w4t-n1sleep    kernel 7.3.0-g85c770faad4b (= gb61f760243c4 + pcie-apple: adopted links kept up through s2idle,
#                  contrib/pending/wireless/patches/linux/0003), selftest on: the test twin of the daily below
#   daily-n1sleep  the same without m5.selftest=1
#   --daily adds a known-good daily to the deploy guard.
# Kernels are kept in w4/kernels/ (wt-n1shut-out holds only the newest build).
# Output (private, 0600; the initramfs carries the FTAB): w4/private/<tag>-n1warm-<date>-<sha8>.bin, .recipe.txt,
# a SHA256SUMS line, and w4/private/deploy-<TAG>.sh (mk-daily.py --deploy-plan steps 0-2 + the known-daily guard of
# w2/prep/gen-deploy-w2.py, run from a scratch copy so nothing is written outside w4/). Stdout: file names and sizes.
import datetime, gzip, hashlib, os, pathlib, subprocess, sys, zlib
H = pathlib.Path.home()
W4 = H/"Work/agents/n1-wifi/w4"
PRIV = (W4/"private").resolve()
BASE = H/"Work/agents/n1-wifi/w3/private/daily-wifi-t1-20261107-5e188412.bin"
OLD_KERNEL_SHA = "ec0873a202f16a233de30f1fbf3e302ab4017f98c1e126d44de8e27dc5f36acc"
OLD_M1N1_SHA = "a4cc59fd94f9abc896a1ea4dd0964bf0710f154290ff957b44f31aefa9127db4"
M1N1 = W4/"build/m1n1-plain-n1-warm.bin"
M1N1_SHA = "4c202e9dbf0738cb256fb3903f02c6abd2d653b8cfecea74d764f19d9ce6e1d5"
KERNELS = {
    "gff289b9ce8ec": ("005c6ea9466379ba23e3ec988429af3429332793fe7ade895b9f327da5ee781c",
                      "f080637018df + pcie-apple shutdown park + centauri never-booted guard"),
    "gb61f760243c4": ("6d228752b21cffe6f44c046275b3e27dbd91e6998b458b55a2f36ec42c290bdd",
                      "gff289b9ce8ec + macsmc-input lid-open confirm (series 0066)"),
    "g85c770faad4b": ("c1d3d17a03adb26a3fe0e511b26f8cdaaddadda7ddbb50bda1c33021213e70b4",
                      "gb61f760243c4 + pcie-apple adopted links kept up through s2idle (0003)"),
}
#                 kernel           selftest  initcall_debug  file label
VARIANTS = {"w4": ("gff289b9ce8ec", True, False, "w4-n1warm"),
            "w4d": ("gff289b9ce8ec", True, True, "w4d-n1warm"),
            "w4t-lidwifi": ("gb61f760243c4", True, False, "w4t-lidwifi"),
            "daily-wifi-lid": ("gb61f760243c4", False, False, "daily-wifi-lid"),
            "w4t-n1sleep": ("g85c770faad4b", True, False, "w4t-n1sleep"),
            "daily-n1sleep": ("g85c770faad4b", False, False, "daily-n1sleep")}
GEN = H/"Work/agents/n1-wifi/w2/prep/gen-deploy-w2.py"
DAILIES = ["534ca14653f1bc474f597ec1b7242f8f572d5cc777a0c4cb7060f8f01852e5a4",  # lid daily (being restored)
           "dcec81eda0d83d7c746f44c767b8e2967ea038938ef76a3632edcb1857701655",
           "275d84ecfee87a2441e9cbd3f550129101dc82680e38abdb01c37c159af8d030",
           "bd9ebd5eed773b01259d87182a75d35487c1069d1c5ee8f316780965f963ecf7",  # daily-wifi-lid (Wi-Fi + lid daily)
           "350fd22adf035a370eef32e7ff6ed0836567b20d49d69fc128f946283b925b00",  # w4t-lidwifi, its test twin
           "78b12875e600b7ca4426b03d3285d41561d24d22eeecb49896a782fc3d48a105",  # daily-wifi (next-daily), promoted 11:21
           "7e285d949c05a69bd60db4170b74aea2091d92e038cc72f871677c4597140f5b"]  # next-daily-wifi, its test twin (prev)
sha = lambda b: hashlib.sha256(b).hexdigest()

args = sys.argv[1:]
tag = "w4"
while args:
    a = args.pop(0)
    if a == "--daily":
        d = args.pop(0)
        assert len(d) == 64 and all(c in "0123456789abcdef" for c in d), "--daily wants a full sha256"
        DAILIES.append(d)
    else:
        tag = a
assert tag in VARIANTS, f"variant: one of {', '.join(VARIANTS)}"
kver, selftest, icdebug, label = VARIANTS[tag]
KERNEL_SHA, KERNEL_DESC = KERNELS[kver]
KERNEL = W4/f"kernels/Image-7.3.0-{kver}.gz"

base, m1n1, kernel = BASE.read_bytes(), M1N1.read_bytes(), KERNEL.read_bytes()
# The file is mk-daily.py's output (5e188412, the name and the recipe) with chosen.m5pro,n1=4 inserted after the
# notch line (18 bytes): what was booted is 90f30233.
assert sha(base) == "90f3023319e2d3b03de4036b2de1a27922c9665bd56cad5b38f01ea259074e3d", "DAILY-WIFI-T1 payload changed"
assert sha(base.replace(b"chosen.m5pro,n1=4\n", b"", 1)) == "5e1884120870d05a34b55e7b1ed1b9f9102c8bd94515fbba58ba5cafbfd62cf4"
assert sha(m1n1) == M1N1_SHA and len(m1n1) == 0x400000, "n1-warm m1n1 changed"
assert sha(kernel) == KERNEL_SHA, f"{KERNEL.name} changed"
M = 0x400000
assert sha(base[:M]) == OLD_M1N1_SHA
k0 = base.index(b"\x1f\x8b\x08", M)                       # Image.gz starts right after the chosen lines
old_kernel = base[k0:k0 + 0x10923af]                     # recipe: Image.gz @0x400100+0x10923af, +18 for the n1 line
assert k0 == 0x400112 and sha(old_kernel) == OLD_KERNEL_SHA, "base layout differs from its recipe"
d = zlib.decompressobj(16 + zlib.MAX_WBITS); d.decompress(old_kernel)
assert d.eof and not d.unused_data, "old Image.gz boundary wrong"
chosen, tail = base[M:k0], base[k0 + len(old_kernel):]   # tail = dtb + initramfs, unchanged
assert chosen.startswith(b"chosen.bootargs=") and b"chosen.m5pro,n1=4\n" in chosen and b"pcie_aspm=off" in chosen
assert b"m5.selftest=1" in chosen and tail[:4] == b"\xd0\x0d\xfe\xed"
nl = chosen.index(b"\n")
args_line = chosen[:nl]
if not selftest:
    assert args_line.count(b" m5.selftest=1") == 1
    args_line = args_line.replace(b" m5.selftest=1", b"")
if icdebug:
    args_line += b" initcall_debug"
chosen = args_line + chosen[nl:]
blob = m1n1 + chosen + kernel + tail
digest = sha(blob)
date = datetime.date.today().strftime("%Y%m%d")
out = PRIV/f"{label}-{date}-{digest[:8]}.bin"

def wr(p, data, mode=0o600):
    tmp = p.with_name(p.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)
    os.replace(tmp, p)

wr(out, blob)
with open(PRIV/"SHA256SUMS", "a") as fh:
    fh.write(f"{digest}  {out.name}\n")
nl = chosen.index(b"\n")
wr(out.with_name(out.name + ".recipe.txt"), (
    f"payload   {out.name}\nsha256    {digest}\nmode      {'test ' + tag.upper() + '; m5.selftest ON' if selftest else 'daily; m5.selftest OFF'}; battery driver ENABLED\n"
    f"base      {BASE.name} (sha256 {sha(base)}): chosen lines (bootargs edited as the variant says), dtb, initramfs unchanged\n"
    f"m1n1      {M1N1.name} sha256 {M1N1_SHA} (0020-0023+0025+0026+0027, v2.0.0-78-g2ce0f78e)\n"
    f"kernel    {KERNEL.name} sha256 {KERNEL_SHA} (7.3.0-{kver} = {KERNEL_DESC}; tree /Volumes/linux-cs/wt-n1shut, branch j716s-n1shut)\n"
    f"layout    m1n1 @0x0+0x400000 | chosen @0x400000+{len(chosen):#x} | Image.gz @{M + len(chosen):#x}+{len(kernel):#x} | "
    f"dtb+initramfs @{M + len(chosen) + len(kernel):#x}+{len(tail):#x}\n"
    f"bootargs  {chosen[16:nl].decode()}\nchosen    asahi,show-notch=1 + m5pro,n1=4\n").encode())

# Deploy script from W2's generator, run as a scratch copy pointed at w4/private, with this guard's daily list
src = GEN.read_text()
for old, new in (('O = H/"Work/agents/aurora-kernel/payloads"', f'O = pathlib.Path({str(PRIV)!r})'),):
    assert old in src
    src = src.replace(old, new)
start = src.index("DAILIES = [")
end = src.index("]", start) + 1
src = src[:start] + "DAILIES = " + repr(DAILIES) + src[end:]
gen = PRIV/f"gen-deploy-{tag}.tmp.py"
wr(gen, src.encode())
try:
    subprocess.run([sys.executable, "-I", str(gen), out.name, tag.upper()], check=True, capture_output=True, text=True)
finally:
    gen.unlink()
dep = PRIV/f"deploy-{tag.upper()}.sh"
txt = dep.read_text()
assert f"PAYLOAD={out}" in txt and f"SHA={digest}" in txt and all(x in txt for x in DAILIES)
os.chmod(dep, 0o600)
print(f"wrote w4/private/{out.name}: {len(blob)} bytes")
print(f"wrote w4/private/{out.name}.recipe.txt, w4/private/{dep.name}; sha256 in w4/private/SHA256SUMS")
