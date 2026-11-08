#!/usr/bin/env python3
# Round 3 of the daily-dcp bisect. B1, B3 and B5 booted, B2 fell back: the trigger is in the in-tree daily-dcp DTB's
# additions over dcp9d, under the display hand-off. Each payload differs from B2 (b6298d9c) in one thing.
#   branch "B6 boots" (the kernel-trained N1 port is the trigger):
#     B9   B2 + chosen.m5pro,n1=4: same loader (0028), the loader trains the port and the kernel adopts it
#     B8   B2 with the in-tree DTB minus port00's pwren-gpios: 0028 then keeps port00 and dart_apcie0 disabled, no N1
#   branch "B6 falls back" (another DT addition):
#     B10  B2 with the in-tree DTB minus the six apcie power-controllers (@118 @138 @148 @1b0 @258 @280)
#     B12  B2 with the in-tree DTB's kernel-train pcie description reverted to dcp9d's (extra pcie windows,
#          pwren-gpios, SMC GPIO bank gpio@67500000, dart_apcie0 apple,manual-availability)
#     B11  B2 with the in-tree DTB minus the GPU nodes, the GPU/UAT reserved-memory placeholders and the NVRAM NOR
# DTBs: dt/mk-dt3.py (decompile c8f1b960, edit by node path, recompile; the unmodified DTS recompiles byte-identical).
# mk-daily.py runs unchanged, as a module (M1N1_SIZE 0x410000); B2 is rebuilt first and must give b6298d9c.
#   python3 -I mk-bisect3.py [B8 B9 B10 B11 B12]   -> ~/Work/agents/daily-dcp/bisect/ (0600)
import hashlib, importlib.util, os, pathlib, sys, tempfile

H = pathlib.Path.home()
TOOL = H / "Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
DD = H / "Work/agents/daily-dcp"
OUT = DD / "bisect"
B2_SHA = "b6298d9c0c375cc3bfbddbeb1554a429bf627e48f279ab9ceaa546b7284d8568"

M_DCP = DD / "m1n1-build/m1n1-plain-n1-dt-gpu-dcp.bin"                   # B2 loader: n1-warm-gpu-dcp + 0028
M_STC = H / "Work/agents/gpu-e2/build/m1n1-plain-n1-warm-gpu-dcp.bin"    # stage C loader (no 0028)
K_DCP = DD / "kbuild/Image.gz"                                            # 7.3.0-gbd53915f2ef1
K_STC = H / "Work/agents/dcp/stagec/kbuild/dcp120/Image.gz"               # 7.3.0-dcp-g22ec57f56b27
D_DCP = DD / "kbuild/t6050-j716s-daily-dcp.dtb"                           # in-tree daily-dcp DTB
D_STC = H / "Work/agents/gpu-e2/payloads/private/dt/t6050-j716s-daily-dcp9d.dtb"  # stage C DTB
DT3 = DD / "bisect/dt"
D_B8 = DT3 / "t6050-j716s-daily-dcp-b8-nopwren.dtb"
D_B10 = DT3 / "t6050-j716s-daily-dcp-b10-nopwrctl.dtb"
D_B11 = DT3 / "t6050-j716s-daily-dcp-b11-nogpu-nonvram.dtb"
D_B12 = DT3 / "t6050-j716s-daily-dcp-b12-notrain-dt.dtb"
IR = H / "Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz"
PINS = {
    M_DCP: "fe7820d224caaa0916eb25cc84ddc1b19a9c086a084d15b09f0ed48f9827d84c",
    M_STC: "085a2734c6f29c4fb28231eedf0420bf90e1befcb1209d5381019dcc43fb31f3",
    K_DCP: "fd5b48ebd314a61cc66542becf1049b16507a9e99a0df04750d6c1b85021798f",
    K_STC: "b9e1bafd31b8346f2bad8699a0b9eab5d25f797e344b85e24314cdb3657647b7",
    D_DCP: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d",
    D_STC: "dab1b4f392ffc3a8024bc168b4143e22a7bad46178ac01363a8056974ea8d7fe",
    D_B8: "d5765d185bd0fd2d804e9f69504abe3a14f6b4bfb4c1809973e75491175c1ba6",
    D_B10: "3ef4428b624ec4feda53c3e2221a6dd49febb9f1d53c4ca02ab082b66d349b4a",
    D_B11: "7492c2f66e58d5e5acf0f2c48a50db731775d3ac5717fb260bc899e1db9b93f8",
    D_B12: "99655db537a6ebc73b8d54fbdb6a946940d365ee7a31900eafc0e48d7b9ac113",
    IR: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa",
}
NOTCH = b"chosen.asahi,show-notch=1\n"
N1 = b"chosen.m5pro,n1=4\n"
DISP = b"chosen.m5,t6050-display=1\n"
EXTRA = "log_buf_len=16M"

