#!/usr/bin/env python3
# E2 and DCP test payloads (all: m5.selftest=1, battery on) on the daily's Wi-Fi recipe: stitched-FTAB initramfs
# (private), chosen.m5pro,n1=4 after the show-notch line, NO pcie_aspm=off. Runs
# contrib/validated/aurora/tools/mk-daily.py unchanged, as a module (like aurora-prs-2/payloads/mk-v2.py), with:
#  - M1N1_SIZE = 0x410000: the GPU hand-off pushes n1-warm's plain image from 0x400000 to 0x410000 (.text crosses
#    the 0x70000 boundary, so every later 64 KiB-aligned section moves up); m1n1 reads its variables right after
#    its own image, so they go at 0x410000. Both the -gpu and the -gpu-dcp images are 0x410000.
#  - NOTCH += the variable lines (mk-daily has no option for more chosen variables).
#   python3 -I mk-e2.py e2a|e2b|dcpa|dcpb0|dcpb       build one payload into payloads/private/
#   python3 -I mk-e2.py plan <payload> [root@host]    print the ESP deploy plan (mk-daily's, with the 0x410000 offset)
import hashlib, importlib.util, os, pathlib, sys
H = pathlib.Path.home()
E = H/"Work/agents/gpu-e2"
TOOL = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
ND = H/"Work/agents/next-daily"
M_GPU = E/"build/m1n1-plain-n1-warm-gpu.bin"
M_DCP = E/"build/m1n1-plain-n1-warm-gpu-dcp.bin"
K_GPU = E/"kbuild/gpu/Image.gz"                       # j716s-series-gpu-27, DRM_APPLE off
K_DCP = E/"kbuild/dcp/Image.gz"                       # same tree + j716s-dcp.config (DRM_APPLE on)
K_DAILY = ND/"images/Image-7.3.0-ga0f2f30c967b.gz"    # the daily kernel
D_GPU = E/"kbuild/gpu/t6050-j716s-gpu27.dtb"          # daily DTB + E1's disabled GPU nodes and gpu alias
D_DAILY = ND/"images/t6050-j716s-next-daily.dtb"
D_DCP9 = E/"payloads/private/dt/t6050-j716s-daily-dcp9.dtb"   # daily DTB + fixed9 display nodes, no bw-scratch
IR = ND/"payloads/private/initramfs-ftab.cpio.gz"
PINS = {
    M_GPU: "fecf701bccb3e462d8f33c779b88a174ca0f8adcde728a37d56d8495f6f8c18e",
    M_DCP: "085a2734c6f29c4fb28231eedf0420bf90e1befcb1209d5381019dcc43fb31f3",
    K_GPU: "5125f15be6cf5933256e105e78097067274d8071367bf993888c237881c3d1b9",
    K_DCP: "e79894ac5cc15d64e765c0621e3c04a24d678a1d9ad466c725e81929879bf43a",
    K_DAILY: "0f302e9a7a05be12884d38e2aff794ec64ae094619eb9d06df8e5bac6e5106fb",
    D_GPU: "53429ff0ce4e15323bee684e391835beda86c5a73e075802f5468add6a84e999",
    D_DAILY: "659af884741861a6edd68b364d4f9ec04d624fe761dd0163e81964dafe136e8c",
    D_DCP9: "e26dcbbc1d3dadde11e44ff15c8b1185d907b564b0ec999643b83f335f5ffe7d",
    IR: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa",
}
NOTCH = b"chosen.asahi,show-notch=1\n"
N1 = b"chosen.m5pro,n1=4\n"
DYNDBG = 'dyndbg="file drivers/gpu/drm/apple/* +p; file drivers/iommu/apple-dart.c +p"'
VARIANTS = {   # label: (m1n1, kernel, dtb, extra variable lines, extra bootargs, note)
    "e2a": ("e2a-ctl", M_GPU, K_GPU, D_GPU, b"", "",
            "E2a control: no chosen.m5pro,gpu line, every GPU node stays disabled, the GPU driver never probes"),
    "e2b": ("e2b-gpu", M_GPU, K_GPU, D_GPU, b"chosen.m5pro,gpu=1\n", "",
            "E2b: chosen.m5pro,gpu=1, m1n1 hands the GPU over, the driver identifies the firmware and boots it"),
    "dcpa": ("dcpa", M_DCP, K_DAILY, D_DAILY, b"", "",
             "DCP-A: the daily kernel and DTB with the gpu-dcp m1n1, not armed (m1n1 reads and logs the DCP state, "
             "reserves the coprocessor __OS_LOG segments)"),
    "dcpb0": ("dcpb0", M_DCP, K_DAILY, D_DCP9, b"chosen.m5,t6050-display=1\n", "",
              "DCP-B0: armed, daily DTB + fixed9 display nodes (no apple,bw-scratch), daily kernel (no DRM_APPLE)"),
    "dcpb": ("dcpb", M_DCP, K_DCP, D_DCP9, b"chosen.m5,t6050-display=1\n", "drm.debug=0x1e log_buf_len=4M " + DYNDBG,
             "DCP-B: DCP-B0 with the j716s-series-gpu-27 kernel built with j716s-dcp.config (DRM_APPLE=y)"),
}
sha = lambda b: hashlib.sha256(b).hexdigest()
spec = importlib.util.spec_from_file_location("mk_daily", TOOL)
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)
mk.M1N1_SIZE = 0x410000

if sys.argv[1] == "plan":
    p = pathlib.Path(sys.argv[2]).resolve()
    b = p.read_bytes()
    st = mk.SELFTEST in b[mk.M1N1_SIZE:mk.M1N1_SIZE + 2048].decode("ascii", "replace")
    print(mk.deploy_plan(p, p.name, sha(b), len(b), st, sys.argv[3] if len(sys.argv) > 3 else "root@LINUX_IP"), end="")
    sys.exit(0)

label, m1n1, kernel, dtb, var, extra, note = VARIANTS[sys.argv[1]]
for f in (m1n1, kernel, dtb, IR):
    got = sha(f.read_bytes())
    if got != PINS[f]:
        sys.exit(f"mk-e2: {f}: sha256 {got} != pin {PINS[f]}")
    if f == m1n1 and len(f.read_bytes()) != 0x410000:
        sys.exit(f"mk-e2: {f} is not 0x410000 bytes")
mk.NOTCH = NOTCH + N1 + var
out = E/"payloads/private"
out.mkdir(mode=0o700, parents=True, exist_ok=True)
argv = [str(TOOL), "--out", str(out), "--label", label, "--battery", "--selftest", "--m1n1", str(m1n1),
        "--kernel", str(kernel), "--dtb", str(dtb), "--initramfs", str(IR)]
if extra:
    argv += ["--extra", extra]
sys.argv = argv
mk.main()
# private (the initramfs carries the board's FTAB): 0600, and the recipe notes
for f in out.glob(f"{label}-*"):
    os.chmod(f, 0o600)
    if f.name.endswith(".recipe.txt") and "note      built by mk-e2.py" not in f.read_text():
        with open(f, "a") as r:
            r.write(f"note      built by mk-e2.py {label}: mk-daily.py as a module, M1N1_SIZE=0x410000, NOTCH = show-notch + "
                    f"{(N1 + var).decode().strip().replace(chr(10), ' + ')}\n"
                    f"note      {note}\n"
                    f"note      deploy plan: python3 -I {E}/mk-e2.py plan <this payload> root@<host> (mk-daily --deploy-plan "
                    f"reads the selftest flag at 0x400000 and would mislabel it)\n")
