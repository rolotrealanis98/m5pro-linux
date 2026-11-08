#!/usr/bin/env python3
# Round 2 of the daily-dcp bisect. B2 (dcpbis-b2-nogpu-20261107-b6298d9c: the twin without chosen.m5pro,gpu=1) fell
# back like the twin (stage-1 watchdog, delta 208 s), so the GPU is out. Each payload here differs from B2 in one
# thing, taken from the stage C / dcp120 boot that worked (dcpc-120d-ct0-20261107-80fa87ec). B2's other settings stay:
# self-test ON, battery ON, initramfs-ftab, bootargs ... m5.selftest=1 log_buf_len=16M, no watchdog bootargs.
#
#   B5  B2 with the stage C DTB t6050-j716s-daily-dcp9d.dtb instead of the in-tree daily-dcp DTB
#   B6  B2 with the stage C loader m1n1-plain-n1-warm-gpu-dcp.bin and chosen.m5pro,n1=4 (the loader trains the N1,
#       the kernel adopts it) instead of n1-dt-gpu-dcp (0028) with no n1 line (the kernel trains it)
#   B7  B5 with the stage C kernel 7.3.0-dcp-g22ec57f56b27 (two differences from B2, one from B5). Not B2 + old
#       kernel: with the in-tree DTB, 0028 enables port00 and dart_apcie0 with the link down (the DTB has pwren-gpios
#       and apple,manual-availability), and the old kernel has no manual-availability support, so it would probe that
#       DART at once and take the SError 0028's own comment warns about. Under dcp9d (no pwren-gpios, no
#       manual-availability) 0028 keeps the port and the DART disabled, so the old kernel boots there as in stage C.
#
# mk-daily.py runs unchanged, as a module (M1N1_SIZE 0x410000). It first rebuilds B2 into a temporary directory and
# stops unless that gives b6298d9c byte for byte.
#   python3 -I mk-bisect2.py [B5 B6 B7]   -> ~/Work/agents/daily-dcp/bisect/ (0600)
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
IR = H / "Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz"
PINS = {
    M_DCP: "fe7820d224caaa0916eb25cc84ddc1b19a9c086a084d15b09f0ed48f9827d84c",
    M_STC: "085a2734c6f29c4fb28231eedf0420bf90e1befcb1209d5381019dcc43fb31f3",
    K_DCP: "fd5b48ebd314a61cc66542becf1049b16507a9e99a0df04750d6c1b85021798f",
    K_STC: "b9e1bafd31b8346f2bad8699a0b9eab5d25f797e344b85e24314cdb3657647b7",
    D_DCP: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d",
    D_STC: "dab1b4f392ffc3a8024bc168b4143e22a7bad46178ac01363a8056974ea8d7fe",
    IR: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa",
}
NOTCH = b"chosen.asahi,show-notch=1\n"
N1 = b"chosen.m5pro,n1=4\n"
DISP = b"chosen.m5,t6050-display=1\n"
EXTRA = "log_buf_len=16M"

# label: (m1n1, kernel, dtb, variables after show-notch, difference, expected)
B2 = ("dcpbis-b2-nogpu", M_DCP, K_DCP, D_DCP, DISP, "-", "-")
VARIANTS = {
    "B5": ("dcpbis-b5-dcp9d", M_DCP, K_DCP, D_STC, DISP,
           "DTB t6050-j716s-daily-dcp9d.dtb (stage C) instead of the in-tree daily-dcp DTB; under it 0028 keeps "
           "port00 and dart_apcie0 disabled (no pwren-gpios, no manual-availability), so no N1 this boot",
           "boots -> something the in-tree DTB adds over dcp9d (GPU/UAT placeholders, apcie power-controllers, the "
           "kernel-train pcie node and SMC GPIO, NVRAM/SPI) breaks the display hand-off; falls back -> kernel or loader"),
    "B6": ("dcpbis-b6-stagec-loader-n1", M_STC, K_DCP, D_DCP, N1 + DISP,
           "loader m1n1-plain-n1-warm-gpu-dcp.bin (stage C, no 0028) with chosen.m5pro,n1=4: the loader trains the "
           "N1 and the kernel adopts it, instead of 0028 leaving the port down for the kernel to train",
           "boots -> 0028's port-kept-enabled/host-tunables path or the kernel's own train is the trigger; falls back "
           "-> not the N1 path"),
    "B7": ("dcpbis-b7-stagec-kernel-dcp9d", M_DCP, K_STC, D_STC, DISP,
           "B5 with the stage C kernel 7.3.0-dcp-g22ec57f56b27 (modules on the root); from B2: kernel and DTB",
           "read against B5: B5 falls back and B7 boots -> the kernel delta (daily base: N1 train, DART "
           "manual-availability, F6, NVRAM, promotion v2); both fall back -> the B2 loader (0028) itself"),
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
            sys.exit(f"mk-bisect2: {f}: sha256 {sha(b)} != pin {PINS[f]}")
        if f == m1n1 and len(b) != 0x410000:
            sys.exit(f"mk-bisect2: {f} is not 0x410000 bytes")
    mk.NOTCH = NOTCH + var
    sys.argv = [str(TOOL), "--out", str(out), "--label", label, "--battery", "--selftest", "--m1n1", str(m1n1),
                "--kernel", str(kernel), "--dtb", str(dtb), "--initramfs", str(IR), "--extra", EXTRA]
    mk.main()
    return sorted(out.glob(f"{label}-2*.bin"), key=lambda p: p.stat().st_mtime)[-1]


with tempfile.TemporaryDirectory() as td:
    t = build(*B2[:5], pathlib.Path(td))
    if sha(t.read_bytes()) != B2_SHA:
        sys.exit(f"mk-bisect2: B2 rebuilds to {sha(t.read_bytes())}, not {B2_SHA}: recipe drifted, stop")
    print(f"B2 CHECK: rebuilds byte-identical ({B2_SHA[:8]})\n")

OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
for key in WANT:
    label, m1n1, kernel, dtb, var, diff, expect = VARIANTS[key]
    p = build(label, m1n1, kernel, dtb, var, OUT)
    r = p.with_name(p.name + ".recipe.txt")
    if "note      bisect" not in r.read_text():
        with open(r, "a") as f:
            f.write(f"note      bisect round 2 {key}, base B2 dcpbis-b2-nogpu-20261107-b6298d9c.bin (built by {OUT}/mk-bisect2.py); "
                    f"variables: {(NOTCH + var).decode().strip().replace(chr(10), ' + ')}\n"
                    f"note      difference from B2: {diff}\n"
                    f"note      expected: {expect}\n"
                    f"note      deploy plan: python3 -I {DD}/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
    print()
for f in OUT.iterdir():
    if f.is_file() and f.suffix != ".py":
        os.chmod(f, 0o600)
