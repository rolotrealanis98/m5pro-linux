#!/usr/bin/env python3
# The in-tree daily-dcp DTB (c8f1b960) with a phandle on the two display nodes that have none: dcp@48ae00000 and
# display-subsystem. m1n1's T6050 display hand-off re-finds every node it edits by phandle and bails when one has none
# (kboot.c:2290-2296, "DCP: T6050: a display node has no phandle"), which fails kboot_prepare_dt(). The dcp9d DTB that
# booted has phandles on both (0xd3, 0xd4); dtc gives the in-tree ones none because no property references them.
# Decompile -> add `phandle = <max+1>` / `<max+2>` -> recompile. The unmodified DTS recompiles byte-identical.
import hashlib, pathlib, re, subprocess
H = pathlib.Path.home(); HERE = pathlib.Path(__file__).resolve().parent
SRC = H / "Work/agents/daily-dcp/kbuild/t6050-j716s-daily-dcp.dtb"; DTC = "/opt/homebrew/bin/dtc"
assert hashlib.sha256(SRC.read_bytes()).hexdigest().startswith("c8f1b960")
dts = subprocess.run([DTC, "-q", "-I", "dtb", "-O", "dts", str(SRC)], capture_output=True, text=True, check=True).stdout
assert subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", "/dev/stdout", "-"], input=dts.encode(),
                      capture_output=True, check=True).stdout == SRC.read_bytes()
used = {int(x, 16) for x in re.findall(r"phandle = <(0x[0-9a-f]+)>;", dts)}
nxt = max(used) + 1
L = dts.split("\n"); out = []; stack = []; added = []
WANT = ("/soc@200000000/dcp@48ae00000", "/display-subsystem")
for l in L:
    m = re.match(r'^(\s*)([\w@,.+-/]*)\s*\{$', l)
    if m:
        stack.append(m.group(2)); out.append(l)
        p = "/".join(stack).replace("//", "/")
        if p in WANT:   # first property, ahead of the subnodes; neither node has a phandle (checked below)
            out.append(f"{m.group(1)}\t" + f"phandle = <{nxt:#x}>;"); added.append((p, nxt)); nxt += 1
        continue
    if re.match(r'^\s*\};', l): stack.pop()
    out.append(l)
assert sorted(p for p, _ in added) == sorted(WANT), added
text = "\n".join(out)
assert text.count("phandle = ") == dts.count("phandle = ") + 2
dst = HERE / "t6050-j716s-daily-dcp-phfix.dtb"
(HERE / "t6050-j716s-daily-dcp-phfix.dts").write_text(text)
subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", str(dst), "-"], input=text.encode(), check=True)
for p, v in added: print(f"added phandle {v:#x} to {p}")
print(dst.name, hashlib.sha256(dst.read_bytes()).hexdigest(), dst.stat().st_size)
