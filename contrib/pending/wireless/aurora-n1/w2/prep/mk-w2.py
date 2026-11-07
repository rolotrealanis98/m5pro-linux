#!/usr/bin/env python3
# Build a W2-series payload = W1's recipe (n1-wifi/prep/mk-w1.py) with another m1n1 and n1 value. Same kernel, DTB,
# initramfs and bootargs as W0/W1; the script asserts that the payload equals W1 beyond the m1n1 and the n1 line.
#   python3 -I ~/Work/agents/n1-wifi/w2/prep/mk-w2.py w2c    # (or 3 = w2, 4 = w2b, the old spellings)
#   w2   n1=3  m1n1 n1-ans (0025)         ran 2026-11-07: storage fine, STOP link up after 500 ms
#   w2b  n1=4  m1n1 n1-ans (0025)         ran 2026-11-07: STOP function-reset is not an SMC pKW4 (0023 bug)
#   w2c  n1=4  m1n1 n1-smc (0025+0026)    SMC gP13 pulse as on J813, 0023 port order, 1 s link wait
#   w2d  n1=5  m1n1 n1-smc (0025+0026)    w2c + J813 port order; only after w2c stopped at "link up ... after 1000 ms"
# Output: ~/Work/agents/aurora-kernel/payloads/<tag>-<name>-<date>-<sha8>.bin (+ .recipe.txt, SHA256SUMS line).
# Private: the initramfs carries the per-unit FTAB. Never into a repo.
import datetime, hashlib, pathlib, subprocess, sys, tempfile
H = pathlib.Path.home()
N1 = H/"Work/agents/n1-wifi"
OUT = H/"Work/agents/aurora-kernel/payloads"
T = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools"
ANS = ("m1n1-plain-n1-ans.bin", "69730b19d6debb6cd4d20e0c3a833b1467a58ec8fccf56d1312ff82db6398fc8",
       "n1 ans: 0020+0021+0022+0023+0025, v2.0.0-76-g3e7019df", "n1ans")
SMC = ("m1n1-plain-n1-smc.bin", "a4cc59fd94f9abc896a1ea4dd0964bf0710f154290ff957b44f31aefa9127db4",
       "n1 smc: 0020+0021+0022+0023+0025+0026, v2.0.0-77-g9b9c8e1d", "n1smc")
VARIANTS = {"w2": ("3", ANS), "w2b": ("4", ANS), "w2c": ("4", SMC), "w2d": ("5", SMC)}
arg = sys.argv[1] if len(sys.argv) > 1 else "w2"
tag = {"3": "w2", "4": "w2b"}.get(arg, arg)
assert tag in VARIANTS, f"unknown variant {arg}: one of {', '.join(VARIANTS)}"
n, (m1n1_name, m1n1_sha, m1n1_desc, label) = VARIANTS[tag]
sha = lambda b: hashlib.sha256(b).hexdigest()
M1N1 = N1/"w2/build"/m1n1_name
assert sha(M1N1.read_bytes()) == m1n1_sha, f"{m1n1_name} changed"
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
assert len(M1N1.read_bytes()) == M and b[:M] == M1N1.read_bytes(), "m1n1 is not the first 4 MiB"
assert b[M:M+16] == b"chosen.bootargs="
# Pin W1's bootargs: mk-daily.py's BASE gained kvm-arm.wfi_trap_policy=trap (for the WFI daily kernel) after W1 was built.
# W2 must differ from W1 only in the m1n1 and the n1 value.
W1_ARGS = (b"chosen.bootargs=earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused "
           b"no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 m5.selftest=1\n")
e = b.index(b"\n", M) + 1
assert b[M:e].replace(b"kvm-arm.wfi_trap_policy=trap ", b"") == W1_ARGS, b[M:e]
b = b[:M] + W1_ARGS + b[e:]
nl = b.index(b"\n", M) + 1
NOTCH = b"chosen.asahi,show-notch=1\n"
assert b[nl:nl+len(NOTCH)] == NOTCH and b"chosen.m5pro,n1" not in b[M:M+4096]
at = nl + len(NOTCH)
line = b"chosen.m5pro,n1=%s\n" % n.encode()
blob = b[:at] + line + b[at:]
W1 = OUT/"w1-n1train-20261107-3c0a1eff.bin"
if W1.exists():  # same bootargs, notch line, kernel, DTB and initramfs as W1, byte for byte
    w1 = W1.read_bytes()
    assert w1[M:] == blob[M:].replace(b"chosen.m5pro,n1=%s\n" % n.encode(), b"chosen.m5pro,n1=1\n", 1), "differs from W1 beyond m1n1 + n1"
d = sha(blob)
out = OUT/f"{tag}-{label}-{date}-{d[:8]}.bin"
out.write_bytes(blob)
with open(OUT/"SHA256SUMS", "a") as f:
    f.write(f"{d}  {out.name}\n")
bootargs = b[M+len(b"chosen.bootargs="):nl-1].decode()
out.with_name(out.name + ".recipe.txt").write_text(
    f"payload   {out.name}\nsha256    {d}\nmode      test {tag.upper()}; m5.selftest ON; battery driver ENABLED (attended boot only)\n"
    f"m1n1      {M1N1.name} sha256 {sha(M1N1.read_bytes())} ({m1n1_desc})\n"
    f"kernel    series /Volumes/linux-cs/wt-series-out/arch/arm64/boot/Image.gz (7.3.0-g4f630b11270d)\n"
    f"dtb       {DTB.name} sha256 {sha(DTB.read_bytes())}\n"
    f"initramfs {INITRD.name} sha256 {sha(INITRD.read_bytes())} (selftest base 1f61a850 + FTAB)\n"
    f"bootargs  {bootargs}\nchosen    asahi,show-notch=1 + m5pro,n1={n} (inserted by w2/prep/mk-w2.py at offset {at:#x}, {len(line)} bytes)\n"
    f"base      mk-daily.py --label wbase (scratch, not kept): {sha(b)}\n")
print(out, d, f"inserted at {at:#x}")
