#!/usr/bin/env python3
# Loader-fix form of the daily-dcp payloads: each existing payload with ONLY the m1n1 swapped to
# m1n1-plain-n1-dt-gpu-dcp-phfix.bin (n1-dt-gpu-dcp-phfix @ 694d4040 = 3e2321df + "kboot: T6050: give the display
# nodes a phandle if the DT has none"). In-tree DTB c8f1b960 unchanged (no DT phandle hack). Each base payload is
# rebuilt byte for byte with the old loader before its loader-fix form is written.
#   L-test  = daily-dcp-test      dfe0c6cc  (self-test ON)
#   L-vrr   = daily-dcp-test-vrr  3606884e  (self-test ON, appledrm.fw27_panel_vrr=1)
#   L-daily = daily-dcp           3706058a  (--daily --no-selftest --force)
import hashlib, importlib.util, os, pathlib, sys, tempfile
H = pathlib.Path.home(); DD = H / "Work/agents/daily-dcp"; OUT = DD / "lfix"
TOOL = H / "Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
M_OLD = DD / "m1n1-build/m1n1-plain-n1-dt-gpu-dcp.bin"; M_FIX = DD / "m1n1-build/m1n1-plain-n1-dt-gpu-dcp-phfix.bin"
K = DD / "kbuild/Image.gz"; D = DD / "kbuild/t6050-j716s-daily-dcp.dtb"
IR = H / "Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz"
PINS = {M_OLD: "fe7820d224caaa0916eb25cc84ddc1b19a9c086a084d15b09f0ed48f9827d84c",
        M_FIX: "98906d2912b9de1b384065ad316d25eac88b56286ac495c0d7e2dbd6f8abd477",
        K: "fd5b48ebd314a61cc66542becf1049b16507a9e99a0df04750d6c1b85021798f",
        D: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d",
        IR: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa"}
NOTCH = b"chosen.asahi,show-notch=1\nchosen.m5pro,gpu=1\nchosen.m5,t6050-display=1\n"
TEST = ["--selftest"]; DAILY = ["--daily", "--no-selftest", "--force"]
SETS = {  # key: (base label, base sha256, mode flags, extra, new label)
    "L-test": ("daily-dcp-test", "dfe0c6cc40a6b48da8e58593ee695026b68dee6db7a7a7592e1338b97e9a0188", TEST,
               "log_buf_len=16M", "daily-dcp-lfix-test"),
    "L-vrr": ("daily-dcp-test-vrr", "3606884ed0e88b5e81a2807cd6cdeed444361d710310b900cb6e3a50a853ffda", TEST,
              "log_buf_len=16M appledrm.fw27_panel_vrr=1", "daily-dcp-lfix-test-vrr"),
    "L-daily": ("daily-dcp", "3706058ae1d0cdc0e87ea96040d7edb06ec802f598c49b95ffd5d383a349a2de", DAILY,
                "log_buf_len=16M", "daily-dcp-lfix"),
    # L-daily-vrr: the daily form + appledrm.fw27_panel_vrr=1. It has no old-loader base payload, so its base check is
    # L-daily itself (rebuilt with the phfix loader below, must give 689facad); then only the bootargs change.
    "L-daily-vrr": ("daily-dcp-lfix", "689facad94cb4aafa813ed888c7d0e580142bab050cc99acbbc6c38fdc7b12da", DAILY,
                    "log_buf_len=16M appledrm.fw27_panel_vrr=1", "daily-dcp-lfix-vrr"),
}
BASE_EXTRA = {"L-daily-vrr": "log_buf_len=16M"}
BASE_LOADER = {"L-daily-vrr": "fix"}
sha = lambda b: hashlib.sha256(b).hexdigest()
WANT = sys.argv[1:] or list(SETS)
for f, h in PINS.items():
    b = f.read_bytes()
    if sha(b) != h: sys.exit(f"mk-lfix: {f}: sha256 {sha(b)} != pin {h}")
    if f in (M_OLD, M_FIX) and len(b) != 0x410000: sys.exit(f"mk-lfix: {f} is not 0x410000 bytes")
spec = importlib.util.spec_from_file_location("mk_daily", TOOL); mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk); mk.M1N1_SIZE = 0x410000; mk.NOTCH = NOTCH
def build(label, m1n1, mode, extra, out):
    sys.argv = [str(TOOL), "--out", str(out), "--label", label, "--battery", *mode, "--m1n1", str(m1n1),
                "--kernel", str(K), "--dtb", str(D), "--initramfs", str(IR), "--extra", extra]
    mk.main()
    return sorted(out.glob(f"{label}-2*.bin"), key=lambda p: p.stat().st_mtime)[-1]
OUT.mkdir(mode=0o700, exist_ok=True)
for key in WANT:
    base, bsha, mode, extra, label = SETS[key]
    with tempfile.TemporaryDirectory() as td:
        got = sha(build(base, M_FIX if BASE_LOADER.get(key) == "fix" else M_OLD, mode, BASE_EXTRA.get(key, extra),
                        pathlib.Path(td)).read_bytes())
        if got != bsha: sys.exit(f"mk-lfix: {base} rebuilds to {got}, not {bsha}: stop")
        print(f"{key}: base {base} rebuilds byte-identical ({bsha[:8]})")
    p = build(label, M_FIX, mode, extra, OUT)
    r = p.with_name(p.name + ".recipe.txt")
    if "note      lfix" not in r.read_text():
        with open(r, "a") as f:
            f.write(f"note      lfix {key}: L-daily 689facad + appledrm.fw27_panel_vrr=1 (only the bootargs differ); L-vrr "
                    f"54b4d1c9 is this payload + m5.selftest=1\n" if key == "L-daily-vrr" else
                    f"note      lfix {key}: {base}-*-{bsha[:8]} with ONLY the loader swapped: m1n1-plain-n1-dt-gpu-dcp-phfix.bin "
                    f"(98906d29, n1-dt-gpu-dcp-phfix @ 694d4040: display nodes without a phandle get one, so the T6050 "
                    f"display hand-off no longer bails on the in-tree DTB, kboot.c:2290-2296); in-tree DTB c8f1b960 unchanged\n"
                    f"note      variables: show-notch + chosen.m5pro,gpu=1 + chosen.m5,t6050-display=1; no n1 line\n"
                    f"note      deploy plan: python3 -I {DD}/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
    print()
for f in OUT.iterdir():
    if f.is_file() and f.suffix != ".py": os.chmod(f, 0o600)
