#!/usr/bin/env python3
# DCP-B0/B DTB = the daily DTB (659af884) + the internal panel's display pipeline exactly as
# contrib/pending/dcp/aurora/mk-fixed9.py writes it (every node disabled, NO apple,bw-scratch:
# BW_SCRATCH_OFFSET stays None), applied to the decompiled daily DTB instead of fixed8, so the
# DCP boots keep everything else of the daily (audio, N1, ...). Private (per-unit): never publish.
#   python3 -I ~/Work/agents/gpu-e2/mk-dcp-dtb.py
import hashlib, pathlib, subprocess, sys
H = pathlib.Path.home()
FIX9 = H/"Documents/GitHub/m5pro-linux/contrib/pending/dcp/aurora/mk-fixed9.py"
DAILY = H/"Work/agents/next-daily/images/t6050-j716s-next-daily.dtb"
OUT = H/"Work/agents/gpu-e2/payloads/private/dt"
DTC = "/opt/homebrew/bin/dtc"   # (wt-aurora's scripts/dtc/dtc, which made e26dcbbc first, was cleaned away)
sha = lambda b: hashlib.sha256(b).hexdigest()
assert sha(DAILY.read_bytes()) == "659af884741861a6edd68b364d4f9ec04d624fe761dd0163e81964dafe136e8c"
src = OUT/"t6050-j716s-daily.dts"
r = subprocess.run([DTC, "-q", "-I", "dtb", "-O", "dts", "-o", str(src), str(DAILY)], capture_output=True, text=True)
assert r.returncode == 0, r.stderr
code = FIX9.read_text()
for old, new in (('SRC = H/"Work/agents/trackpad-aurora/dt/j716s-typec-fixed8.dts"', f'SRC = pathlib.Path("{src}")'),
                 ('FIXED8_DTB = H/"Work/agents/trackpad-aurora/dt/t6050-j716s-typec-fixed8.dtb"', f'FIXED8_DTB = pathlib.Path("{DAILY}")'),
                 ('OUT = H/"Work/agents/dcp-aurora/dt"', f'OUT = pathlib.Path("{OUT}")'),
                 ('DTC = "/Volumes/linux-cs/wt-aurora/scripts/dtc/dtc"', f'DTC = "{DTC}"'),
                 ('"j716s-typec-fixed9.dts"', '"t6050-j716s-daily-dcp9.dts"'),
                 ('"t6050-j716s-typec-fixed9.dtb"', '"t6050-j716s-daily-dcp9.dtb"')):
    assert code.count(old) == 1, old
    code = code.replace(old, new)
assert "BW_SCRATCH_OFFSET = None" in code
exec(compile(code, str(FIX9), "exec"), {"__name__": "__main__"})
# The added nodes must be the ones fixed9 has: diff the two decompiled additions.
f9 = (H/"Work/agents/dcp-aurora/dt/j716s-typec-fixed9.dts").read_text()
d9 = (OUT/"t6050-j716s-daily-dcp9.dts").read_text()
for anchor, end in (("iommu@48a340000 {", "\n\t\t};"), ("iommu@48a300000 {", "\n\t\t};"),
                    ("mailbox@48ae08000 {", "\n\t\t};"), ("dcp@48ae00000 {", "\n\t\t};"),
                    ("display-subsystem {", "\n\t};")):
    a = f9.split(anchor, 1)[1].split(end, 1)[0]
    b = d9.split(anchor, 1)[1].split(end, 1)[0]
    assert a == b, f"node {anchor} differs from fixed9"
internal = d9.split("dcp@48ae00000 {", 1)[1].split("\n\t\t};", 1)[0]
assert "apple,bw-scratch =" not in internal
got = sha((OUT/"t6050-j716s-daily-dcp9.dtb").read_bytes())
assert got == "e26dcbbc1d3dadde11e44ff15c8b1185d907b564b0ec999643b83f335f5ffe7d", got
print("added nodes identical to fixed9's; the internal dcp node has no apple,bw-scratch "
      "(only the daily's dcpext0 keeps its own)")
