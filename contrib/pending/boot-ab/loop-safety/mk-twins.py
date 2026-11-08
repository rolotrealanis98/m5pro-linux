#!/usr/bin/env python3
# Test twins of next-daily-wifi-20261107-ee3d0dd8 (daily DTB, pcie_aspm=off, chosen.m5pro,n1=4) for the watchdog loop-safety
# test plan, built with the patched mk-daily.py next to this file. Output: private/twins/ (0600, the initramfs has the FTAB).
#   python3 -I mk-twins.py opener   # new initramfs (opener), m5.selftest=1 watchdog.open_timeout=300  -> must boot normally
#   python3 -I mk-twins.py noopener # new initramfs + m5.wdt=off (marks only, no opener), open_timeout=120 -> must reset at ~150 s
import hashlib, os, pathlib, shutil, subprocess, sys
H = pathlib.Path.home(); L = H/"Work/agents/loop-safety"; N = H/"Work/agents/next-daily"
MK = L/"mk-daily.py"
K = N/"images/Image-7.3.0-ga0f2f30c967b.gz"; D = N/"images/t6050-j716s-next-daily.dtb"
M = H/"Work/agents/n1-wifi/w4/build/m1n1-plain-n1-warm.bin"
IR_OLD = N/"payloads/private/initramfs-ftab.cpio.gz"; IR_NEW = L/"private/initramfs-ftab-wdt2.cpio.gz"
PINS = {K: "0f302e9a7a05be12884d38e2aff794ec64ae094619eb9d06df8e5bac6e5106fb", D: "659af884741861a6edd68b364d4f9ec04d624fe761dd0163e81964dafe136e8c",
        M: "4c202e9dbf0738cb256fb3903f02c6abd2d653b8cfecea74d764f19d9ce6e1d5", IR_OLD: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa"}
sha = lambda b: hashlib.sha256(b).hexdigest()
for p, h in PINS.items():
    assert sha(p.read_bytes()) == h, f"{p} changed"
v = sys.argv[1]
label, ir, extra = {"opener": ("wdt2-opener", IR_NEW, []),
                    "noopener": ("wdt2-noopener", IR_NEW, ["--wdt-open-timeout", "120"])}[v]   # m5.wdt=off below: marks only, no opener
OUT = L/"private/twins"; OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
tmp = OUT/"tmp"; shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir(mode=0o700)
r = subprocess.run([sys.executable, "-I", str(MK), "--out", str(tmp), "--m1n1", str(M), "--kernel", str(K), "--dtb", str(D), "--battery",
                    "--label", label, "--initramfs", str(ir), "--extra", "pcie_aspm=off" + (" m5.wdt=off" if v == "noopener" else ""), *extra], capture_output=True, text=True)
if r.returncode: sys.exit(r.stderr)
p = pathlib.Path(r.stdout.split("wrote     ")[1].split("\n")[0].strip()); blob = p.read_bytes()
NOTCH = b"chosen.asahi,show-notch=1\n"; N1 = b"chosen.m5pro,n1=4\n"
assert blob.count(NOTCH) == 1 and N1 not in blob
i = blob.index(NOTCH) + len(NOTCH); out = blob[:i] + N1 + blob[i:]; dg = sha(out)
name = f"{label}-20261107-{dg[:8]}.bin"
rec = (p.with_name(p.name + ".recipe.txt")).read_text().replace(p.name, name).replace(sha(blob), dg)
rec += "note      chosen.m5pro,n1=4 inserted after the show-notch line (offsets from Image.gz on are +0x12), as mk-next-daily.py does; twin of next-daily-wifi-20261107-ee3d0dd8\n"
if v == "noopener":
    rec += ("note      NEGATIVE TEST: new initramfs with m5.wdt=off (writes boot_stage 0x31/0x32 only, no opener, no drop-in) + open_timeout=120: "
            "expect the root to come up (0x33, 0x34 from the selftest) and a reset at ~150 s of kernel uptime with error stage 0x33/0x34, then the stage-1 fallback. "
            "The root must have NO RuntimeWatchdogSec drop-in (rm /etc/systemd/system.conf.d/m5pro-watchdog.conf first; the opener twin installs it)\n")
for f, data in ((OUT/name, out), (OUT/(name + ".recipe.txt"), rec.encode())):
    fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as h: h.write(data)
with open(OUT/"SHA256SUMS", "a") as h: h.write(f"{dg}  {name}\n")
shutil.rmtree(tmp)
print(f"{OUT/name}  {dg}  {len(out)} bytes")
