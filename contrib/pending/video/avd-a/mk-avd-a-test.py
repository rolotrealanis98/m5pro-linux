#!/usr/bin/env python3
# avd-a TEST payload, adapted from ~/Work/agents/video-observe/mk-video-observe2-test.py (same variables, initramfs, tool):
#   avd-a-test   bootargs of the recovery2-test set (m5.selftest=1 watchdog.open_timeout=300 + EXTRA)
#                + aurora.m5_pause_timeout_us=2000 (the daily's GPU pause setting)
#                (apple_avd and apple_jpeg are kept from autoloading by a modprobe.d blacklist the runner writes; it loads them by hand)
# loader = the video-observe loader m1n1-plain-n1-dt-gpu-dcp-phfix-ave.bin (the daily's loader branch n1-dt-gpu-dcp-phfix @ 694d4040
#          + contrib/pending/video/encode/patches/m1n1/0001, AVE firmware hand-off), PINNED below: the same loader the daily
#          daily-dcp-rec-video-20261108-26ca25f0 boots with
# kernel = kbuild-avd/Image.gz = j716s-avd-a (0933f881d736 + SERIES.txt), release in kbuild-avd/kernel.release
# dtb    = kbuild-avd/t6050-j716s-avd-a.dtb (in-tree; avd + avd_dart + jpeg0/1 + jpeg_dart okay, so it DIFFERS from the daily's)
# Output (0600) in this directory: <label>-<date>-<sha8>.bin, .recipe.txt, .rel, modules-<rel>.tar.zst, SHA256SUMS lines.
#   python3 -I mk-avd-a-test.py
import hashlib, importlib.util, os, pathlib, shutil, subprocess, sys, tempfile
H = pathlib.Path.home(); R = H/"Work/agents/avd"; K = R/"kbuild-avd"
LABEL = "avd-a-test"
TOOL = H/"Work/agents/loop-safety/mk-daily.py"
REPO_TOOL = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
DIFF = H/"Documents/GitHub/m5pro-linux/contrib/pending/boot-ab/loop-safety/mk-daily.diff"
M1N1 = H/"Work/agents/video-observe/m1n1-build/m1n1-plain-n1-dt-gpu-dcp-phfix-ave.bin"
IR = H/"Work/agents/loop-safety/private/initramfs-ftab-wdt2.cpio.gz"
DAILY = H/"Work/agents/video-observe/daily-dcp-rec-video-20261108-26ca25f0.bin"
VIDEO_DTB = H/"Work/agents/video-observe/kbuild-video/t6050-j716s-video-observe.dtb"
FW = R/"firmware/avd-fw-v5-t2.bin"
sha = lambda b: hashlib.sha256(b).hexdigest()
PINS = {M1N1: "fb29185cb374bee9c03de7d907653a0d9a5ca78ee776be1341b596c9242aa928",
        IR: "abb4716532fbe4f2e366b80645d664f6797dc2cda3a5a0622616b80a7844d208",
        DAILY: "26ca25f055dd83e813abdcfe898b72d56185fdd6e676bffedcd0141ad9b0f2e5",
        VIDEO_DTB: "4a8cfe25f33d24df351c42d3c4e1d883aed7585da895d63de1ff22ce36613a77",
        FW: "e3c3c3fa8f7945953342b3de9a58dee0a70faab3dea44827b3a71c416beca440"}
NOTCH = b"chosen.asahi,show-notch=1\nchosen.m5pro,gpu=1\nchosen.m5,t6050-display=1\n"
EXTRA = "log_buf_len=16M appledrm.fw27_panel_vrr=1 rcupdate.rcu_cpu_stall_timeout=21 aurora.m5_pause_timeout_us=2000"
for f, h in PINS.items():
    if sha(f.read_bytes()) != h: sys.exit(f"mk-avd-a-test: {f}: sha256 {sha(f.read_bytes())} != pin {h}")
if len(M1N1.read_bytes()) != 0x410000: sys.exit("mk-avd-a-test: loader is not 0x410000 bytes")
with tempfile.TemporaryDirectory() as td:
    t = pathlib.Path(td)/"mk-daily.py"; shutil.copy(REPO_TOOL, t)
    subprocess.run(["patch", "-s", str(t), str(DIFF)], check=True)
    if t.read_bytes() != TOOL.read_bytes(): sys.exit(f"mk-avd-a-test: {TOOL} is not the repo mk-daily.py with {DIFF.name} applied")
sums = {l.split()[1]: l.split()[0] for l in (K/"SHA256SUMS").read_text().splitlines() if l.strip()}
rel = (K/"kernel.release").read_text().strip()
kern, dtb, mods = K/"Image.gz", K/"t6050-j716s-avd-a.dtb", K/f"modules-{rel}.tar.zst"
for f in (kern, dtb, mods, K/"kernel.release"):
    if sha(f.read_bytes()) != sums[f.name]: sys.exit(f"mk-avd-a-test: {f} does not match {K}/SHA256SUMS")
