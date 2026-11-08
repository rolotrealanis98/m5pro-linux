#!/usr/bin/env python3
# Bisect payloads for the failed daily-dcp test twin (daily-dcp-test-20261107-dfe0c6cc.bin, error stage 0x30, both
# twins fell back after the stage-1 watchdog). Each payload differs from the twin in exactly one way; everything else
# (kernel 7.3.0-gbd53915f2ef1, self-test ON, battery ON, initramfs-ftab, bootargs + log_buf_len=16M, M1N1_SIZE
# 0x410000, show-notch) is the twin's. No watchdog bootargs (the ftab initramfs has no opener).
#
#   B1   loader m1n1-plain-n1-dt-gpu.bin (the daily's: no display hand-off code), variables gpu=1 only
#   B2   twin without chosen.m5pro,gpu=1 (display hand-off + kernel-side N1 training, no GPU hand-off)
#   B3   twin with the daily's DTB t6050-j716s-daily-n1k.dtb (no display nodes) and no display variable
#   B2b  (optional split, only if B2 boots) twin + initcall_blacklist=__aurora_init: the m1n1 GPU hand-off stays
#        (GPU reserved-memory, GPU nodes okay) but the GPU driver never registers
#
# Runs contrib/validated/aurora/tools/mk-daily.py unchanged, as a module (as mk-daily-dcp.py does). Before building,
# it rebuilds the twin itself into a temporary directory and refuses to go on unless that reproduces dfe0c6cc
# byte for byte, so every variant below is the twin recipe with one change.
#   python3 -I mk-bisect.py [B1 B2 B3 B2b]      (default: all) -> ~/Work/agents/daily-dcp/bisect/ (0600)
#   python3 -I ~/Work/agents/daily-dcp/mk-daily-dcp.py plan <payload> root@<host>   deploy plan (0x410000 offset)
import hashlib, importlib.util, os, pathlib, sys, tempfile

H = pathlib.Path.home()
TOOL = H / "Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
DD = H / "Work/agents/daily-dcp"
OUT = DD / "bisect"
TWIN_SHA = "dfe0c6cc40a6b48da8e58593ee695026b68dee6db7a7a7592e1338b97e9a0188"

M_DCP = DD / "m1n1-build/m1n1-plain-n1-dt-gpu-dcp.bin"                   # twin loader: n1-warm-gpu-dcp + 0028
M_GPU = H / "Work/agents/n1-kernel/m1n1-build/m1n1-plain-n1-dt-gpu.bin"  # daily loader: n1-warm-gpu + 0028
K_DCP = DD / "kbuild/Image.gz"                                            # 7.3.0-gbd53915f2ef1
D_DCP = DD / "kbuild/t6050-j716s-daily-dcp.dtb"                           # twin DTB (display nodes, disabled)
D_N1K = H / "Work/agents/daily-n1k/kbuild/t6050-j716s-daily-n1k.dtb"      # daily DTB (no display nodes)
IR = H / "Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz"
PINS = {
    M_DCP: "fe7820d224caaa0916eb25cc84ddc1b19a9c086a084d15b09f0ed48f9827d84c",
    M_GPU: "1d05a5060e218b0802ba5f6ac2dbc5aa7b25d834f8e341995b675c5c1a7e246b",
    K_DCP: "fd5b48ebd314a61cc66542becf1049b16507a9e99a0df04750d6c1b85021798f",
    D_DCP: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d",
    D_N1K: "2612e67c9a19b266217d753d04ad719ec7fa425094d4d26f67a319c0ff90692b",
    IR: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa",
}
NOTCH = b"chosen.asahi,show-notch=1\n"
GPU = b"chosen.m5pro,gpu=1\n"
DISP = b"chosen.m5,t6050-display=1\n"
EXTRA = "log_buf_len=16M"