# label: (m1n1, kernel, dtb, variables after show-notch, difference, expected)
B2 = ("dcpbis-b2-nogpu", M_DCP, K_DCP, D_DCP, DISP, "-", "-")
VARIANTS = {
    "B9": ("dcpbis-b9-n1loader", M_DCP, K_DCP, D_DCP, N1 + DISP,
           "chosen.m5pro,n1=4 added (stage C's variable order): the B2 loader trains the N1 port and the kernel adopts "
           "it (no kernel train); the in-tree DTB is unchanged",
           "B6 booted and B9 boots -> the kernel's own train of a down port is the trigger, and loader-trained N1 "
           "is a shippable daily; B9 falls back while B6 booted -> 0028 itself (the only other B6 difference)"),
    "B8": ("dcpbis-b8-nopwren", M_DCP, K_DCP, D_B8, DISP,
           "in-tree DTB without port00's pwren-gpios: 0028 no longer sees a kernel-trainable port and keeps port00 and "
           "dart_apcie0 disabled (no N1); everything else in the DTB stays",
           "boots -> the N1 port being enabled for the kernel train is the trigger (as B5, but with every other "
           "in-tree addition present)"),
    "B10": ("dcpbis-b10-nopwrctl", M_DCP, K_DCP, D_B10, DISP,
            "in-tree DTB without the six apcie power-controllers (apcie_gp, fab6_soc, apcie_sys_gp, apcie_phy_sw, "
            "aphy_gp_aus5_a, aphy_gp_aus5); dcp9d has none of them. The kernel train needs them, so N1 may not come up",
            "boots -> the always-on / no-auto-pm apcie domains (raised by pmgr_pwrstate before the DCP probes) are the "
            "trigger"),
    "B12": ("dcpbis-b12-notrain-dt", M_DCP, K_DCP, D_B12, DISP,
            "in-tree DTB with the kernel-train pcie description reverted to dcp9d's: pcie reg/reg-names (5 windows), "
            "no pwren-gpios, no SMC GPIO bank, no apple,manual-availability; port00 and dart_apcie0 stay disabled",
            "boots while B8 fell back -> the SMC GPIO bank, the extra pcie windows or the manual-availability DART "
            "(enabled-but-unused parts of the train description) are the trigger"),
    "B11": ("dcpbis-b11-nogpu-nonvram", M_DCP, K_DCP, D_B11, DISP,
            "in-tree DTB without the GPU nodes (soc@2300000000), the six GPU/UAT reserved-memory placeholders, the "
            "NVRAM NOR (spi@505118000 disabled, flash@0 gone) and the gpu/nvram aliases",
            "expected to fall back (all of it is disabled or a module before the root mounts); boots -> one of them"),
}

sha = lambda b: hashlib.sha256(b).hexdigest()
WANT = sys.argv[1:] or list(VARIANTS)
spec = importlib.util.spec_from_file_location("mk_daily", TOOL)
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)
mk.M1N1_SIZE = 0x410000


def build(label, m1n1, kernel, dtb, var, out):
    for f in (m1n1, kernel, dtb, IR):
        b = f.read_bytes()
        if sha(b) != PINS[f]:
            sys.exit(f"mk-bisect3: {f}: sha256 {sha(b)} != pin {PINS[f]}")
        if f == m1n1 and len(b) != 0x410000:
            sys.exit(f"mk-bisect3: {f} is not 0x410000 bytes")
    mk.NOTCH = NOTCH + var
    sys.argv = [str(TOOL), "--out", str(out), "--label", label, "--battery", "--selftest", "--m1n1", str(m1n1),
                "--kernel", str(kernel), "--dtb", str(dtb), "--initramfs", str(IR), "--extra", EXTRA]
    mk.main()
    return sorted(out.glob(f"{label}-2*.bin"), key=lambda p: p.stat().st_mtime)[-1]


with tempfile.TemporaryDirectory() as td:
    t = build(*B2[:5], pathlib.Path(td))
    if sha(t.read_bytes()) != B2_SHA:
        sys.exit(f"mk-bisect3: B2 rebuilds to {sha(t.read_bytes())}, not {B2_SHA}: recipe drifted, stop")
    print(f"B2 CHECK: rebuilds byte-identical ({B2_SHA[:8]})\n")

OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
for key in WANT:
    label, m1n1, kernel, dtb, var, diff, expect = VARIANTS[key]
    p = build(label, m1n1, kernel, dtb, var, OUT)
    r = p.with_name(p.name + ".recipe.txt")
    if "note      bisect" not in r.read_text():
        with open(r, "a") as f:
            f.write(f"note      bisect round 3 {key}, base B2 dcpbis-b2-nogpu-20261107-b6298d9c.bin (built by {OUT}/mk-bisect3.py); "
                    f"variables: {(NOTCH + var).decode().strip().replace(chr(10), ' + ')}\n"
                    f"note      difference from B2: {diff}\n"
                    f"note      expected: {expect}\n"
                    f"note      deploy plan: python3 -I {DD}/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
    print()
for f in OUT.iterdir():
    if f.is_file() and f.suffix != ".py":
        os.chmod(f, 0o600)
