#!/usr/bin/env python3
# Boot-test payload for aurora-silicon/m1n1 pr/t6050-gpu-handoff (686e792 = pr/t6050-bringup d8a0458 + the T6050
# GPU hand-off) on the J716s. Runs contrib/validated/aurora/tools/mk-daily.py unchanged, as a module (like
# m1n1-t6050-bringup/payloads/mk-bringup.py and gpu-e2/mk-e2.py), with one override:
#  - M1N1_SIZE = 0x410000: this branch's plain m1n1.bin (and aurora-wip b6b4592's) is 0x410000 bytes; m1n1 reads
#    the payload variables right after its own image.
# The hand-off has no chosen.* variable: it runs when the DT enables the gpu node. "The GPU variable set" is
# therefore the DTB: E2's t6050-j716s-gpu27.dtb (53429ff0, every GPU node disabled) with status = "okay" on
# &gpu and &pmgr_gfx only (fdtput, nothing else differs). m1n1 fills and enables the two mailboxes and the six
# reserved-memory regions. The unmodified E2 DTB is the control (m1n1 logs "disabled in the device tree").
# NOTCH stays mk-daily's default ("chosen.asahi,show-notch=1\n"); this branch has no N1 hand-off (#65), so no
# chosen.asahi,t6050-n1 line and no N1 training, as in the bring-up payload.
# Ingredients: E2 kernel 7.3.0-g3671d907d570 (5125f15b; modules already on the root fs from E2), the Wi-Fi
# daily's stitched-FTAB initramfs cffbbaf1 (PRIVATE: carries the board's FTAB), E2 bootargs (no pcie_aspm=off),
# battery on, selftest on. Attended boot: this loader disables the stage-1 watchdog.
#   python3 -I ~/Work/agents/m1n1-gpu-pr/payloads/mk-gpu.py
import hashlib, importlib.util, pathlib, sys
H = pathlib.Path.home()
HERE = pathlib.Path(__file__).resolve().parent
TOOL = H / "Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
PINS = {  # m1n1: ../build/SHA256SUMS gpu.bin; DTB: E2 DTB + two status=okay; kernel/initramfs: exactly what E2b used
    HERE / "m1n1-gpu-plain-686e792.bin": "c1405d08b91fc100f14fffd70c1f9b34f9f354ffde5d771788610b72755db0fe",
    H / "Work/agents/gpu-e2/kbuild/gpu/Image.gz": "5125f15be6cf5933256e105e78097067274d8071367bf993888c237881c3d1b9",
    HERE / "t6050-j716s-gpu27-gpu-on.dtb": "adada7fc5134cec28ebde4302fae5452e2994993e9bd0debd4c8af8f06ba3543",
    H / "Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz": "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa",
}
for p, want in PINS.items():
    got = hashlib.sha256(p.read_bytes()).hexdigest()
    if got != want:
        sys.exit(f"mk-gpu: {p}: sha256 {got} != {want}")
m1n1, kernel, dtb, initrd = PINS
if len(m1n1.read_bytes()) != 0x410000:
    sys.exit("mk-gpu: the m1n1 is not 0x410000 bytes")

spec = importlib.util.spec_from_file_location("mk_daily", TOOL)
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)
mk.M1N1_SIZE = 0x410000
assert mk.NOTCH == b"chosen.asahi,show-notch=1\n"
sys.argv = [str(TOOL), "--out", str(HERE), "--label", "m1n1-t6050-gpu", "--battery", "--selftest",
            "--m1n1", str(m1n1), "--kernel", str(kernel), "--dtb", str(dtb), "--initramfs", str(initrd)]
mk.main()