# label: (m1n1, dtb, variables, extra bootargs, the one difference, expected)
TWIN = ("daily-dcp-test", M_DCP, D_DCP, GPU + DISP, EXTRA, "-", "-")
VARIANTS = {
    "B1": ("dcpbis-b1-gpuloader", M_GPU, D_DCP, GPU, EXTRA,
           "loader m1n1-plain-n1-dt-gpu.bin (no display hand-off code) and variables gpu=1 only",
           "boots on simpledrm + aurora: the dcp, its mailbox, both display DARTs and the display subsystem stay "
           "status=disabled (only the display hand-off enables them), so apple-drm never probes; the DCP driver "
           "cannot take the panel over without the hand-off (no vram memory-region, no apple,firmware-compat)"),
    "B2": ("dcpbis-b2-nogpu", M_DCP, D_DCP, DISP, EXTRA,
           "no chosen.m5pro,gpu=1 (display hand-off + kernel-side N1 training, no GPU hand-off)",
           "boots with the DCP on the panel if the GPU+DCP pair is the cause (aurora absent, card0=apple); falls "
           "back if the DCP itself fails on the daily-n1k base (kernel N1/F6/NVRAM code, in-tree DT)"),
    "B3": ("dcpbis-b3-n1kdtb", M_DCP, D_N1K, GPU, EXTRA,
           "the daily's DTB t6050-j716s-daily-n1k.dtb (no display nodes) and no display variable",
           "boots as a plain GPU daily (simpledrm + aurora) unless the daily-dcp kernel build itself is broken; "
           "the loader's display code only reads and logs ('not armed')"),
    "B2b": ("dcpbis-b2b-noaurora", M_DCP, D_DCP, GPU + DISP, EXTRA + " initcall_blacklist=__aurora_init",
            "initcall_blacklist=__aurora_init (GPU hand-off kept, GPU driver never registers)",
            "optional, only after B2 boots: boots -> the GPU driver running next to the DCP is the trigger; falls "
            "back -> the m1n1 GPU hand-off state itself (GPU reserved-memory, GPU/PMGR nodes okay) is"),
}

sha = lambda b: hashlib.sha256(b).hexdigest()
WANT = sys.argv[1:] or list(VARIANTS)
spec = importlib.util.spec_from_file_location("mk_daily", TOOL)
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)
mk.M1N1_SIZE = 0x410000


def build(label, m1n1, dtb, var, extra, out):
    for f in (m1n1, dtb, K_DCP, IR):
        b = f.read_bytes()
        if sha(b) != PINS[f]:
            sys.exit(f"mk-bisect: {f}: sha256 {sha(b)} != pin {PINS[f]}")
        if f == m1n1 and len(b) != 0x410000:
            sys.exit(f"mk-bisect: {f} is not 0x410000 bytes")
    mk.NOTCH = NOTCH + var
    sys.argv = [str(TOOL), "--out", str(out), "--label", label, "--battery", "--selftest", "--m1n1", str(m1n1),
                "--kernel", str(K_DCP), "--dtb", str(dtb), "--initramfs", str(IR), "--extra", extra]
    mk.main()
    got = sorted(out.glob(f"{label}-2*.bin"), key=lambda p: p.stat().st_mtime)[-1]
    return got


# 1. the twin, rebuilt: must be dfe0c6cc
with tempfile.TemporaryDirectory() as td:
    t = build(*TWIN[:5], pathlib.Path(td))
    if sha(t.read_bytes()) != TWIN_SHA:
        sys.exit(f"mk-bisect: the twin rebuilds to {sha(t.read_bytes())}, not {TWIN_SHA}: recipe drifted, stop")
    print(f"TWIN CHECK: rebuilds byte-identical ({TWIN_SHA[:8]})\n")

# 2. the variants
OUT.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chmod(OUT, 0o700)
for key in WANT:
    label, m1n1, dtb, var, extra, diff, expect = VARIANTS[key]
    p = build(label, m1n1, dtb, var, extra, OUT)
    r = p.with_name(p.name + ".recipe.txt")
    if "note      bisect" not in r.read_text():
        with open(r, "a") as f:
            f.write(f"note      bisect {key} of daily-dcp-test-20261107-dfe0c6cc.bin (built by {OUT}/mk-bisect.py); "
                    f"variables: {(NOTCH + var).decode().strip().replace(chr(10), ' + ')}\n"
                    f"note      the one difference from the twin: {diff}\n"
                    f"note      expected: {expect}\n"
                    f"note      no ramoops node: iBoot zeroes the ECC DRAM and clears /pram on every boot (CRASHLOG-PRAM)\n"
                    f"note      deploy plan: python3 -I {DD}/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
    print()
for f in OUT.iterdir():
    if f.is_file() and f.suffix != ".py":
        os.chmod(f, 0o600)
