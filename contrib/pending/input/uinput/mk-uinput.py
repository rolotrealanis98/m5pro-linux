#!/usr/bin/env python3
# uinput payloads (issue #4), adapted from ~/Work/agents/video-observe/mk-daily-video-hv27.py: the installed daily
# daily-dcp-rec-video-hv27-20261108-c7f84366 with ONLY the kernel replaced.
#   python3 -I mk-uinput.py test    uinput-test: m5.selftest=1 watchdog.open_timeout=300 (self-revert to boot.bin.prev)
#   python3 -I mk-uinput.py daily   daily-uinput-hv27: no m5.selftest, the same bytes otherwise
# loader    = hv27/m1n1-build/m1n1-hv27-plain.bin (3ea65595, pinned): the installed daily's loader
# kernel    = kbuild-uinput/Image.gz = j716s-uinput (0933f881d736 + "arm64: configs: j716s: Build in uinput and uhid";
#             config = the daily's + CONFIG_INPUT_UINPUT=y + CONFIG_UHID=y), release in kbuild-uinput/kernel.release
# dtb       = kbuild-uinput/t6050-j716s-uinput.dtb, which must be byte-identical to the daily's (4a8cfe25, pinned)
# initramfs = loop-safety/private/initramfs-ftab-wdt2.cpio.gz (abb47165, pinned): the daily's
# Output (0600) in this directory: <label>-<date>-<sha8>.bin, .recipe.txt, .rel, modules-<rel>.tar.zst, SHA256SUMS lines.
import hashlib, importlib.util, os, pathlib, shutil, subprocess, sys, tempfile
if len(sys.argv) != 2 or sys.argv[1] not in ("test", "daily"): sys.exit("usage: mk-uinput.py test|daily")
MODE = sys.argv[1]
H = pathlib.Path.home(); R = H/"Work/agents/uinput"; K = R/"kbuild-uinput"
LABEL = "uinput-test" if MODE == "test" else "daily-uinput-hv27"
TOOL = H/"Work/agents/loop-safety/mk-daily.py"
REPO_TOOL = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
DIFF = H/"Documents/GitHub/m5pro-linux/contrib/pending/boot-ab/loop-safety/mk-daily.diff"
M1N1 = H/"Work/agents/hv27/m1n1-build/m1n1-hv27-plain.bin"
IR = H/"Work/agents/loop-safety/private/initramfs-ftab-wdt2.cpio.gz"
DAILY_DTB = "4a8cfe25f33d24df351c42d3c4e1d883aed7585da895d63de1ff22ce36613a77"
sha = lambda b: hashlib.sha256(b).hexdigest()
PINS = {M1N1: "3ea655950e932392a273576847ec9713171fc52fee3217f46ad538168a11eae1",
        IR: "abb4716532fbe4f2e366b80645d664f6797dc2cda3a5a0622616b80a7844d208"}
NOTCH = b"chosen.asahi,show-notch=1\nchosen.m5pro,gpu=1\nchosen.m5,t6050-display=1\n"
EXTRA = "log_buf_len=16M appledrm.fw27_panel_vrr=1 rcupdate.rcu_cpu_stall_timeout=21 aurora.m5_pause_timeout_us=2000"
for f, h in PINS.items():
    if sha(f.read_bytes()) != h: sys.exit(f"mk-uinput: {f}: sha256 {sha(f.read_bytes())} != pin {h}")
if len(M1N1.read_bytes()) != 0x430000: sys.exit("mk-uinput: loader is not 0x430000 bytes")
with tempfile.TemporaryDirectory() as td:
    t = pathlib.Path(td)/"mk-daily.py"; shutil.copy(REPO_TOOL, t)
    subprocess.run(["patch", "-s", str(t), str(DIFF)], check=True)
    if t.read_bytes() != TOOL.read_bytes(): sys.exit(f"mk-uinput: {TOOL} is not the repo mk-daily.py with {DIFF.name} applied")
sums = {l.split()[1]: l.split()[0] for l in (K/"SHA256SUMS").read_text().splitlines() if l.strip()}
rel = (K/"kernel.release").read_text().strip()
kern, dtb, mods = K/"Image.gz", K/"t6050-j716s-uinput.dtb", K/f"modules-{rel}.tar.zst"
for f in (kern, dtb, mods, K/"kernel.release"):
    if sha(f.read_bytes()) != sums[f.name]: sys.exit(f"mk-uinput: {f} does not match {K}/SHA256SUMS")
if sha(dtb.read_bytes()) != DAILY_DTB: sys.exit("mk-uinput: the DTB differs from the daily's 4a8cfe25 (a config-only change must not move it)")
cfg = (K/"config").read_text().splitlines()
for c in ("CONFIG_INPUT_UINPUT=y", "CONFIG_UHID=y"):
    if c not in cfg: sys.exit(f"mk-uinput: {c} not in {K}/config")
tip = subprocess.run(["git", "-C", "/Volumes/linux-cs-uinput/wt-uinput", "rev-parse", "--short=12", "j716s-uinput"],
                     capture_output=True, text=True).stdout.strip()
if not rel.endswith("-g" + tip): sys.exit(f"mk-uinput: release {rel} is not the branch tip {tip}")
os.chmod(R, 0o700)
spec = importlib.util.spec_from_file_location("mk_daily", TOOL); mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk); mk.M1N1_SIZE = 0x430000; mk.NOTCH = NOTCH
sys.argv = [str(TOOL), "--out", str(R), "--label", LABEL, "--battery", "--m1n1", str(M1N1), "--kernel", str(kern),
            "--dtb", str(dtb), "--initramfs", str(IR), "--extra", EXTRA] + ([] if MODE == "test" else ["--no-selftest"])
mk.main()
p = sorted(R.glob(f"{LABEL}-2*.bin"), key=lambda x: x.stat().st_mtime)[-1]
(R/(p.name[:-4] + ".rel")).write_text(rel + "\n")
shutil.copyfile(mods, R/mods.name)
with open(p.with_name(p.name + ".recipe.txt"), "a") as f:
    f.write(f"note      built by mk-uinput.py {MODE}: loop-safety patched mk-daily.py as a module (diff applied, checked), M1N1_SIZE=0x430000\n"
            f"note      issue #4 (uinput + uhid): the installed daily daily-dcp-rec-video-hv27-20261108-c7f84366 with only the kernel replaced; "
            f"loader m1n1-hv27-plain (3ea65595, pinned), initramfs initramfs-ftab-wdt2 (pinned), DTB byte-identical to the daily's 4a8cfe25 (checked); "
            f"kernel = j716s-uinput {tip} (0933f881d736 + j716s.config: INPUT_UINPUT=y, UHID=y; config = the daily's + those two symbols, checked by the build), release {rel}\n"
            f"note      extra bootargs: {EXTRA}\n"
            f"note      modules: modules-{rel}.tar.zst (daily list), install before booting: tar -C / -xf modules-{rel}.tar.zst && depmod {rel}\n")
with open(R/"SHA256SUMS", "a+") as f:
    f.seek(0); have = f.read()
    for x in (p, R/mods.name, R/(p.name[:-4] + ".rel"), kern, dtb, M1N1):
        line = f"{sha(x.read_bytes())}  {x.name if x.parent == R else ('ku-' + x.name)}\n"
        if line not in have: f.write(line); have += line
for x in list(R.glob(f"{LABEL}-2*")) + list(R.glob("modules-*")) + [R/"SHA256SUMS"]:
    os.chmod(x, 0o600)
print(f"{LABEL}: {p}  {sha(p.read_bytes())}  release {rel}  loader {M1N1.name} {PINS[M1N1][:8]}")