if sha(dtb.read_bytes()) == PINS[VIDEO_DTB]: sys.exit("mk-avd-a-test: the DTB is the video-observe DTB (AVD/JPEG not enabled?)")
dts = (K/"t6050-j716s-avd-a.dts").read_text() if (K/"t6050-j716s-avd-a.dts").exists() else ""
for c in ("apple,t6050-avd", "apple,t8142-avd", "apple,t6050-jpeg", "apple,t6050-prores", "apple,t6050-ave"):
    if f'"{c}"' not in dts: sys.exit(f"mk-avd-a-test: {c} not in the DTB (kbuild-avd/t6050-j716s-avd-a.dts)")
checks = (K/"dtb-checks.txt").read_text() if (K/"dtb-checks.txt").exists() else ""
for n in ("avd@2309080000", "iommu@2309020000", "jpeg@2281000000", "jpeg@2281060000", "iommu@2281020000"):
    if f'node {n}: status "okay"' not in checks: sys.exit(f"mk-avd-a-test: {n} is not okay in kbuild-avd/dtb-checks.txt")
for m in ("apple,t6050-avd", "apple/avd-fw-v5-t2.bin"):
    if m not in (K/"apple-avd.modinfo").read_text(): sys.exit(f"mk-avd-a-test: apple-avd.modinfo lacks {m}")
tip = subprocess.run(["git", "-C", "/Volumes/linux-cs/linux", "rev-parse", "--short=12", "j716s-avd-a"],
                     capture_output=True, text=True).stdout.strip()
R.mkdir(mode=0o700, exist_ok=True); os.chmod(R, 0o700)
spec = importlib.util.spec_from_file_location("mk_daily", TOOL); mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk); mk.M1N1_SIZE = 0x410000; mk.NOTCH = NOTCH
sys.argv = [str(TOOL), "--out", str(R), "--label", LABEL, "--battery", "--selftest", "--m1n1", str(M1N1), "--kernel", str(kern),
            "--dtb", str(dtb), "--initramfs", str(IR), "--extra", EXTRA]
mk.main()
p = sorted(R.glob(f"{LABEL}-2*.bin"), key=lambda x: x.stat().st_mtime)[-1]
(R/(p.name[:-4] + ".rel")).write_text(rel + "\n")
shutil.copyfile(mods, R/mods.name)
r = p.with_name(p.name + ".recipe.txt")
with open(r, "a") as f:
    f.write(f"note      built by mk-avd-a-test.py: loop-safety patched mk-daily.py as a module (diff applied, checked), M1N1_SIZE=0x410000\n"
            f"note      avd-a TEST payload for the daily daily-dcp-rec-video-20261108-26ca25f0 (restore target, pinned): same variables, VRR and pause bootargs; "
            f"loader = m1n1-plain-n1-dt-gpu-dcp-phfix-ave (fb29185c, pinned) = the daily's loader; "
            f"kernel = j716s-avd-a {tip or '?'} (0933f881d736 + video 0001-0004, 0009-0011 + AVD node annotation, SERIES.txt; config = the video-observe config unchanged), release {rel}; "
            f"in-tree DTB DIFFERS from the daily 4a8cfe25 (avd + avd_dart + jpeg0/jpeg1 + jpeg_dart okay; ave, apr0 as in the daily); "
            f"initramfs = initramfs-ftab-wdt2 (daily ftab + watchdog opener v2); m5.selftest=1 + watchdog.open_timeout=300\n"
            f"note      extra bootargs: {EXTRA}\n"
            f"note      firmware: apple/avd-fw-v5-t2.bin {PINS[FW][:8]} (aurora-silicon/avd-fw, built on the Studio: build-avd-fw.sh) is NOT in the payload; "
            f"the runner copies it to /lib/firmware/apple/ on the root before the boot and removes it after (request_firmware reads the root, the module is loaded by hand)\n"
            f"note      apple_avd and apple_jpeg are loaded by hand (modprobe) during the test; the runner blacklists them in modprobe.d before the boot\n"
            f"note      modules: modules-{rel}.tar.zst (daily list, carries apple-avd.ko with the T6050 variant and apple-jpeg.ko), install before booting: tar -C / -xf modules-{rel}.tar.zst && depmod {rel}\n"
            f"note      test: ~/Work/agents/avd/run-avd-a.sh drives it (AVD probe + firmware boot, JPEG probe, H.264 decode, JPEG encode), then restores the daily\n"
            f"note      deploy plan: python3 -I {H}/Work/agents/daily-dcp/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
with open(R/"SHA256SUMS", "a") as f:
    have = (R/"SHA256SUMS").read_text() if (R/"SHA256SUMS").exists() else ""
    for x in (p, R/mods.name, R/(p.name[:-4] + ".rel"), kern, dtb, M1N1, FW):
        line = f"{sha(x.read_bytes())}  {x.name if x.parent == R else ('kb-' + x.name)}\n"
        if line not in have: f.write(line); have += line
for x in list(R.glob(f"{LABEL}-2*")) + list(R.glob("modules-*")) + [R/"SHA256SUMS"]:
    os.chmod(x, 0o600)
print(f"{LABEL}: {p}  {sha(p.read_bytes())}  release {rel}  loader {M1N1.name} {PINS[M1N1][:8]}  firmware {FW.name} {PINS[FW][:8]}")
