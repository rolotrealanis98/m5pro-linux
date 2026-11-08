#!/usr/bin/env python3
# video-observe TEST payload, adapted from ~/Work/agents/gpu-recovery/mk-recovery2-test.py (same variables, initramfs, tool):
#   video-observe-test   bootargs of the recovery2-test set (m5.selftest=1 watchdog.open_timeout=300 + EXTRA)
#                        + aurora.m5_pause_timeout_us=2000 (the daily's GPU pause setting)
#                        + module_blacklist=apple_prores (the ProRes observer is loaded by hand during the test)
# loader = m1n1-build/m1n1-plain-n1-dt-gpu-dcp-phfix-ave.bin = the daily's loader branch n1-dt-gpu-dcp-phfix @ 694d4040 +
#          contrib/pending/video/encode/patches/m1n1/0001 (AVE firmware hand-off), PINNED below (build-m1n1-ave.sh)
# kernel = kbuild-video/Image.gz = j716s-video-observe (12c445fa5371 + SERIES.txt), release in kbuild-video/kernel.release
# dtb    = kbuild-video/t6050-j716s-video-observe.dtb (in-tree; the series adds the T6050 media nodes, so it DIFFERS from the daily)
# Output (0600) in this directory: <label>-<date>-<sha8>.bin, .recipe.txt, .rel, modules-<rel>.tar.zst, SHA256SUMS lines.
#   python3 -I mk-video-observe-test.py
import hashlib, importlib.util, os, pathlib, shutil, subprocess, sys, tempfile
H = pathlib.Path.home(); R = H/"Work/agents/video-observe"; K = R/"kbuild-video"
LABEL = "video-observe-test"
TOOL = H/"Work/agents/loop-safety/mk-daily.py"
REPO_TOOL = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
DIFF = H/"Documents/GitHub/m5pro-linux/contrib/pending/boot-ab/loop-safety/mk-daily.diff"
M1N1 = R/"m1n1-build/m1n1-plain-n1-dt-gpu-dcp-phfix-ave.bin"
DAILY_M1N1 = H/"Work/agents/daily-dcp/m1n1-build/m1n1-plain-n1-dt-gpu-dcp-phfix.bin"
IR = H/"Work/agents/loop-safety/private/initramfs-ftab-wdt2.cpio.gz"
DAILY_DTB = H/"Work/agents/daily-dcp/kbuild/t6050-j716s-daily-dcp.dtb"
sha = lambda b: hashlib.sha256(b).hexdigest()
PINS = {M1N1: "fb29185cb374bee9c03de7d907653a0d9a5ca78ee776be1341b596c9242aa928",
        DAILY_M1N1: "98906d2912b9de1b384065ad316d25eac88b56286ac495c0d7e2dbd6f8abd477",
        IR: "abb4716532fbe4f2e366b80645d664f6797dc2cda3a5a0622616b80a7844d208",
        DAILY_DTB: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d"}
NOTCH = b"chosen.asahi,show-notch=1\nchosen.m5pro,gpu=1\nchosen.m5,t6050-display=1\n"
EXTRA = "log_buf_len=16M appledrm.fw27_panel_vrr=1 rcupdate.rcu_cpu_stall_timeout=21 aurora.m5_pause_timeout_us=2000 module_blacklist=apple_prores"
for f, h in PINS.items():
    if sha(f.read_bytes()) != h: sys.exit(f"mk-video-observe-test: {f}: sha256 {sha(f.read_bytes())} != pin {h}")
if len(M1N1.read_bytes()) != 0x410000: sys.exit("mk-video-observe-test: loader is not 0x410000 bytes")
with tempfile.TemporaryDirectory() as td:
    t = pathlib.Path(td)/"mk-daily.py"; shutil.copy(REPO_TOOL, t)
    subprocess.run(["patch", "-s", str(t), str(DIFF)], check=True)
    if t.read_bytes() != TOOL.read_bytes(): sys.exit(f"mk-video-observe-test: {TOOL} is not the repo mk-daily.py with {DIFF.name} applied")
sums = {l.split()[1]: l.split()[0] for l in (K/"SHA256SUMS").read_text().splitlines() if l.strip()}
rel = (K/"kernel.release").read_text().strip()
kern, dtb, mods = K/"Image.gz", K/"t6050-j716s-video-observe.dtb", K/f"modules-{rel}.tar.zst"
for f in (kern, dtb, mods, K/"kernel.release"):
    if sha(f.read_bytes()) != sums[f.name]: sys.exit(f"mk-video-observe-test: {f} does not match {K}/SHA256SUMS")
same_dtb = sha(dtb.read_bytes()) == PINS[DAILY_DTB]
dts = (K/"t6050-j716s-video-observe.dts").read_text() if (K/"t6050-j716s-video-observe.dts").exists() else ""
for c in ("apple,t6050-prores", "apple,t6050-ave"):
    if f'"{c}"' not in dts: sys.exit(f"mk-video-observe-test: {c} not in the DTB (kbuild-video/t6050-j716s-video-observe.dts)")
tip = subprocess.run(["git", "-C", "/Volumes/linux-cs-gpurec/wt-video-observe", "rev-parse", "--short=12", "j716s-video-observe"],
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
    f.write(f"note      built by mk-video-observe-test.py: loop-safety patched mk-daily.py as a module (diff applied, checked), M1N1_SIZE=0x410000\n"
            f"note      video-observe TEST payload for the daily daily-dcp-rec-p2000-20261108-f185b487: same variables, VRR and pause bootargs; "
            f"loader = m1n1-plain-n1-dt-gpu-dcp-phfix-ave (fb29185c, pinned) = the daily's phfix loader branch 694d4040 + encode/patches/m1n1/0001 (AVE firmware hand-off); "
            f"kernel = j716s-video-observe {tip or '?'} (12c445fa5371 + video 0006/0008 + encode 0001-0002 + prores 0001/0003-0005, SERIES.txt; config = daily-dcp + VIDEO_APPLE_PRORES_T6050_OBSERVE=y), release {rel}; "
            f"in-tree DTB {'identical to the daily c8f1b960' if same_dtb else 'DIFFERS from the daily c8f1b960 (adds the T6050 media nodes: ave + 2 DARTs okay, apr0 + DART okay, avd/jpeg disabled)'}; "
            f"initramfs = initramfs-ftab-wdt2 (daily ftab + watchdog opener v2); m5.selftest=1 + watchdog.open_timeout=300\n"
            f"note      extra bootargs: {EXTRA}\n"
            f"note      module_blacklist=apple_prores: the ProRes observer is loaded by hand (modprobe apple_prores) during the test\n"
            f"note      modules: modules-{rel}.tar.zst (daily list, carries apple-ave.ko and apple-prores.ko), install before booting: tar -C / -xf modules-{rel}.tar.zst && depmod {rel}\n"
            f"note      test: ~/Work/agents/video-observe/run-video-observe.sh drives it (AVE probe-only bind, ProRes observe)\n"
            f"note      deploy plan: python3 -I {H}/Work/agents/daily-dcp/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
with open(R/"SHA256SUMS", "a") as f:
    have = (R/"SHA256SUMS").read_text() if (R/"SHA256SUMS").exists() else ""
    for x in (p, R/mods.name, R/(p.name[:-4] + ".rel"), kern, dtb, M1N1):
        line = f"{sha(x.read_bytes())}  {x.name if x.parent == R else ('kv-' + x.name)}\n"
        if line not in have: f.write(line); have += line
for x in list(R.glob(f"{LABEL}-2*")) + list(R.glob("modules-*")) + [R/"SHA256SUMS"]:
    os.chmod(x, 0o600)
print(f"{LABEL}: {p}  {sha(p.read_bytes())}  release {rel}  dtb-same-as-daily={same_dtb}  loader {M1N1.name} {PINS[M1N1][:8]}")
