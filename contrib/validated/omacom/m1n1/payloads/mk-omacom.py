#!/usr/bin/env python3
# Boot-test payloads for the omacom/m1n1 T6050 series on the J716s, one per branch stack.
# Like ~/Work/agents/aurora-prs-2/payloads/mk-v2.py: runs contrib/validated/aurora/tools/mk-daily.py unchanged,
# as a module, with two overrides per payload:
#  - M1N1_SIZE = 0x410000: every omacom build here (base, each commit) is 0x410000 bytes, and m1n1 reads the
#    payload variables right after its own image (m1n1-raw.ld _payload_start).
#  - NOTCH = mk-daily's show-notch line + the stack's chosen lines (mk-daily has no option for more variables;
#    the daily carries chosen.m5pro,n1=4 at the same place). The names are omacom's: chosen.asahi,t6050-n1 and
#    chosen.asahi,t6050-display; the lineage names (chosen.m5pro,n1, chosen.m5,t6050-display) are not read.
# m1n1: ../build/cNN.bin (plain `make` of the branch tip; ../build/build.sh), checked against ../build/cNN.commit
# and ../build/SHA256SUMS. Every other ingredient is pinned to a payload booted on the J716s today:
#   daily      = the daily's test twin next-daily-wifi-20261107-ee3d0dd8 (kernel 7.3.0-ga0f2f30c967b, daily DTB,
#                stitched-FTAB initramfs, its bootargs incl. pcie_aspm=off)
#   gpu        = E2b e2b-gpu-20261107-3f2fec04 (kernel 7.3.0-g3671d907d570, its bootargs) with the DTB of the aurora GPU
#                PR payload (E2 DTB + status okay on &gpu and &pmgr_gfx: this hand-off has no opt-in, the DT decides)
#   display    = DCP-B0 dcpb0-20261107-fe531c17 (daily kernel, daily DTB + display nodes without bw-scratch)
# The initramfs carries the board's FTAB: PRIVATE, so are the payloads (mode 600, never committed).
# Self-test on (m5.selftest=1: reverts to boot.bin.prev without network 90 s after network-online), battery on.
#   python3 -I ~/Work/agents/omacom-m1n1/payloads/mk-omacom.py [name ...]
import hashlib, importlib.util, os, pathlib, sys
H = pathlib.Path.home()
HERE = pathlib.Path(__file__).resolve().parent
BUILD = HERE.parent / "build"
TOOL = H / "Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
KERNEL_DAILY = (H / "Work/agents/next-daily/images/Image-7.3.0-ga0f2f30c967b.gz",
                "0f302e9a7a05be12884d38e2aff794ec64ae094619eb9d06df8e5bac6e5106fb")
KERNEL_GPU = (H / "Work/agents/gpu-e2/kbuild/gpu/Image.gz",
              "5125f15be6cf5933256e105e78097067274d8071367bf993888c237881c3d1b9")
DTB_DAILY = (H / "Work/agents/next-daily/images/t6050-j716s-next-daily.dtb",
             "659af884741861a6edd68b364d4f9ec04d624fe761dd0163e81964dafe136e8c")
DTB_GPU = (H / "Work/agents/m1n1-gpu-pr/payloads/t6050-j716s-gpu27-gpu-on.dtb",
           "adada7fc5134cec28ebde4302fae5452e2994993e9bd0debd4c8af8f06ba3543")
DTB_DCP = (H / "Work/agents/gpu-e2/payloads/private/dt/t6050-j716s-daily-dcp9.dtb",
           "e26dcbbc1d3dadde11e44ff15c8b1185d907b564b0ec999643b83f335f5ffe7d")
INITRD = (H / "Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz",
          "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa")
SHOW_NOTCH = b"chosen.asahi,show-notch=1\n"
N1 = b"chosen.asahi,t6050-n1=4\n"
DISPLAY = b"chosen.asahi,t6050-display=1\n"
# name: (label, build image, branch, kernel, dtb, extra chosen lines, extra bootargs)
PAYLOADS = {
    "bringup": ("omacom-t6050-bringup", "c02", "omacom/t6050-bringup", KERNEL_DAILY, DTB_DAILY, b"", "pcie_aspm=off"),
    "n1":      ("omacom-t6050-n1", "c07", "omacom/t6050-n1", KERNEL_DAILY, DTB_DAILY, N1, "pcie_aspm=off"),
    "gpu":     ("omacom-t6050-gpu", "c08", "omacom/t6050-gpu", KERNEL_GPU, DTB_GPU, N1, ""),
    "display": ("omacom-t6050-display", "c12", "omacom/t6050-display", KERNEL_DAILY, DTB_DCP, N1 + DISPLAY, ""),
    "wdtkeep": ("omacom-wdt-keep", "c13", "omacom/wdt-keep", KERNEL_DAILY, DTB_DAILY, N1, "pcie_aspm=off"),
}


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def pinned(entry):
    p, want = entry
    got = sha(p)
    if got != want:
        sys.exit(f"mk-omacom: {p}: sha256 {got} != {want}")
    return p


sums = dict(reversed(l.split()) for l in (BUILD / "SHA256SUMS").read_text().splitlines() if l.strip())
repo = H / "Work/agents/aurora-prs-2/m1n1"
for name in sys.argv[1:] or list(PAYLOADS):
    label, img, branch, kernel, dtb, chosen, extra = PAYLOADS[name]
    m1n1 = BUILD / f"{img}.bin"
    tip = os.popen(f"git -C {repo} rev-parse --short=7 {branch}").read().strip()
    built = (BUILD / f"{img}.commit").read_text().split()[0]
    if not built.startswith(tip) and not tip.startswith(built):
        sys.exit(f"mk-omacom: {img}.bin is {built}, {branch} is {tip}: rebuild")
    if sums.get(f"{img}.bin") != sha(m1n1) or len(m1n1.read_bytes()) != 0x410000:
        sys.exit(f"mk-omacom: {m1n1} does not match build/SHA256SUMS or is not 0x410000 bytes")
    spec = importlib.util.spec_from_file_location("mk_daily", TOOL)
    mk = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mk)
    assert mk.NOTCH == SHOW_NOTCH
    mk.M1N1_SIZE = 0x410000
    mk.NOTCH = SHOW_NOTCH + chosen
    sys.argv = [str(TOOL), "--out", str(HERE), "--label", label, "--battery", "--selftest",
                "--m1n1", str(m1n1), "--kernel", str(pinned(kernel)), "--dtb", str(pinned(dtb)),
                "--initramfs", str(pinned(INITRD))] + (["--extra", extra] if extra else [])
    mk.main()
    for f in HERE.glob(f"{label}-*.bin"):
        f.chmod(0o600)
