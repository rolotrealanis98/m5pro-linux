#!/usr/bin/env python3
# The fix for the daily-dcp fallback: the in-tree DTB with phandles on dcp@48ae00000 and display-subsystem
# (fix/mk-dt-fix.py, 67f43890). m1n1's T6050 display hand-off bails on a display node without a phandle
# (kboot.c:2290-2296) -> kboot_prepare_dt() fails -> "Running proxy" with no host -> the stage-1 watchdog.
# Each payload is an existing one with ONLY the DTB swapped; that existing payload is rebuilt first, byte for byte.
#   B4       = B2 (b6298d9c, display, no gpu) + fixed DTB
#   B4-twin  = daily-dcp-test (dfe0c6cc, gpu=1 + display) + fixed DTB          <- the daily-dcp candidate
#   B4-vrr   = daily-dcp-test-vrr (3606884e, + appledrm.fw27_panel_vrr=1) + fixed DTB
import hashlib, importlib.util, os, pathlib, sys, tempfile
H = pathlib.Path.home(); DD = H / "Work/agents/daily-dcp"; OUT = DD / "bisect"
TOOL = H / "Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
M = DD / "m1n1-build/m1n1-plain-n1-dt-gpu-dcp.bin"; K = DD / "kbuild/Image.gz"
D_OLD = DD / "kbuild/t6050-j716s-daily-dcp.dtb"; D_FIX = DD / "fix/t6050-j716s-daily-dcp-phfix.dtb"
IR = H / "Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz"
PINS = {M: "fe7820d224caaa0916eb25cc84ddc1b19a9c086a084d15b09f0ed48f9827d84c",
        K: "fd5b48ebd314a61cc66542becf1049b16507a9e99a0df04750d6c1b85021798f",
        D_OLD: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d",
        D_FIX: "67f438904aa3266d362cb1c6b755668b29b9c5f364dcfd41190c7afbb24a82c4",
        IR: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa"}
NOTCH = b"chosen.asahi,show-notch=1\n"; GPU = b"chosen.m5pro,gpu=1\n"; DISP = b"chosen.m5,t6050-display=1\n"
# key: (base label, base sha, variables, extra, new label, note)
SETS = {
    "B4": ("dcpbis-b2-nogpu", "b6298d9c0c375cc3bfbddbeb1554a429bf627e48f279ab9ceaa546b7284d8568", DISP,
           "log_buf_len=16M", "dcpfix-b4-nogpu", "B2 with the phandle-fixed DTB (display hand-off, no GPU)"),
    "B4-twin": ("daily-dcp-test", "dfe0c6cc40a6b48da8e58593ee695026b68dee6db7a7a7592e1338b97e9a0188", GPU + DISP,
                "log_buf_len=16M", "daily-dcp-phfix-test", "the daily-dcp test twin with the phandle-fixed DTB"),
    "B4-vrr": ("daily-dcp-test-vrr", "3606884e", GPU + DISP, "log_buf_len=16M appledrm.fw27_panel_vrr=1",
               "daily-dcp-phfix-test-vrr", "the VRR test twin with the phandle-fixed DTB"),
}
sha = lambda b: hashlib.sha256(b).hexdigest()
WANT = sys.argv[1:] or list(SETS)
spec = importlib.util.spec_from_file_location("mk_daily", TOOL); mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk); mk.M1N1_SIZE = 0x410000
for f, h in PINS.items():
    if sha(f.read_bytes()) != h: sys.exit(f"mk-phfix: {f} != pin")
def build(label, dtb, var, extra, out):
    mk.NOTCH = NOTCH + var
    sys.argv = [str(TOOL), "--out", str(out), "--label", label, "--battery", "--selftest", "--m1n1", str(M),
                "--kernel", str(K), "--dtb", str(dtb), "--initramfs", str(IR), "--extra", extra]
    mk.main()
    return sorted(out.glob(f"{label}-2*.bin"), key=lambda p: p.stat().st_mtime)[-1]
for key in WANT:
    base, bsha, var, extra, label, note = SETS[key]
    with tempfile.TemporaryDirectory() as td:
        got = sha(build(base, D_OLD, var, extra, pathlib.Path(td)).read_bytes())
        if not got.startswith(bsha): sys.exit(f"mk-phfix: {base} rebuilds to {got}, not {bsha}")
        print(f"{key}: base {base} rebuilds byte-identical ({bsha[:8]})")
    p = build(label, D_FIX, var, extra, OUT)
    with open(p.with_name(p.name + ".recipe.txt"), "a") as r:
        r.write(f"note      {key}: {note}; only the DTB differs from {base} ({bsha[:8]}): c8f1b960 -> 67f43890 "
                f"(phandle 0x74 on dcp@48ae00000, 0x75 on display-subsystem; fix/mk-dt-fix.py)\n"
                f"note      why: m1n1 kboot.c:2290-2296 bails on a display node without a phandle -> kboot_prepare_dt fails "
                f"-> proxy with no host -> stage-1 watchdog (every in-tree-DTB + display hand-off boot fell back)\n"
                f"note      deploy plan: python3 -I {DD}/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
    print()
for f in OUT.iterdir():
    if f.is_file() and f.suffix != ".py": os.chmod(f, 0o600)
