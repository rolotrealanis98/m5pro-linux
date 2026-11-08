#!/usr/bin/env python3
# Round 3 DTBs: the in-tree daily-dcp DTB (c8f1b960) with one group of its additions over dcp9d reverted.
# Decompile -> edit the DTS text by node path -> recompile with dtc. The unmodified DTS recompiles byte-identical.
#   python3 -I mk-dt3.py   -> dt/t6050-j716s-daily-dcp-<variant>.dtb + .dts
import pathlib, re, subprocess, sys, hashlib
H = pathlib.Path.home(); HERE = pathlib.Path(__file__).resolve().parent
SRC = H / "Work/agents/daily-dcp/kbuild/t6050-j716s-daily-dcp.dtb"
DTC = "/opt/homebrew/bin/dtc"
assert hashlib.sha256(SRC.read_bytes()).hexdigest().startswith("c8f1b960")
dts = subprocess.run([DTC, "-q", "-I", "dtb", "-O", "dts", str(SRC)], capture_output=True, text=True, check=True).stdout
rt = subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", "/dev/stdout", "-"], input=dts.encode(), capture_output=True, check=True).stdout
assert rt == SRC.read_bytes(), "roundtrip is not byte-identical"

def lines_of(text): return text.split("\n")
def find_node(L, path):
    """[start, end] line indices of the node at absolute path (names as in the DTS)."""
    stack = []
    for i, l in enumerate(L):
        m = re.match(r'^\s*([\w@,.+-/]*)\s*\{$', l)
        if m:
            stack.append(m.group(1) or "/")
            if "/".join(stack).replace("//", "/") == path:
                depth = 0
                for j in range(i, len(L)):
                    depth += L[j].count("{") - L[j].count("}")
                    if depth == 0: return i, j
            continue
        if re.match(r'^\s*\};', l): stack.pop()
    sys.exit(f"node {path} not found")
def drop_node(L, path):
    a, b = find_node(L, path)
    del L[a:b + 1]
    if a < len(L) and L[a].strip() == "" and L[a - 1].strip() == "": del L[a]
def set_prop(L, path, prop, value):
    """value None = delete the property; else replace its whole line (property must exist)."""
    a, b = find_node(L, path); depth = 0
    for i in range(a, b + 1):
        if i > a: depth += L[i - 1].count("{") - L[i - 1].count("}")
        if depth == 1 and re.match(rf'^\s*{re.escape(prop)}( = .*)?;$', L[i]):
            if value is None: del L[i]
            else: L[i] = re.sub(r'^(\s*).*$', rf'\g<1>{prop} = {value};', L[i])
            return
    sys.exit(f"{path} has no {prop}")

S = "/soc@200000000"
PCIE = "/pcie@1cb0000000"
PMGR = f"{S}/power-management@280900000"
DCP9D_PCIE_REG = "<0x1c 0xb0000000 0x00 0x10000000 0x04 0x14000000 0x00 0x4000 0x04 0x10028000 0x00 0x8000 0x04 0x17010000 0x00 0x4000 0x04 0x10024000 0x00 0x4000>"
VARIANTS = {
    # B8: the port is not one the kernel can train any more -> 0028 keeps port00 and dart_apcie0 disabled: no N1
    "b8-nopwren": [("prop", f"{PCIE}/pci@0,0", "pwren-gpios", None)],
    # B10: the six apcie power-controllers the in-tree DT adds (absent from dcp9d)
    "b10-nopwrctl": [("node", f"{PMGR}/power-controller@{a}") for a in ("280", "258", "1b0", "148", "138", "118")],
    # B11: GPU nodes + GPU/UAT reserved-memory placeholders + NVRAM NOR, and their aliases
    "b11-nogpu-nonvram": [("prop", "/aliases", "gpu", None), ("prop", "/aliases", "nvram", None),
                          *[("node", f"/reserved-memory/{n}") for n in ("gpu-fw-text", "gpu-fw-data", "uat-ttbs",
                            "uat-pagetables", "uat-l2-pagetables", "uat-handoff")],
                          ("node", "/soc@2300000000"),
                          ("node", f"{S}/spi@505118000/flash@0"),
                          ("prop", f"{S}/spi@505118000", "status", '"disabled"')],
    # B12: the kernel-train pcie description reverted to dcp9d's (windows, pwren-gpios, SMC GPIO bank, manual-availability)
    "b12-notrain-dt": [("prop", PCIE, "reg", DCP9D_PCIE_REG),
                       ("prop", PCIE, "reg-names", '"config", "rc", "port0", "phy0", "intr2axi0"'),
                       ("prop", f"{PCIE}/pci@0,0", "pwren-gpios", None),
                       ("node", f"{S}/smc@28c600000/gpio@67500000"),
                       ("prop", f"{S}/iommu@410000000", "apple,manual-availability", None)],
}
for name, edits in VARIANTS.items():
    L = lines_of(dts)
    for e in edits:
        if e[0] == "node": drop_node(L, e[1])
        else: set_prop(L, e[1], e[2], e[3])
    text = "\n".join(L)
    out = HERE / f"t6050-j716s-daily-dcp-{name}.dtb"
    (HERE / f"t6050-j716s-daily-dcp-{name}.dts").write_text(text)
    subprocess.run([DTC, "-q", "-I", "dts", "-O", "dtb", "-o", str(out), "-"], input=text.encode(), check=True)
    print(name, hashlib.sha256(out.read_bytes()).hexdigest(), out.stat().st_size)
