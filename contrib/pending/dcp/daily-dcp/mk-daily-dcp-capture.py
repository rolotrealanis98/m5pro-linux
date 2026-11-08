#!/usr/bin/env python3
# daily-dcp CAPTURE payloads: daily-dcp-test (L-test form: phfix loader, in-tree DTB, gpu=1 + display, self-test ON,
# battery, initramfs-ftab, bootargs + log_buf_len=16M) with ONLY the kernel swapped for the capture build
# (branch j716s-daily-dcp-capture = bd53915f2ef1 + j716s-capture.config, DRM_ASAHI=m; everything else identical,
# diffconfig vs daily-dcp prints only "DRM_ASAHI y -> m") and, in the default variant, modprobe.blacklist=aurora.
#   daily-dcp-capture-test         + modprobe.blacklist=aurora: udev does NOT autoload the GPU driver; it probes only
#                                  when someone runs `modprobe aurora` (an explicit modprobe ignores the blacklist),
#                                  so the probe happens after journald has flushed to /var/log/journal.
#   daily-dcp-capture-test-udev    no blacklist: udev loads aurora at coldplug (may be before the journal flush).
# The capture modules tarball (same 128 targets + aurora.ko) MUST be installed on the root before booting it:
# the release string is new.
#   python3 -I mk-daily-dcp-capture.py daily-dcp-capture-test|daily-dcp-capture-test-udev
#   python3 -I ~/Work/agents/daily-dcp/mk-daily-dcp.py plan <payload> [root@host]   (deploy plan, 0x410000 offset)
import hashlib, importlib.util, os, pathlib, sys, gzip
H = pathlib.Path.home()
TOOL = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
DD = H/"Work/agents/daily-dcp"
CD = DD/"capture"
M = DD/"m1n1-build/m1n1-plain-n1-dt-gpu-dcp-phfix.bin"
K = CD/"kbuild/Image.gz"
D = CD/"kbuild/t6050-j716s-daily-dcp.dtb"
IR = H/"Work/agents/next-daily/payloads/private/initramfs-ftab.cpio.gz"
def pin_from_sums(f):
    for line in (CD/"kbuild/SHA256SUMS").read_text().splitlines():
        h, n = line.split()
        if n == f.name:
            return h
    sys.exit(f"mk-capture: {f.name} not in kbuild/SHA256SUMS")
PINS = {
    M: "98906d2912b9de1b384065ad316d25eac88b56286ac495c0d7e2dbd6f8abd477",
    K: pin_from_sums(K),
    D: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d",  # must equal the daily-dcp in-tree DTB
    IR: "cffbbaf1030d224ca092c586aa25ab0ef2a93db5a1e2701aa3bd0d5618b2fbfa",
}
if pin_from_sums(D) != PINS[D]:
    sys.exit("mk-capture: the capture build's DTB differs from the daily-dcp in-tree DTB c8f1b960")
NOTCH = b"chosen.asahi,show-notch=1\nchosen.m5pro,gpu=1\nchosen.m5,t6050-display=1\n"
VARIANTS = {
    "daily-dcp-capture-test": "log_buf_len=16M modprobe.blacklist=aurora",
    "daily-dcp-capture-test-udev": "log_buf_len=16M",
}
sha = lambda b: hashlib.sha256(b).hexdigest()
label = sys.argv[1]
extra = VARIANTS[label]
for f, h in PINS.items():
    b = f.read_bytes()
    if sha(b) != h: sys.exit(f"mk-capture: {f}: sha256 {sha(b)} != pin {h}")
    if f == M and len(b) != 0x410000: sys.exit(f"mk-capture: {f} is not 0x410000 bytes")
img = gzip.decompress(K.read_bytes())
if b"aurora" in img and b"Probing..." in img and b"AGX GPU driver for Apple silicon" in img:
    sys.exit("mk-capture: the GPU driver looks built in (DRM_ASAHI=y kernel?): refusing")
spec = importlib.util.spec_from_file_location("mk_daily", TOOL); mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk); mk.M1N1_SIZE = 0x410000; mk.NOTCH = NOTCH
CD.mkdir(mode=0o700, exist_ok=True)
sys.argv = [str(TOOL), "--out", str(CD), "--label", label, "--battery", "--selftest", "--m1n1", str(M),
            "--kernel", str(K), "--dtb", str(D), "--initramfs", str(IR), "--extra", extra]
mk.main()
rel = (CD/"kbuild/kernel.release").read_text().strip()
for f in CD.glob(f"{label}-2*"):
    os.chmod(f, 0o600)
    if f.name.endswith(".recipe.txt") and "note      capture" not in f.read_text():
        with open(f, "a") as r:
            r.write(f"note      capture: L-test (daily-dcp-lfix-test 14f93bfc) with ONLY the kernel swapped for {rel} "
                    f"(j716s-daily-dcp-capture: DRM_ASAHI=m, the rest identical to 7.3.0-gbd53915f2ef1)"
                    f"{' and modprobe.blacklist=aurora added' if 'blacklist' in extra else ''}\n"
                    f"note      variables: show-notch + chosen.m5pro,gpu=1 + chosen.m5,t6050-display=1; no n1 line\n"
                    f"note      install first: modules-{rel}.tar.zst from {CD}/kbuild (tar --zstd -xf -C / && depmod {rel})\n"
                    f"note      deploy plan: python3 -I {DD}/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
os.chmod(CD/"SHA256SUMS", 0o600)
